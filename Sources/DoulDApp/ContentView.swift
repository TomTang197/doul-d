import SwiftUI
import DolbyCore
import DolbyMetal
import DolbyDisplay

public struct ContentView: View {
    @StateObject private var engine = PlaybackEngine()
    @State private var showLogs = false
    
    public init() {}
    
    public var body: some View {
        VStack(spacing: 0) {
            // 顶部工具栏
            topToolBar
            
            Divider()
            
            // 中部主渲染区与悬浮 HUD
            ZStack {
                Color.black.edgesIgnoringSafeArea(.all)
                
                MetalVideoView(engine: engine)
                    .aspectRatio(16/9, contentMode: .fit)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.white.opacity(0.1), lineWidth: 1)
                    )
                    .padding(16)
                
                // 悬浮 HUD 标签
                VStack {
                    HStack {
                        profileBadge(engine.currentProfile)
                        
                        if engine.isProfile7Rewritten {
                            HStack(spacing: 4) {
                                Image(systemName: "arrow.triangle.swap")
                                Text("tvOS 机制: Profile 7 -> 8.1 实时重构")
                            }
                            .font(.caption.bold())
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.purple.opacity(0.85))
                            .foregroundColor(.white)
                            .cornerRadius(6)
                        }
                        
                        Spacer()
                        
                        // 渲染模式徽标
                        Text(engine.renderMode == .lldvTunneling ? "LLDV 杜比隧道直通" : "Apple 原生 EDR")
                            .font(.caption.bold())
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(engine.renderMode == .lldvTunneling ? Color.orange.opacity(0.85) : Color.blue.opacity(0.85))
                            .foregroundColor(.white)
                            .cornerRadius(6)
                    }
                    .padding(24)
                    
                    Spacer()
                    
                    // 底部场景动态元数据浮动条
                    dynamicMetadataHUD
                        .padding(24)
                }
            }
            .frame(minHeight: 380)
            
            Divider()
            
            // 底部控制面板
            bottomDashboard
            
            // 可折叠日志区域
            if showLogs {
                Divider()
                diagnosticsConsole
                    .frame(height: 120)
            }
        }
        .frame(minWidth: 860, minHeight: 680)
        .background(VisualEffectView().edgesIgnoringSafeArea(.all))
    }
    
    // MARK: - 顶部工具栏
    private var topToolBar: some View {
        HStack(spacing: 12) {
            Image(systemName: "tv.and.mediabox")
                .font(.title2)
                .foregroundColor(.orange)
            
            VStack(alignment: .leading, spacing: 2) {
                Text("Doul D - 杜比视界外屏透传系统")
                    .font(.headline)
                Text("Dolby Vision Passthrough & Mastering Engine")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            
            Spacer()
            
            // 预设片源切换测试
            Menu {
                Button("蓝光原盘: Profile 7 (FEL 双层 4000 nits)") {
                    engine.loadDemoStream(profile: .profile7FEL)
                }
                Button("蓝光原盘: Profile 7 (MEL 单增强层)") {
                    engine.loadDemoStream(profile: .profile7MEL)
                }
                Button("流媒体专有: Profile 5 (IPT 色彩空间)") {
                    engine.loadDemoStream(profile: .profile5)
                }
                Button("单层规范: Profile 8.1 (HDR10 兼容)") {
                    engine.loadDemoStream(profile: .profile81)
                }
            } label: {
                Label("片源模拟测试", systemImage: "film.stack")
            }
            
            // 刷新外屏拓扑
            Button(action: {
                engine.refreshDisplayTopology()
            }) {
                Image(systemName: "arrow.clockwise")
            }
            .help("刷新外接显示器信息与 EDID")
            
            // 切换诊断日志
            Button(action: {
                withAnimation { showLogs.toggle() }
            }) {
                Image(systemName: "terminal")
            }
            .help("展开/折叠系统日志")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
    
    // MARK: - 动态元数据浮动条
    private var dynamicMetadataHUD: some View {
        HStack(spacing: 20) {
            VStack(alignment: .leading, spacing: 2) {
                Text("场景动态范围 (Level 1)")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Text("\(String(format: "%.1f", engine.minLuminanceNits)) ~ \(Int(engine.maxLuminanceNits)) nits")
                    .font(.system(.body, design: .monospaced).bold())
                    .foregroundColor(.white)
            }
            
            Divider().frame(height: 24)
            
            VStack(alignment: .leading, spacing: 2) {
                Text("场景平均亮度 (Avg)")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Text("\(Int(engine.avgLuminanceNits)) nits")
                    .font(.system(.body, design: .monospaced).bold())
                    .foregroundColor(.white)
            }
            
            Divider().frame(height: 24)
            
            VStack(alignment: .leading, spacing: 2) {
                Text("色域与矩阵")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Text(engine.currentProfile == .profile5 ? "IPTPQc2 -> Rec.2020" : "ITU-R BT.2020 / ST 2084")
                    .font(.system(.body, design: .monospaced).bold())
                    .foregroundColor(.yellow)
            }
            
            Spacer()
            
            // 播放 / 暂停按钮
            Button(action: { engine.togglePlayback() }) {
                Image(systemName: engine.isPlaying ? "pause.fill" : "play.fill")
                    .font(.title3)
                    .foregroundColor(.white)
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(Color.orange))
            }
            .buttonStyle(PlainButtonStyle())
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.black.opacity(0.75)))
    }
    
    // MARK: - 底部控制面板
    private var bottomDashboard: some View {
        HStack(alignment: .top, spacing: 24) {
            // 左列：杜比视界重构与渲染状态
            VStack(alignment: .leading, spacing: 8) {
                Text("杜比视界色彩与管线")
                    .font(.subheadline.bold())
                    .foregroundColor(.primary)
                
                HStack {
                    Text("输入格式:")
                        .foregroundColor(.secondary)
                    Text(engine.currentProfile.description)
                        .bold()
                }
                .font(.caption)
                
                HStack {
                    Text("输出格式:")
                        .foregroundColor(.secondary)
                    Text(engine.targetProfile.description)
                        .bold()
                        .foregroundColor(.green)
                }
                .font(.caption)
                
                HStack {
                    Text("渲染模式:")
                        .foregroundColor(.secondary)
                    Picker("", selection: $engine.renderMode) {
                        Text("LLDV 杜比隧道 (直通)").tag(DVRenderMode.lldvTunneling)
                        Text("Apple 原生 EDR (HDR10)").tag(DVRenderMode.nativeAppleEDR)
                    }
                    .pickerStyle(SegmentedPickerStyle())
                    .frame(width: 220)
                }
                .font(.caption)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            
            Divider()
            
            // 右列：外屏检测与一键投屏
            VStack(alignment: .leading, spacing: 8) {
                Text("外接屏幕与 tvOS 投屏调度")
                    .font(.subheadline.bold())
                    .foregroundColor(.primary)
                
                if let best = engine.bestExternalDisplay {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Circle()
                                .fill(best.isDolbyVisionReady ? Color.green : Color.orange)
                                .frame(width: 8, height: 8)
                            Text(best.name)
                                .font(.caption.bold())
                            
                            if best.isDolbyVisionReady {
                                Text("Dolby VSVDB 命中")
                                    .font(.system(size: 9, weight: .bold))
                                    .padding(.horizontal, 4)
                                    .padding(.vertical, 2)
                                    .background(Color.green.opacity(0.2))
                                    .foregroundColor(.green)
                                    .cornerRadius(4)
                            }
                        }
                        
                        let headroom = best.edrState?.currentHeadroom ?? 1.0
                        let peakNits = best.edrState?.estimatedPeakNits ?? 500.0
                        Text("EDR 裕度: \(String(format: "%.2fx", headroom)) | 预计峰值: \(Int(peakNits)) nits")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    
                    Button(action: {
                        engine.toggleExternalPresentation()
                    }) {
                        HStack {
                            Image(systemName: engine.isExternalPresentationActive ? "stop.fill" : "play.tv.fill")
                            Text(engine.isExternalPresentationActive ? "退出外屏独立全屏" : "一键投屏至外屏 (点亮杜比)")
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(engine.isExternalPresentationActive ? .red : .orange)
                    .controlSize(.regular)
                } else {
                    Text("未发现外接显示设备，当前在内建屏幕上以 Liquid Retina XDR 模式渲染。")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(16)
        .background(Color(NSColor.windowBackgroundColor))
    }
    
    // MARK: - 诊断日志控制台
    private var diagnosticsConsole: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 4) {
                ForEach(engine.diagnosticsLog.indices, id: \.self) { idx in
                    Text(engine.diagnosticsLog[idx])
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundColor(Color.green.opacity(0.9))
                }
            }
            .padding(10)
        }
        .background(Color.black.opacity(0.9))
    }
    
    private func profileBadge(_ profile: DolbyVisionProfile) -> some View {
        Text(profile.description)
            .font(.caption.bold())
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.orange.opacity(0.9))
            .foregroundColor(.white)
            .cornerRadius(6)
    }
}

// 磨砂玻璃背景
public struct VisualEffectView: NSViewRepresentable {
    public func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.blendingMode = .behindWindow
        view.state = .active
        view.material = .sidebar
        return view
    }
    
    public func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
