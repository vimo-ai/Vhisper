//
//  AudioLevelMonitor.swift
//  vhisper
//
//  实时音频频谱分析器
//  使用 AVAudioEngine + Accelerate FFT 获取真实频谱
//

import AVFoundation
import Accelerate
import Combine

// MARK: - Audio Level Monitor

/// 音频频谱监听器（FFT 频谱分析）
class AudioLevelMonitor: ObservableObject {
    static let shared = AudioLevelMonitor()

    // MARK: - Published Properties

    /// 频谱数据（20个频段，范围 0-1）
    @Published var levels: [Float] = Array(repeating: 0.0, count: 20)

    /// 当前峰值
    @Published var peakLevel: Float = 0.0

    /// 是否正在监听
    @Published var isMonitoring: Bool = false

    // MARK: - Private Properties

    private let audioEngine = AVAudioEngine()
    private let numberOfBands = 20 // 频段数量

    // FFT 相关
    private let fftSize = 1024
    private var fftSetup: FFTSetup?
    private var log2n: vDSP_Length = 0

    // 平滑处理
    private var smoothedLevels: [Float] = Array(repeating: 0.0, count: 20)
    private let smoothingFactor: Float = 0.3 // 平滑系数，越小越平滑

    // 波浪动画 - 每个条独立的目标高度和当前高度
    private var targetHeights: [Float] = Array(repeating: 0.0, count: 20)
    private var currentHeights: [Float] = Array(repeating: 0.0, count: 20)
    private var updateCounter: Int = 0

    private init() {
        setupFFT()
    }

    deinit {
        if let setup = fftSetup {
            vDSP_destroy_fftsetup(setup)
        }
    }

    // MARK: - FFT Setup

    private func setupFFT() {
        log2n = vDSP_Length(log2(Float(fftSize)))
        fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))
    }

    // MARK: - Public Methods

    /// 开始监听麦克风
    func startMonitoring() {
        guard !isMonitoring else { return }

        do {
            try setupAudioEngine()
            isMonitoring = true
        } catch {
        }
    }

    /// 停止监听
    func stopMonitoring() {
        guard isMonitoring else { return }

        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()

        isMonitoring = false

        // 重置
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.levels = Array(repeating: 0.0, count: self.numberOfBands)
            self.smoothedLevels = Array(repeating: 0.0, count: self.numberOfBands)
            self.peakLevel = 0.0
        }

    }

    // MARK: - Private Methods

    private func setupAudioEngine() throws {
        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)

        inputNode.installTap(onBus: 0, bufferSize: UInt32(fftSize), format: format) { [weak self] buffer, _ in
            self?.processFFT(buffer)
        }

        try audioEngine.start()
    }

    /// FFT 频谱分析
    private func processFFT(_ buffer: AVAudioPCMBuffer) {
        guard let fftSetup = fftSetup,
              let channelData = buffer.floatChannelData else { return }

        let frameLength = Int(buffer.frameLength)
        guard frameLength >= fftSize else { return }

        // 获取音频数据
        let samples = channelData[0]

        // 准备 FFT 输入（应用汉宁窗减少频谱泄漏）
        var windowedSamples = [Float](repeating: 0, count: fftSize)
        var window = [Float](repeating: 0, count: fftSize)
        vDSP_hann_window(&window, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))
        vDSP_vmul(samples, 1, window, 1, &windowedSamples, 1, vDSP_Length(fftSize))

        // 准备 split complex 格式
        var realp = [Float](repeating: 0, count: fftSize / 2)
        var imagp = [Float](repeating: 0, count: fftSize / 2)

        realp.withUnsafeMutableBufferPointer { realBP in
            imagp.withUnsafeMutableBufferPointer { imagBP in
                var splitComplex = DSPSplitComplex(realp: realBP.baseAddress!, imagp: imagBP.baseAddress!)

                // 将实数数据转换为 split complex 格式
                windowedSamples.withUnsafeBufferPointer { samplesPtr in
                    samplesPtr.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: fftSize / 2) { complexPtr in
                        vDSP_ctoz(complexPtr, 2, &splitComplex, 1, vDSP_Length(fftSize / 2))
                    }
                }

                // 执行 FFT
                vDSP_fft_zrip(fftSetup, &splitComplex, 1, log2n, FFTDirection(FFT_FORWARD))

                // 计算幅度
                var magnitudes = [Float](repeating: 0, count: fftSize / 2)
                vDSP_zvmags(&splitComplex, 1, &magnitudes, 1, vDSP_Length(fftSize / 2))

                // 转换为分贝并归一化
                var normalizedMagnitudes = [Float](repeating: 0, count: fftSize / 2)
                var one: Float = 1.0
                vDSP_vdbcon(magnitudes, 1, &one, &normalizedMagnitudes, 1, vDSP_Length(fftSize / 2), 0)

                // 分成频段
                let bandLevels = self.computeBandLevels(from: normalizedMagnitudes)

                // 平滑处理并更新
                DispatchQueue.main.async { [weak self] in
                    guard let self = self else { return }

                    // 应用平滑
                    for i in 0..<self.numberOfBands {
                        self.smoothedLevels[i] = self.smoothedLevels[i] * (1 - self.smoothingFactor) + bandLevels[i] * self.smoothingFactor
                    }

                    self.levels = self.smoothedLevels
                    self.peakLevel = self.smoothedLevels.max() ?? 0
                }
            }
        }
    }

    /// 计算波形显示数据 - 静音时平，说话时每个条独立随机波动
    private func computeBandLevels(from magnitudes: [Float]) -> [Float] {
        // 计算整体音量（人声频段 100-3000Hz）
        let binCount = magnitudes.count
        let voiceLowBin = 2
        let voiceHighBin = min(64, binCount - 1)

        var sum: Float = 0
        for bin in voiceLowBin...voiceHighBin {
            sum += magnitudes[bin]
        }
        let avgMagnitude = sum / Float(voiceHighBin - voiceLowBin + 1)

        // 归一化音量到 0-1
        let volume = max(0, min(1, (avgMagnitude + 70) / 45))

        let baseHeight: Float = 0.1  // 静音时的基础高度

        // 每隔几帧更新一次目标高度（控制波动频率）
        updateCounter += 1
        if updateCounter >= 3 {
            updateCounter = 0

            // 给每个条生成新的随机目标高度
            for i in 0..<numberOfBands {
                // 用平方让分布更极端：更多低值，少数高值
                let raw = Float.random(in: 0.0...1.0)
                let randomValue = raw * raw  // 平方后大部分在 0-0.25，少数能到 1

                // 目标高度 = 基础高度 + 音量驱动的随机波动
                targetHeights[i] = baseHeight + volume * randomValue * 0.9
            }
        }

        // 当前高度平滑过渡到目标高度
        let transitionSpeed: Float = 0.3
        for i in 0..<numberOfBands {
            currentHeights[i] += (targetHeights[i] - currentHeights[i]) * transitionSpeed
        }

        return currentHeights
    }
}
