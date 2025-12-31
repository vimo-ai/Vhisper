//
//  WaveformOverlay.swift
//  vhisper
//
//  波形可视化悬浮窗组件
//  支持 Metaball 融合效果的双层设计
//

import SwiftUI
import Combine

// MARK: - MetaballWaveformView

/// Metaball 风格的波形视图
/// 上层：识别文字（动态宽度）
/// 下层：波形显示
/// 两层通过 alphaThreshold + blur 实现融合效果
struct MetaballWaveformView: View {
    let levels: [Float]
    let recognizedText: String
    let stashText: String

    // 配置常量
    private let waveformWidth: CGFloat = 120
    private let waveformHeight: CGFloat = 36
    private let minTextWidth: CGFloat = 60
    private let maxTextWidth: CGFloat = 280
    private let bubbleHeight: CGFloat = 28
    private let blurRadius: CGFloat = 8
    private let verticalGap: CGFloat = 4  // 上下椭圆之间的间距

    var body: some View {
        let displayText = recognizedText + stashText
        let hasText = !displayText.isEmpty

        // 内容层
        VStack(spacing: -4) {  // 轻微重叠产生融合感
            // 上层文字区域 - 直接根据 hasText 显示，不用 @State（避免重建 View 时重置）
            if hasText {
                Text(displayText)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.white.opacity(0.95))
                    .fixedSize(horizontal: true, vertical: true)  // 不截断，完整显示
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .glassEffect(.regular, in: Capsule())
                    .transition(.asymmetric(
                        insertion: .scale(scale: 0.7, anchor: .bottom).combined(with: .opacity),
                        removal: .scale(scale: 0.85, anchor: .bottom).combined(with: .opacity)
                    ))
            }

            // 下层波形区域
            WaveformBarsView(levels: levels)
                .frame(width: waveformWidth - 28, height: waveformHeight - 16)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .glassEffect(.regular, in: Capsule())
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.75), value: hasText)
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: displayText)
    }

    /// 根据文字计算椭圆宽度
    private func calculatedTextWidth(for text: String) -> CGFloat {
        guard !text.isEmpty else { return minTextWidth }

        // 使用 NSString 计算实际宽度
        let font = NSFont.systemFont(ofSize: 11, weight: .medium)
        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        let size = (text as NSString).size(withAttributes: attributes)
        let estimatedWidth = size.width + 32  // padding

        return min(max(estimatedWidth, minTextWidth), maxTextWidth)
    }
}

// MARK: - WaveformBarsView

/// 波形条视图（提取为独立组件）
struct WaveformBarsView: View {
    let levels: [Float]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<paddedLevels.count, id: \.self) { index in
                WaveformBar(level: paddedLevels[index])
            }
        }
    }

    private var paddedLevels: [Float] {
        if levels.count >= 20 {
            return Array(levels.prefix(20))
        } else if levels.isEmpty {
            return Array(repeating: 0.1, count: 20)
        } else {
            var result: [Float] = []
            let step = Float(levels.count - 1) / 19.0
            for i in 0..<20 {
                let idx = Float(i) * step
                let lower = Int(idx)
                let upper = min(lower + 1, levels.count - 1)
                let frac = idx - Float(lower)
                result.append(levels[lower] * (1 - frac) + levels[upper] * frac)
            }
            return result
        }
    }
}

// MARK: - WaveformWindow

/// 悬浮窗口 - 始终在最上层显示
class WaveformWindow: NSWindow {
    /// 最大窗口宽度（用于文字显示）
    private let maxWidth: CGFloat = 320
    /// 最大窗口高度（波形+文字）
    private let maxHeight: CGFloat = 100

    init() {
        // 初始尺寸（会动态调整）
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 150, height: 60),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )

        // 窗口属性
        self.isOpaque = false
        self.backgroundColor = .clear
        self.level = .floating
        self.collectionBehavior = [.canJoinAllSpaces, .stationary]
        self.isMovableByWindowBackground = true
        self.hasShadow = false  // Metaball 自带视觉效果

        // 默认隐藏
        self.orderOut(nil)
    }

    /// 显示窗口 - 在鼠标所在屏幕的底部中间
    func show() {
        let mouseLocation = NSEvent.mouseLocation
        let currentScreen = NSScreen.screens.first { $0.frame.contains(mouseLocation) } ?? NSScreen.main ?? NSScreen.screens.first!

        let visibleRect = currentScreen.visibleFrame
        let size = self.frame.size
        let x = visibleRect.midX - size.width / 2
        let y = visibleRect.minY + 80

        self.setFrameOrigin(NSPoint(x: x, y: y))
        self.orderFront(nil)
    }

    /// 更新窗口尺寸（保持居中）
    func updateSize(width: CGFloat, height: CGFloat) {
        let newWidth = min(width, maxWidth)
        let newHeight = min(height, maxHeight)

        let currentFrame = self.frame
        let deltaWidth = newWidth - currentFrame.width
        let deltaHeight = newHeight - currentFrame.height

        let newX = currentFrame.origin.x - deltaWidth / 2
        let newY = currentFrame.origin.y - deltaHeight  // 向上扩展

        self.setFrame(NSRect(x: newX, y: newY, width: newWidth, height: newHeight), display: true, animate: true)
    }

    /// 隐藏窗口
    func hide() {
        self.orderOut(nil)
    }
}

// MARK: - WaveformView

/// 波形视图 - 精致的录音波纹效果
struct WaveformView: View {
    let levels: [Float]

    // 预览模式
    @State private var previewLevels: [Float] = Array(repeating: 0.3, count: 20)
    @State private var previewTimer: Timer?

    let isPreviewMode: Bool

    init(levels: [Float] = [], isPreviewMode: Bool = false) {
        self.levels = levels
        self.isPreviewMode = isPreviewMode
    }

    var body: some View {
        // 波纹
        HStack(spacing: 2) {
            let displayLevels = isPreviewMode ? previewLevels : paddedLevels

            ForEach(0..<displayLevels.count, id: \.self) { index in
                WaveformBar(level: displayLevels[index])
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 18))
        .frame(width: 120, height: 36)
        .onAppear {
            if isPreviewMode {
                startPreviewAnimation()
            }
        }
        .onDisappear {
            stopPreviewAnimation()
        }
    }

    // 确保有 20 个值
    private var paddedLevels: [Float] {
        if levels.count >= 20 {
            return Array(levels.prefix(20))
        } else if levels.isEmpty {
            return Array(repeating: 0.1, count: 20)
        } else {
            // 插值扩展到 20 个
            var result: [Float] = []
            let step = Float(levels.count - 1) / 19.0
            for i in 0..<20 {
                let idx = Float(i) * step
                let lower = Int(idx)
                let upper = min(lower + 1, levels.count - 1)
                let frac = idx - Float(lower)
                result.append(levels[lower] * (1 - frac) + levels[upper] * frac)
            }
            return result
        }
    }

    private func startPreviewAnimation() {
        previewTimer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { _ in
            withAnimation(.easeInOut(duration: 0.1)) {
                previewLevels = (0..<20).map { _ in
                    Float.random(in: 0.15...0.85)
                }
            }
        }
    }

    private func stopPreviewAnimation() {
        previewTimer?.invalidate()
        previewTimer = nil
    }
}

// MARK: - WaveformBar

/// 单个细波纹条 - 静默时淡，说话时亮
struct WaveformBar: View {
    let level: Float

    var body: some View {
        RoundedRectangle(cornerRadius: 0.5)
            .fill(.white.opacity(barOpacity))
            .frame(width: 1.5, height: barHeight)
            .animation(.easeOut(duration: 0.06), value: level)
    }

    // 高度：静默时很短，说话时变高
    private var barHeight: CGFloat {
        let minHeight: CGFloat = 3
        let maxHeight: CGFloat = 18
        return minHeight + CGFloat(level) * (maxHeight - minHeight)
    }

    // 透明度：静默时淡（0.3），说话时亮（0.95）
    private var barOpacity: Double {
        let minOpacity: Double = 0.25
        let maxOpacity: Double = 0.95
        return minOpacity + Double(level) * (maxOpacity - minOpacity)
    }
}

// AudioLevelMonitor 定义在 AudioLevelMonitor.swift 中

// MARK: - WaveformOverlayController

/// 波形悬浮窗管理器 - 单例
/// 支持 Metaball 风格的波形 + 文字显示
class WaveformOverlayController {
    static let shared = WaveformOverlayController()

    private var window: WaveformWindow?
    private var hostingView: NSHostingView<MetaballWaveformView>?
    private var monitor: AudioLevelMonitor?
    private var cancellable: AnyCancellable?

    // 当前识别文字状态
    private var recognizedText: String = ""
    private var stashText: String = ""

    private init() {}

    /// 显示波形窗口
    /// - Parameter monitor: 音频电平监控器
    func show(with monitor: AudioLevelMonitor) {
        // 重置文字状态
        recognizedText = ""
        stashText = ""

        // 创建窗口（如果不存在）
        if window == nil {
            window = WaveformWindow()
        }

        self.monitor = monitor

        // 创建 Metaball 视图
        let metaballView = MetaballWaveformView(
            levels: monitor.levels,
            recognizedText: recognizedText,
            stashText: stashText
        )
        hostingView = NSHostingView(rootView: metaballView)

        // 设置窗口内容
        window?.contentView = hostingView

        // 监听音频电平变化
        cancellable = monitor.$levels
            .receive(on: DispatchQueue.main)
            .sink { [weak self] newLevels in
                self?.updateView(levels: newLevels)
            }

        // 显示窗口
        window?.show()
    }

    /// 隐藏波形窗口
    func hide() {
        window?.hide()
        cancellable?.cancel()
        cancellable = nil
        monitor = nil
        recognizedText = ""
        stashText = ""
    }

    /// 更新识别文字（流式 ASR 调用）
    /// - Parameters:
    ///   - text: 已确认的文字
    ///   - stash: 暂存的文字（可能会变化）
    func updateText(text: String, stash: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.recognizedText = text
            self.stashText = stash
            self.updateView(levels: self.monitor?.levels ?? [])
        }
    }

    /// 清空文字
    func clearText() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.recognizedText = ""
            self.stashText = ""
            self.updateView(levels: self.monitor?.levels ?? [])
        }
    }

    /// 更新视图数据
    private func updateView(levels: [Float]) {
        guard let hostingView = hostingView else { return }

        let updatedView = MetaballWaveformView(
            levels: levels,
            recognizedText: recognizedText,
            stashText: stashText
        )
        hostingView.rootView = updatedView
    }
}

// MARK: - 预览

#if DEBUG
struct WaveformView_Previews: PreviewProvider {
    static var previews: some View {
        WaveformView(isPreviewMode: true)
            .padding()
            .background(Color.gray.opacity(0.3))
    }
}

struct MetaballWaveformView_Previews: PreviewProvider {
    static var previews: some View {
        VStack(spacing: 40) {
            // 无文字状态
            MetaballWaveformView(
                levels: (0..<20).map { _ in Float.random(in: 0.2...0.8) },
                recognizedText: "",
                stashText: ""
            )

            // 有文字状态
            MetaballWaveformView(
                levels: (0..<20).map { _ in Float.random(in: 0.2...0.8) },
                recognizedText: "你好世界",
                stashText: " 这是暂存"
            )

            // 长文字状态
            MetaballWaveformView(
                levels: (0..<20).map { _ in Float.random(in: 0.2...0.8) },
                recognizedText: "这是一段比较长的识别文字",
                stashText: ""
            )
        }
        .padding(40)
        .background(Color.black.opacity(0.8))
    }
}

/// 交互式预览 - 模拟实时效果
struct MetaballWaveformInteractivePreview: View {
    @State private var text: String = ""
    @State private var levels: [Float] = Array(repeating: 0.3, count: 20)
    @State private var timer: Timer?

    private let sampleTexts = [
        "",
        "你好",
        "你好世界",
        "你好世界，今天",
        "你好世界，今天天气",
        "你好世界，今天天气真不错",
        "",  // 清空
    ]
    @State private var textIndex = 0

    var body: some View {
        VStack(spacing: 20) {
            Text("Metaball 波形预览")
                .font(.headline)
                .foregroundColor(.white)

            MetaballWaveformView(
                levels: levels,
                recognizedText: text,
                stashText: ""
            )

            Button("切换文字") {
                textIndex = (textIndex + 1) % sampleTexts.count
                text = sampleTexts[textIndex]
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(40)
        .background(Color.black.opacity(0.85))
        .onAppear {
            startWaveformAnimation()
        }
        .onDisappear {
            timer?.invalidate()
        }
    }

    private func startWaveformAnimation() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { _ in
            withAnimation(.easeInOut(duration: 0.1)) {
                levels = (0..<20).map { _ in Float.random(in: 0.15...0.85) }
            }
        }
    }
}

#Preview("Metaball Interactive") {
    MetaballWaveformInteractivePreview()
}
#endif
