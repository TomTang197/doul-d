import Foundation
import Cocoa
import CoreGraphics
import os.log

private let logger = Logger(subsystem: "com.dould.DolbyDisplay", category: "DisplayEDRManager")

// MARK: - Display EDR State

/// 单个屏幕的 EDR 亮度与动态范围状态
public struct DisplayEDRState: Sendable, Equatable {
    public let displayID: CGDirectDisplayID
    public let screenName: String
    public let isBuiltin: Bool

    /// 当前可用的 EDR 亮度裕度 (例如 1.0 代表 SDR, 2.0 代表 2倍 SDR 亮度, 最高可达 4.0 ~ 16.0)
    public let currentHeadroom: CGFloat

    /// 若用户调低 SDR 亮度滑块，该屏幕理论上支持的最大潜在裕度
    public let maxPotentialHeadroom: CGFloat

    /// 参考模式下的 EDR 裕度 (若屏幕处于专业参考预设模式)
    public let maxReferenceHeadroom: CGFloat

    /// 估算的基准 SDR 白点亮度 (通常为 100 ~ 200 nits)
    public let estimatedSDRWhiteNits: Double

    /// 当前实际能够输出的最大峰值亮度 (currentHeadroom * estimatedSDRWhiteNits)
    public let estimatedPeakNits: Double

    /// 是否具备超出 SDR 的扩展动态范围能力
    public var isEDRAvailable: Bool {
        return currentHeadroom > 1.001
    }

    public static func == (lhs: DisplayEDRState, rhs: DisplayEDRState) -> Bool {
        return lhs.displayID == rhs.displayID &&
               abs(lhs.currentHeadroom - rhs.currentHeadroom) < 0.005 &&
               abs(lhs.maxPotentialHeadroom - rhs.maxPotentialHeadroom) < 0.005 &&
               lhs.screenName == rhs.screenName
    }
}

// MARK: - DisplayEDRManager

/// 负责监听 macOS 屏幕拓扑与 EDR 亮度裕度变化的高精度管理器
@MainActor
public final class DisplayEDRManager: NSObject {

    public static let shared = DisplayEDRManager()

    /// 当前所有检测到的显示器状态映射 [CGDirectDisplayID: DisplayEDRState]
    public private(set) var currentStates: [CGDirectDisplayID: DisplayEDRState] = [:]

    /// 监听回调：当 EDR 亮度裕度或屏幕参数发生变化时触发
    public var onHeadroomChanged: (([CGDirectDisplayID: DisplayEDRState]) -> Void)?

    /// 监听回调：当屏幕插拔 (Topology Change) 时触发
    public var onDisplaysChanged: (([CGDirectDisplayID: DisplayEDRState]) -> Void)?

    private var pollTimer: Timer?
    private var isMonitoring = false

    // AsyncStream 广播通道
    private var streamContinuations: [UUID: AsyncStream<[CGDirectDisplayID: DisplayEDRState]>.Continuation] = [:]

    public override init() {
        super.init()
        updateAllScreenStates()
        startMonitoring()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - 监听生命周期

    /// 启动屏幕参数通知与高精度亮度裕度采样轮询
    public func startMonitoring() {
        guard !isMonitoring else { return }
        isMonitoring = true

        // 1. 监听系统屏幕参数变化通知 (插拔外屏、改变分辨率/色彩描述文件)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleScreenParametersChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )

        // 2. 监听色彩空间变化通知
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleColorSpaceChanged),
            name: NSScreen.colorSpaceDidChangeNotification,
            object: nil
        )

        // 3. 开启平滑亮度采样定时器 (macOS 亮度滑块微调与环境光感应不会发送通知，通过 2Hz 采样捕获)
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.pollHeadroomChanges()
            }
        }

        logger.info("DisplayEDRManager monitoring started successfully")
    }

    /// 停止监听
    public func stopMonitoring() {
        guard isMonitoring else { return }
        isMonitoring = false
        NotificationCenter.default.removeObserver(self)
        pollTimer?.invalidate()
        pollTimer = nil

        for continuation in streamContinuations.values {
            continuation.finish()
        }
        streamContinuations.removeAll()

        logger.info("DisplayEDRManager monitoring stopped")
    }

    // MARK: - 状态刷新与采样

    @objc private func handleScreenParametersChanged(_ notification: Notification) {
        logger.info("Display topology parameter change notification received")
        let oldStates = currentStates
        updateAllScreenStates()
        onDisplaysChanged?(currentStates)
        broadcastStates()

        if oldStates != currentStates {
            onHeadroomChanged?(currentStates)
        }
    }

    @objc private func handleColorSpaceChanged(_ notification: Notification) {
        logger.info("Screen color space changed notification received")
        updateAllScreenStates()
        broadcastStates()
        onHeadroomChanged?(currentStates)
    }

    private func pollHeadroomChanges() {
        var hasChanges = false
        let screens = NSScreen.screens

        for screen in screens {
            guard let displayID = screen.displayID else { continue }
            let headroom = screen.maximumExtendedDynamicRangeColorComponentValue
            let potential = screen.maximumPotentialExtendedDynamicRangeColorComponentValue

            if let existing = currentStates[displayID] {
                if abs(existing.currentHeadroom - headroom) > 0.01 ||
                   abs(existing.maxPotentialHeadroom - potential) > 0.01 {
                    hasChanges = true
                    break
                }
            } else {
                hasChanges = true
                break
            }
        }

        if hasChanges {
            updateAllScreenStates()
            broadcastStates()
            onHeadroomChanged?(currentStates)
        }
    }

    /// 重新扫描所有 NSScreen 并构建 EDR 状态
    public func updateAllScreenStates() {
        var newStates: [CGDirectDisplayID: DisplayEDRState] = [:]
        let screens = NSScreen.screens

        for screen in screens {
            guard let displayID = screen.displayID else { continue }
            let isBuiltin = CGDisplayIsBuiltin(displayID) != 0

            // 提取 EDR 裕度
            let headroom = max(1.0, screen.maximumExtendedDynamicRangeColorComponentValue)
            let potential = max(1.0, screen.maximumPotentialExtendedDynamicRangeColorComponentValue)
            let reference = max(1.0, screen.maximumReferenceExtendedDynamicRangeColorComponentValue)

            // 计算基准白与估算峰值亮度
            var sdrWhite: Double = 100.0 // 标准 SDR 基准参考白点 (100 nits)
            if isBuiltin {
                // MacBook Pro Liquid Retina XDR 内屏典型默认 SDR 呈现约 160 ~ 200 nits
                sdrWhite = 160.0
            }

            // 结合 EDID 深度校正 (若存在目标最大亮度)
            var estimatedPeak = Double(headroom) * sdrWhite
            if let edid = EDIDParser.fetchEDID(for: displayID),
               let parsed = EDIDParser.parse(data: edid),
               parsed.dolbyVision.isSupported {
                estimatedPeak = max(estimatedPeak, parsed.dolbyVision.targetMaxLuminance)
            }

            let state = DisplayEDRState(
                displayID: displayID,
                screenName: screen.localizedName,
                isBuiltin: isBuiltin,
                currentHeadroom: headroom,
                maxPotentialHeadroom: potential,
                maxReferenceHeadroom: reference,
                estimatedSDRWhiteNits: sdrWhite,
                estimatedPeakNits: estimatedPeak
            )

            newStates[displayID] = state
        }

        self.currentStates = newStates
    }

    // MARK: - 查询接口

    /// 获取指定屏幕的当前 EDR 状态
    public func state(for displayID: CGDirectDisplayID) -> DisplayEDRState? {
        return currentStates[displayID]
    }

    /// 获取系统中最佳的外接 HDR/EDR 屏幕状态
    public func bestExternalEDRScreen() -> DisplayEDRState? {
        return currentStates.values
            .filter { !$0.isBuiltin }
            .max { $0.currentHeadroom < $1.currentHeadroom }
    }

    // MARK: - Swift Concurrency 异步流支持

    /// 订阅 EDR 状态变化的 AsyncStream
    public func statesStream() -> AsyncStream<[CGDirectDisplayID: DisplayEDRState]> {
        let id = UUID()
        return AsyncStream { continuation in
            // 发送初始状态
            continuation.yield(self.currentStates)
            self.streamContinuations[id] = continuation

            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in
                    self?.streamContinuations.removeValue(forKey: id)
                }
            }
        }
    }

    private func broadcastStates() {
        for continuation in streamContinuations.values {
            continuation.yield(currentStates)
        }
    }
}

// MARK: - NSScreen 扩展辅助方法

extension NSScreen {
    /// 获取当前屏幕对应的 CGDirectDisplayID
    public var displayID: CGDirectDisplayID? {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        guard let screenNumber = deviceDescription[key] as? NSNumber else {
            return nil
        }
        return CGDirectDisplayID(screenNumber.uint32Value)
    }
}
