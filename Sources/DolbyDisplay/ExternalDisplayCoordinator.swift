import Foundation
import Cocoa
import CoreGraphics
import Metal
import QuartzCore
import os.log

private let logger = Logger(subsystem: "com.dould.DolbyDisplay", category: "ExternalDisplayCoordinator")

// MARK: - Display Evaluation

/// 屏幕评估与杜比视界匹配度评分
@MainActor
public struct DisplayEvaluation: Sendable {
    public let screen: NSScreen
    public let displayID: CGDirectDisplayID
    public let name: String
    public let isBuiltin: Bool
    public let edid: ParsedEDID?
    public let capabilities: CoreDisplayCapabilities
    public let edrState: DisplayEDRState?
    public let score: Double
    public let recommendedMode: DisplayNegotiationMode
    public let suitabilityReason: String

    public var isDolbyVisionReady: Bool {
        return (edid?.dolbyVision.isSupported == true) || capabilities.isDolbyVisionHardwareSupported
    }

    public var maxLuminanceNits: Double {
        if let dvMax = edid?.dolbyVision.targetMaxLuminance, dvMax > 0 {
            return dvMax
        }
        if let edr = edrState {
            return edr.estimatedPeakNits
        }
        return 500.0
    }
}

// MARK: - Presentation Session

/// 独立外屏全屏呈现会话 (tvOS 风格 Exclusive Fullscreen)
@MainActor
public final class DolbyPresentationSession {
    public let window: NSWindow
    public let metalLayer: CAMetalLayer
    public let screen: NSScreen
    public let displayID: CGDirectDisplayID
    public let evaluation: DisplayEvaluation

    private var keyEventMonitor: Any?
    private var isDismissed = false

    public init(
        window: NSWindow,
        metalLayer: CAMetalLayer,
        screen: NSScreen,
        displayID: CGDirectDisplayID,
        evaluation: DisplayEvaluation
    ) {
        self.window = window
        self.metalLayer = metalLayer
        self.screen = screen
        self.displayID = displayID
        self.evaluation = evaluation

        setupKeyMonitor()
    }

    private func setupKeyMonitor() {
        // 监听 Esc 键退出全屏
        keyEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { // Escape
                self?.dismiss()
                return nil
            }
            return event
        }
    }

    /// 动态更新 Metal 图层的颜色空间与 EDR 参数
    public func configureColorSpace(name: CFString = CGColorSpace.extendedLinearDisplayP3) {
        if let cs = CGColorSpace(name: name) {
            metalLayer.colorspace = cs
        }
        metalLayer.wantsExtendedDynamicRangeContent = true
    }

    /// 隐藏鼠标光标 (播放开始时调用)
    public func hideCursor() {
        NSCursor.hide()
    }

    /// 恢复鼠标光标
    public func unhideCursor() {
        NSCursor.unhide()
    }

    /// 关闭全屏窗口并结束呈现会话
    public func dismiss() {
        guard !isDismissed else { return }
        isDismissed = true

        if let monitor = keyEventMonitor {
            NSEvent.removeMonitor(monitor)
            keyEventMonitor = nil
        }

        unhideCursor()
        window.orderOut(nil)
        window.close()
        logger.info("DolbyPresentationSession dismissed for display \(self.displayID)")
    }
}

// MARK: - ExternalDisplayCoordinator

/// 负责全系统屏幕探测、杜比视界适配度裁决与独立全屏 Metal 画布投屏的协调中枢
@MainActor
public final class ExternalDisplayCoordinator {

    public static let shared = ExternalDisplayCoordinator()

    public private(set) var activeSession: DolbyPresentationSession?

    private init() {}

    // MARK: - 屏幕拓扑综合评估

    /// 评估当前系统中所有连接的屏幕，按杜比视界最适度从高到低排序
    public func evaluateAllDisplays() -> [DisplayEvaluation] {
        var evaluations: [DisplayEvaluation] = []
        let screens = NSScreen.screens
        let edrManager = DisplayEDRManager.shared
        let bridge = CoreDisplayBridge.shared

        for screen in screens {
            guard let displayID = screen.displayID else { continue }
            let isBuiltin = CGDisplayIsBuiltin(displayID) != 0
            let name = screen.localizedName

            // 1. 抓取并解析 EDID
            var parsedEDID: ParsedEDID? = nil
            if let edidData = EDIDParser.fetchEDID(for: displayID) {
                parsedEDID = EDIDParser.parse(data: edidData)
            }

            // 2. 探测底层 CoreDisplay 能力
            let caps = bridge.probeDisplayCapabilities(displayID: displayID)

            // 3. 提取 EDR 亮度状态
            let edrState = edrManager.state(for: displayID)

            // 4. 计算杜比匹配得分与推荐模式
            let (score, recommendedMode, reason) = computeSuitabilityScore(
                isBuiltin: isBuiltin,
                edid: parsedEDID,
                caps: caps,
                edr: edrState
            )

            let eval = DisplayEvaluation(
                screen: screen,
                displayID: displayID,
                name: name,
                isBuiltin: isBuiltin,
                edid: parsedEDID,
                capabilities: caps,
                edrState: edrState,
                score: score,
                recommendedMode: recommendedMode,
                suitabilityReason: reason
            )

            evaluations.append(eval)
        }

        // 按得分从高到低排序
        return evaluations.sorted { $0.score > $1.score }
    }

    /// 挑选当前系统中播放杜比视界的最优屏幕
    public func findBestDisplayForDolbyVision() -> DisplayEvaluation? {
        return evaluateAllDisplays().first
    }

    // MARK: - 匹配度智能仲裁算法

    private func computeSuitabilityScore(
        isBuiltin: Bool,
        edid: ParsedEDID?,
        caps: CoreDisplayCapabilities,
        edr: DisplayEDRState?
    ) -> (score: Double, mode: DisplayNegotiationMode, reason: String) {
        let dv = edid?.dolbyVision

        // 优先级 1: 外接显示器明确支持 Dolby Vision (VSVDB OUI 0x00D046 命中)
        if !isBuiltin, let dv = dv, dv.isSupported {
            let baseScore = 10000.0
            let lumBonus = min(4000.0, dv.targetMaxLuminance)
            let modeBonus: Double
            let chosenMode: DisplayNegotiationMode

            switch dv.mode {
            case .both:
                modeBonus = 500.0
                chosenMode = .dolbyVisionLLDV()
            case .lldv:
                modeBonus = 400.0
                chosenMode = .dolbyVisionLLDV()
            case .standard:
                modeBonus = 300.0
                chosenMode = .dolbyVisionStandardTunnel()
            case .unsupported:
                modeBonus = 0.0
                chosenMode = .nativeEDR()
            }

            let totalScore = baseScore + lumBonus + modeBonus
            let reason = "外接屏幕原生支持杜比视界 [\(dv.mode.description)], 目标亮度: \(Int(dv.targetMaxLuminance)) nits"
            return (totalScore, chosenMode, reason)
        }

        // 优先级 2: 外接显示器支持高动态范围 (HDR10 / EDR 裕度 > 1.0)
        let headroom = edr?.currentHeadroom ?? 1.0
        if !isBuiltin && (headroom > 1.001 || caps.isHDRModeActive) {
            let baseScore = 5000.0
            let edrBonus = Double(headroom) * 1000.0
            let totalScore = baseScore + edrBonus
            let reason = "外接 HDR 显示器, 实时可用 EDR 亮度裕度: \(String(format: "%.2f", headroom))x"
            return (totalScore, .nativeEDR(), reason)
        }

        // 优先级 3: 内建 Liquid Retina XDR 屏幕 (如 14/16 英寸 MacBook Pro Mini-LED)
        if isBuiltin && headroom > 1.001 {
            let baseScore = 3000.0
            let edrBonus = Double(headroom) * 800.0
            let totalScore = baseScore + edrBonus
            let reason = "内建 Liquid Retina XDR 顶级屏幕, 实时 EDR 亮度裕度: \(String(format: "%.2f", headroom))x"
            return (totalScore, .nativeEDR(), reason)
        }

        // 优先级 4: 外接 SDR 显示器
        if !isBuiltin {
            let totalScore = 1000.0
            let reason = "普通外接 SDR 显示器 (降级至 BT.709 色彩映射呈现)"
            return (totalScore, .preserveCurrent, reason)
        }

        // 优先级 5: 内建标准 SDR 屏幕
        let totalScore = 500.0
        let reason = "内建标准 SDR 屏幕"
        return (totalScore, .preserveCurrent, reason)
    }

    // MARK: - 独立全屏投屏与 Metal 图层挂载

    /// 在指定屏幕上以独立全屏模式 (Exclusive Space / Secondary Screen Fullscreen) 打开窗口并绑定 Metal 渲染图层
    /// - Parameters:
    ///   - targetScreen: 目标屏幕 (默认为系统评估最佳屏幕)
    ///   - device: Metal 设备 (默认 MTLCreateSystemDefaultDevice)
    /// - Returns: 成功启动的 DolbyPresentationSession 会话
    public func presentExclusiveFullscreen(
        on targetScreen: NSScreen? = nil,
        device: MTLDevice? = MTLCreateSystemDefaultDevice()
    ) throws -> DolbyPresentationSession {
        // 若已有活动会话，先正常销毁
        activeSession?.dismiss()

        // 确定目标屏幕
        let evaluation: DisplayEvaluation
        if let targetScreen = targetScreen {
            let evals = evaluateAllDisplays()
            evaluation = evals.first { $0.screen == targetScreen } ?? DisplayEvaluation(
                screen: targetScreen,
                displayID: targetScreen.displayID ?? 0,
                name: targetScreen.localizedName,
                isBuiltin: CGDisplayIsBuiltin(targetScreen.displayID ?? 0) != 0,
                edid: nil,
                capabilities: CoreDisplayBridge.shared.probeDisplayCapabilities(displayID: targetScreen.displayID ?? 0),
                edrState: DisplayEDRManager.shared.state(for: targetScreen.displayID ?? 0),
                score: 1000.0,
                recommendedMode: .nativeEDR(),
                suitabilityReason: "User manually selected screen"
            )
        } else {
            guard let best = findBestDisplayForDolbyVision() else {
                throw NSError(
                    domain: "ExternalDisplayCoordinator",
                    code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "No active display available for Dolby Vision presentation"]
                )
            }
            evaluation = best
        }

        let screen = evaluation.screen
        let displayID = evaluation.displayID

        logger.info("Presenting exclusive fullscreen Dolby canvas on screen [\(evaluation.name)] (displayID: \(displayID))")

        // 1. 尝试协商最佳底层显示模式
        let negotiation = CoreDisplayBridge.shared.negotiateDisplayMode(
            for: displayID,
            preferredMode: evaluation.recommendedMode
        )
        logger.info("Display mode negotiation result: \(negotiation.appliedModeDescription)")

        // 2. 创建独立全屏无边框窗口 (贴合目标屏幕完整几何 Frame)
        let window = NSWindow(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false,
            screen: screen
        )

        // 3. 配置 tvOS 沉浸式窗口属性与层级
        window.setFrame(screen.frame, display: true)
        window.level = .screenSaver // 置于 Dock 和系统菜单栏之上
        window.collectionBehavior = [
            .fullScreenPrimary,
            .canJoinAllSpaces,
            .stationary,
            .ignoresCycle
        ]
        window.isOpaque = true
        window.backgroundColor = .black
        window.hasShadow = false
        window.hidesOnDeactivate = false
        window.canHide = false

        // 4. 配置根容器视图与 CAMetalLayer
        let contentView = NSView(frame: window.contentRect(forFrameRect: screen.frame))
        contentView.wantsLayer = true

        guard let metalDevice = device else {
            throw NSError(
                domain: "ExternalDisplayCoordinator",
                code: -2,
                userInfo: [NSLocalizedDescriptionKey: "Failed to initialize Metal device for rendering"]
            )
        }

        let metalLayer = CAMetalLayer()
        metalLayer.device = metalDevice
        metalLayer.pixelFormat = .rgba16Float // 杜比视变 / HDR 渲染必备 16-bit 浮点缓冲区
        metalLayer.framebufferOnly = true
        metalLayer.isOpaque = true

        // 开启 Extended Dynamic Range 扩展高动态范围支持
        metalLayer.wantsExtendedDynamicRangeContent = true

        // 根据模式配置颜色空间
        if let cs = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3) {
            metalLayer.colorspace = cs
        }

        metalLayer.frame = contentView.bounds
        metalLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        metalLayer.contentsScale = screen.backingScaleFactor

        contentView.layer = metalLayer
        window.contentView = contentView

        // 5. 显示窗口并夺取焦点
        window.makeKeyAndOrderFront(nil)

        let session = DolbyPresentationSession(
            window: window,
            metalLayer: metalLayer,
            screen: screen,
            displayID: displayID,
            evaluation: evaluation
        )

        self.activeSession = session
        return session
    }

    /// 关闭当前活动的投屏会话
    public func stopActiveSession() {
        activeSession?.dismiss()
        activeSession = nil
    }
}
