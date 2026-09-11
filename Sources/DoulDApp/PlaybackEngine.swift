import Foundation
import SwiftUI
import CoreMedia
import CoreVideo
import Metal
import QuartzCore
import DolbyCore
import DolbyMetal
import DolbyDisplay

/// 播放与渲染调度核心引擎
@MainActor
public final class PlaybackEngine: ObservableObject {
    // MARK: - Published 状态
    
    @Published public var currentProfile: DolbyVisionProfile = .profile7FEL
    @Published public var isProfile7Rewritten: Bool = true
    @Published public var targetProfile: DolbyVisionProfile = .profile81
    
    @Published public var videoWidth: Int = 3840
    @Published public var videoHeight: Int = 2160
    @Published public var fps: Double = 23.976
    
    // 动态元数据 (Level 1)
    @Published public var minLuminanceNits: Double = 0.005
    @Published public var maxLuminanceNits: Double = 1000.0
    @Published public var avgLuminanceNits: Double = 180.0
    
    // 渲染模式
    @Published public var renderMode: DVRenderMode = .lldvTunneling
    @Published public var isPlaying: Bool = false
    @Published public var currentPlaybackTime: Double = 0.0
    @Published public var totalDuration: Double = 7200.0 // 示例时长
    
    // 显示器状态
    @Published public var bestExternalDisplay: DisplayEvaluation?
    @Published public var isExternalPresentationActive: Bool = false
    @Published public var currentEDRHeadroom: Double = 1.0
    
    // 日志与诊断输出
    @Published public var diagnosticsLog: [String] = []
    
    // MARK: - 底层组件
    public let metalRenderer: DVMetalRenderer?
    public let edrManager: DisplayEDRManager
    public let displayCoordinator: ExternalDisplayCoordinator
    private var presentationSession: DolbyPresentationSession?
    
    private var playbackTimer: Timer?
    
    public init() {
        self.metalRenderer = DVMetalRenderer()
        self.edrManager = DisplayEDRManager.shared
        self.displayCoordinator = ExternalDisplayCoordinator.shared
        
        setupDiagnostics()
        refreshDisplayTopology()
    }
    
    // MARK: - 显示器拓扑探测与模式协商
    
    public func refreshDisplayTopology() {
        bestExternalDisplay = displayCoordinator.findBestDisplayForDolbyVision()
        
        if let best = bestExternalDisplay {
            let dvDesc = best.edid?.dolbyVision.mode.description ?? (best.capabilities.isDolbyVisionHardwareSupported ? "系统硬件支持" : "无")
            let headroom = best.edrState?.currentHeadroom ?? 1.0
            let peakNits = best.edrState?.estimatedPeakNits ?? 500.0
            
            appendLog("🔍 发现最佳输出显示设备: \(best.name) (ID: \(best.displayID))")
            appendLog("   - 杜比视界支持: \(dvDesc)")
            appendLog("   - 当前 EDR 裕度: \(String(format: "%.2fx", headroom)) (峰值约 \(Int(peakNits)) nits)")
            
            // 自动匹配推荐模式
            switch best.recommendedMode {
            case .dolbyVisionLLDV, .dolbyVisionStandardTunnel:
                renderMode = .lldvTunneling
                appendLog("   -> 推荐启用 LLDV 杜比视界 RGB 隧道封装直通")
            case .nativeEDR:
                renderMode = .nativeAppleEDR
                appendLog("   -> 推荐启用 Apple 原生 EDR 宽动态范围呈现")
            default:
                renderMode = .nativeAppleEDR
            }
        } else {
            appendLog("⚠️ 未检测到外接 HDR/杜比显示器，采用内建屏幕 EDR 渲染模式")
            renderMode = .nativeAppleEDR
        }
    }
    
    // MARK: - 投屏与独立全屏管理
    
    public func toggleExternalPresentation() {
        if isExternalPresentationActive {
            stopExternalPresentation()
        } else {
            startExternalPresentation()
        }
    }
    
    public func startExternalPresentation() {
        guard let best = bestExternalDisplay, let renderer = metalRenderer else {
            appendLog("❌ 无法启动外屏投屏: 无有效外屏或 Metal 初始化失败")
            return
        }
        
        appendLog("🚀 正在向外屏 [\(best.name)] 发起独立全屏呈现...")
        do {
            let session = try displayCoordinator.presentExclusiveFullscreen(
                on: best.screen,
                device: renderer.device
            )
            
            // 配置全屏图层
            if renderMode == .lldvTunneling {
                DVMetalLayerConfig.configureForLLDVTunnel(layer: session.metalLayer)
            } else {
                DVMetalLayerConfig.configureForEDR(layer: session.metalLayer)
            }
            self.presentationSession = session
            self.isExternalPresentationActive = true
            appendLog("✅ 外屏独立全屏会话建立成功，已锁定专属渲染管线")
        } catch {
            appendLog("❌ 启动外屏全屏失败: \(error.localizedDescription)")
        }
    }
    
    public func stopExternalPresentation() {
        presentationSession?.dismiss()
        presentationSession = nil
        isExternalPresentationActive = false
        appendLog("⏹ 已退出外屏独立全屏呈现")
    }
    
    // MARK: - 模拟/测试片源加载与 Profile 7 重构演示
    
    public func loadDemoStream(profile: DolbyVisionProfile) {
        currentProfile = profile
        appendLog("🎬 加载杜比视界媒体流: \(profile.description)")
        
        switch profile {
        case .profile7, .profile7FEL, .profile7MEL:
            isProfile7Rewritten = true
            targetProfile = .profile81
            appendLog("⚡️ 触发 tvOS 机制：实时捕获 NALU 62 (RPU)，清除 EL 重采样与残差")
            appendLog("✅ 已动态重构为合法 Profile 8.1 规范 (兼容 Rec.2020 + SMPTE ST 2084 PQ)")
            minLuminanceNits = 0.001
            maxLuminanceNits = 4000.0
            avgLuminanceNits = 240.0
            
        case .profile5:
            isProfile5Loaded()
            
        case .profile81, .profile84:
            isProfile7Rewritten = false
            targetProfile = profile
            appendLog("ℹ️ 单层杜比视界直接送入硬件硬解与色调映射")
            minLuminanceNits = 0.005
            maxLuminanceNits = 1000.0
            avgLuminanceNits = 150.0
            
        default:
            isProfile7Rewritten = false
            targetProfile = profile
        }
    }
    
    private func isProfile5Loaded() {
        isProfile7Rewritten = false
        targetProfile = .profile5
        appendLog("🌈 流媒体 Profile 5 (IPT 颜色空间) - 启用 Metal 专用 IPTPQc2 逆色彩解算矩阵")
        appendLog("✅ 消除发紫发绿，映射至 Rec.2020 宽色域")
        minLuminanceNits = 0.0001
        maxLuminanceNits = 1000.0
        avgLuminanceNits = 180.0
    }
    
    public func togglePlayback() {
        isPlaying.toggle()
        if isPlaying {
            startPlaybackTimer()
            appendLog("▶️ 播放开始")
        } else {
            playbackTimer?.invalidate()
            playbackTimer = nil
            appendLog("⏸ 播放暂停")
        }
    }
    
    private func startPlaybackTimer() {
        playbackTimer?.invalidate()
        playbackTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self = self, self.isPlaying else { return }
                self.currentPlaybackTime += 1.0
                if self.currentPlaybackTime > self.totalDuration {
                    self.currentPlaybackTime = 0.0
                }
                
                // 模拟场景动态元数据变化
                let variation = sin(self.currentPlaybackTime * 0.1) * 200.0
                self.maxLuminanceNits = max(600.0, min(4000.0, 1000.0 + variation))
                self.avgLuminanceNits = max(100.0, min(500.0, 200.0 + variation * 0.2))
            }
        }
    }
    
    private func setupDiagnostics() {
        appendLog("🚀 Doul D 杜比视界播放引擎初始化完成")
        appendLog("🔧 Apple Silicon 硬件加速渲染管线就绪 (Metal 3.0)")
    }
    
    public func appendLog(_ message: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        let timestamp = formatter.string(from: Date())
        diagnosticsLog.append("[\(timestamp)] \(message)")
        if diagnosticsLog.count > 100 {
            diagnosticsLog.removeFirst(diagnosticsLog.count - 100)
        }
    }
}
