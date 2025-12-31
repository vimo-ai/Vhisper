//
//  VhisperBridge.swift
//  vhisper
//
//  Swift 封装层 - 提供类型安全的 API
//

import Foundation
import VhisperCore

/// Vhisper 核心封装
public final class Vhisper {

    // MARK: - Types

    /// 状态枚举
    public enum State: Int32 {
        case idle = 0
        case recording = 1
        case processing = 2
        case invalid = -1
    }

    /// 结果类型
    public enum Result {
        case success(String)
        case failure(Error)
        case cancelled
    }

    /// 流式识别事件
    public enum StreamingEvent {
        /// 中间结果
        /// - text: 已确认的文本
        /// - stash: 暂定文本（可能被后续修正）
        case partial(text: String, stash: String)
        /// 最终结果
        case final(text: String)
        /// 错误
        case error(String)
    }

    /// 错误类型
    public enum VhisperError: Error, LocalizedError {
        case invalidHandle
        case startFailed
        case configParseFailed
        case cancelled
        case processingFailed(String)

        public var errorDescription: String? {
            switch self {
            case .invalidHandle: return "Invalid Vhisper handle"
            case .startFailed: return "Failed to start recording"
            case .configParseFailed: return "Failed to parse config JSON"
            case .cancelled: return "Operation cancelled"
            case .processingFailed(let msg): return msg
            }
        }
    }

    // MARK: - Properties

    private var handle: OpaquePointer?

    /// 获取当前状态
    public var state: State {
        guard let h = handle else { return .invalid }
        return State(rawValue: vhisper_get_state(h)) ?? .invalid
    }

    /// 是否正在录音
    public var isRecording: Bool {
        return state == .recording
    }

    /// 是否正在处理
    public var isProcessing: Bool {
        return state == .processing
    }

    /// 是否空闲
    public var isIdle: Bool {
        return state == .idle
    }

    /// 是否在流式模式
    public var isStreaming: Bool {
        guard let h = handle else { return false }
        return vhisper_is_streaming(h) == 1
    }

    // MARK: - Lifecycle

    /// 初始化
    /// - Parameter configJSON: 可选的 JSON 配置字符串
    public init(configJSON: String? = nil) throws {
        if let json = configJSON {
            handle = json.withCString { vhisper_create($0) }
        } else {
            handle = vhisper_create(nil)
        }

        guard handle != nil else {
            throw VhisperError.invalidHandle
        }
    }

    deinit {
        if let h = handle {
            vhisper_destroy(h)
        }
    }

    // MARK: - Recording Control

    /// 开始录音
    public func startRecording() throws {
        guard let h = handle else { throw VhisperError.invalidHandle }

        let result = vhisper_start_recording(h)
        if result != 0 {
            throw VhisperError.startFailed
        }
    }

    /// 停止录音并处理（回调版本）
    /// - Parameter completion: 完成回调，在后台线程调用
    public func stopRecording(completion: @escaping (Result) -> Void) {
        guard let h = handle else {
            completion(.failure(VhisperError.invalidHandle))
            return
        }

        let context = CallbackContext(completion: completion)
        let contextPtr = Unmanaged.passRetained(context).toOpaque()

        vhisper_stop_recording(h, { ctx, text, error in
            guard let ctx = ctx else { return }

            let context = Unmanaged<CallbackContext>.fromOpaque(ctx).takeRetainedValue()

            if let errorPtr = error {
                let errorMsg = String(cString: errorPtr)
                if errorMsg.lowercased().contains("cancel") {
                    context.completion(.cancelled)
                } else {
                    context.completion(.failure(VhisperError.processingFailed(errorMsg)))
                }
            } else if let textPtr = text {
                let result = String(cString: textPtr)
                context.completion(.success(result))
            } else {
                context.completion(.failure(VhisperError.processingFailed("Unknown error")))
            }
        }, contextPtr)
    }

    /// 取消当前操作
    public func cancel() throws {
        guard let h = handle else { throw VhisperError.invalidHandle }
        _ = vhisper_cancel(h)
    }

    // MARK: - Streaming Control

    /// 开始流式录音和识别
    /// - Parameter onEvent: 事件回调，在后台线程调用
    public func startStreaming(onEvent: @escaping (StreamingEvent) -> Void) throws {
        guard let h = handle else { throw VhisperError.invalidHandle }

        let context = StreamingCallbackContext(onEvent: onEvent)
        let contextPtr = Unmanaged.passRetained(context).toOpaque()

        let result = vhisper_start_streaming(h, { ctx, eventType, text, stash, error in
            guard let ctx = ctx else { return }

            // 只有在 Final 或 Error 时才释放 context
            let isFinal = eventType == 1 || eventType == 2
            let context: StreamingCallbackContext
            if isFinal {
                context = Unmanaged<StreamingCallbackContext>.fromOpaque(ctx).takeRetainedValue()
            } else {
                context = Unmanaged<StreamingCallbackContext>.fromOpaque(ctx).takeUnretainedValue()
            }

            switch eventType {
            case 0: // Partial
                let textStr = text.map { String(cString: $0) } ?? ""
                let stashStr = stash.map { String(cString: $0) } ?? ""
                context.onEvent(.partial(text: textStr, stash: stashStr))
            case 1: // Final
                let textStr = text.map { String(cString: $0) } ?? ""
                context.onEvent(.final(text: textStr))
            case 2: // Error
                let errorStr = error.map { String(cString: $0) } ?? "Unknown error"
                context.onEvent(.error(errorStr))
            default:
                break
            }
        }, contextPtr)

        if result != 0 {
            Unmanaged<StreamingCallbackContext>.fromOpaque(contextPtr).release()
            throw VhisperError.startFailed
        }
    }

    /// 停止流式录音
    /// 提交当前音频缓冲区，回调会收到 final 事件
    public func stopStreaming() throws {
        guard let h = handle else { throw VhisperError.invalidHandle }
        _ = vhisper_stop_streaming(h)
    }

    /// 取消流式识别
    /// 停止录音并丢弃数据，不会触发 final 回调
    public func cancelStreaming() throws {
        guard let h = handle else { throw VhisperError.invalidHandle }
        _ = vhisper_cancel_streaming(h)
    }

    // MARK: - Configuration

    /// 更新配置
    /// - Parameter configJSON: 新的 JSON 配置
    public func updateConfig(_ configJSON: String) throws {
        guard let h = handle else { throw VhisperError.invalidHandle }

        let result = configJSON.withCString { vhisper_update_config(h, $0) }
        if result == -2 {
            throw VhisperError.configParseFailed
        } else if result != 0 {
            throw VhisperError.invalidHandle
        }
    }

    // MARK: - Static

    /// 获取版本号
    public static var version: String {
        guard let ptr = vhisper_version() else { return "unknown" }
        return String(cString: ptr)
    }
}

// MARK: - Callback Contexts

private class CallbackContext {
    let completion: (Vhisper.Result) -> Void

    init(completion: @escaping (Vhisper.Result) -> Void) {
        self.completion = completion
    }
}

private class StreamingCallbackContext {
    let onEvent: (Vhisper.StreamingEvent) -> Void

    init(onEvent: @escaping (Vhisper.StreamingEvent) -> Void) {
        self.onEvent = onEvent
    }
}

// MARK: - Async/Await Extension

extension Vhisper {
    /// 停止录音并处理（async 版本）
    @MainActor
    public func stopRecording() async throws -> String {
        return try await withCheckedThrowingContinuation { continuation in
            stopRecording { result in
                DispatchQueue.main.async {
                    switch result {
                    case .success(let text):
                        continuation.resume(returning: text)
                    case .failure(let error):
                        continuation.resume(throwing: error)
                    case .cancelled:
                        continuation.resume(throwing: VhisperError.cancelled)
                    }
                }
            }
        }
    }

    /// 开始流式录音并返回 AsyncStream
    ///
    /// 使用方式:
    /// ```swift
    /// for await event in try vhisper.startStreamingAsync() {
    ///     switch event {
    ///     case .partial(let text, let stash):
    ///         print("中间结果: \(text) + \(stash)")
    ///     case .final(let text):
    ///         print("最终结果: \(text)")
    ///     case .error(let msg):
    ///         print("错误: \(msg)")
    ///     }
    /// }
    /// ```
    public func startStreamingAsync() throws -> AsyncStream<StreamingEvent> {
        return AsyncStream { continuation in
            do {
                try startStreaming { event in
                    continuation.yield(event)
                    // 在 final 或 error 时结束流
                    if case .final = event {
                        continuation.finish()
                    } else if case .error = event {
                        continuation.finish()
                    }
                }
            } catch {
                continuation.yield(.error(error.localizedDescription))
                continuation.finish()
            }
        }
    }
}
