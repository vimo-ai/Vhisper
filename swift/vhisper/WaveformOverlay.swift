//
//  WaveformOverlay.swift
//  vhisper
//
//  波形可视化悬浮窗组件
//

import SwiftUI
import Combine

// MARK: - WaveformWindow

/// 悬浮窗口 - 始终在最上层显示
class WaveformWindow: NSWindow {

    init() {
        // 小巧的尺寸
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 120, height: 36),
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
        self.hasShadow = true

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
class WaveformOverlayController {
    static let shared = WaveformOverlayController()

    private var window: WaveformWindow?
    private var hostingView: NSHostingView<WaveformView>?
    private var monitor: AudioLevelMonitor?
    private var cancellable: AnyCancellable?

    private init() {}

    /// 显示波形窗口
    /// - Parameter monitor: 音频电平监控器
    func show(with monitor: AudioLevelMonitor) {
        print("🎵 WaveformOverlayController.show() 被调用")

        // 创建窗口（如果不存在）
        if window == nil {
            window = WaveformWindow()
            print("🎵 创建了新的 WaveformWindow")
        }

        self.monitor = monitor

        // 创建视图并绑定数据
        let waveformView = WaveformView(levels: monitor.levels)
        hostingView = NSHostingView(rootView: waveformView)

        // 设置窗口内容
        window?.contentView = hostingView

        // 监听数据变化并更新视图
        cancellable = monitor.$levels
            .receive(on: DispatchQueue.main)
            .sink { [weak self] newLevels in
                self?.updateView(levels: newLevels)
            }

        // 显示窗口
        window?.show()
        print("🎵 窗口已调用 show()，frame: \(window?.frame ?? .zero)")
    }

    /// 隐藏波形窗口
    func hide() {
        window?.hide()
        cancellable?.cancel()
        cancellable = nil
        monitor = nil
    }

    /// 更新视图数据
    private func updateView(levels: [Float]) {
        guard let hostingView = hostingView else { return }

        let updatedView = WaveformView(levels: levels)
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
#endif
