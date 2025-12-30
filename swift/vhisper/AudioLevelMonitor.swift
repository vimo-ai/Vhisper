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
            print("✅ 音频频谱监听已启动 (FFT)")
        } catch {
            print("❌ 音频频谱监听启动失败: \(error)")
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

        print("✅ 音频频谱监听已停止")
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

    /// 计算波形显示数据 - 中间高两边低的效果
    private func computeBandLevels(from magnitudes: [Float]) -> [Float] {
        // 先计算整体音量（取人声频段 100-3000Hz 的能量）
        let binCount = magnitudes.count
        let voiceLowBin = 2   // 约 100Hz
        let voiceHighBin = min(64, binCount - 1)  // 约 3000Hz

        var sum: Float = 0
        let range = Array(magnitudes[voiceLowBin...voiceHighBin])
        vDSP_sve(range, 1, &sum, vDSP_Length(range.count))
        let avgLevel = sum / Float(range.count)

        // 归一化到 0-1
        let normalizedLevel = max(0, min(1, (avgLevel + 75) / 50))

        // 生成中间高两边低的波形
        var bandLevels = [Float](repeating: 0, count: numberOfBands)
        let center = Float(numberOfBands - 1) / 2.0

        for i in 0..<numberOfBands {
            // 距离中心的比例 (0 = 中心, 1 = 边缘)
            let distanceFromCenter = abs(Float(i) - center) / center

            // 高斯形状：中间高，两边低
            let shape = exp(-distanceFromCenter * distanceFromCenter * 2.5)

            // 加一点随机扰动，让波形更自然
            let noise = Float.random(in: 0.85...1.15)

            // 最终值 = 基础形状 × 音量 × 随机扰动
            bandLevels[i] = min(1, shape * normalizedLevel * noise)
        }

        return bandLevels
    }
}
