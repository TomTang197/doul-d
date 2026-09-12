import SwiftUI
import UniformTypeIdentifiers
import AppKit
import DolbyCore
import DolbyMetal
import DolbyDisplay

public struct ContentView: View {
    @StateObject private var engine = PlaybackEngine()
    @State private var isDropTargeted = false
    @State private var showLogs = false
    @State private var isHoveringVideo = false
    
    public init() {}
    
    public var body: some View {
        ZStack {
            Color.black.edgesIgnoringSafeArea(.all)
            
            if engine.loadedMediaURL == nil {
                emptyStateDropView
            } else {
                activeVideoPlayerView
            }
            
            // 错误提示条
            if let err = engine.errorMessage {
                VStack {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.yellow)
                        Text(err)
                            .font(.caption.bold())
                            .foregroundColor(.white)
                        Spacer()
                        Button(action: { engine.errorMessage = nil }) {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.white.opacity(0.7))
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(12)
                    .background(Color.red.opacity(0.85))
                    .cornerRadius(8)
                    .padding(16)
                    
                    Spacer()
                }
                .transition(.move(edge: .top).combined(with: .opacity))
            }
            
            // 准备与加载指示器
            if engine.isPreparing {
                ZStack {
                    Color.black.opacity(0.6).edgesIgnoringSafeArea(.all)
                    VStack(spacing: 16) {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle(tint: .orange))
                            .scaleEffect(1.5)
                        Text("正在对杜比视界原盘容器进行极速无损解包...")
                            .font(.headline)
                            .foregroundColor(.white)
                    }
                    .padding(24)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color.black.opacity(0.85)))
                }
            }
        }
        .frame(minWidth: 920, minHeight: 640)
        .onDrop(of: [UTType.fileURL, UTType.item], isTargeted: $isDropTargeted) { providers in
            handleDrop(providers: providers)
        }
    }
    
    // MARK: - 状态 A: 拖拽引导页
    
    private var emptyStateDropView: some View {
        VStack(spacing: 24) {
            Spacer()
            
            ZStack {
                Circle()
                    .fill(isDropTargeted ? Color.orange.opacity(0.25) : Color.white.opacity(0.06))
                    .frame(width: 150, height: 150)
                
                Image(systemName: isDropTargeted ? "arrow.down.circle.fill" : "film.stack.fill")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 68, height: 68)
                    .foregroundColor(isDropTargeted ? .orange : .white.opacity(0.9))
            }
            
            VStack(spacing: 8) {
                Text("直接拖入杜比视界视频文件播放")
                    .font(.title2.bold())
                    .foregroundColor(.white)
                
                Text("支持 4K UHD 蓝光原盘 (Profile 7) 与流媒体 (Profile 5/8)，消除偏色并直通外屏")
                    .font(.callout)
                    .foregroundColor(.gray)
            }
            
            HStack(spacing: 16) {
                Button(action: openFilePicker) {
                    HStack {
                        Image(systemName: "folder.fill")
                        Text("选择本地视频文件...")
                    }
                    .font(.headline)
                    .padding(.horizontal, 22)
                    .padding(.vertical, 10)
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
                .controlSize(.large)
                
                Menu {
                    Button("试看: 4K 蓝光原盘 Profile 7 (4000 nits)") {
                        engine.loadDemoStream(profile: .profile7FEL)
                        engine.mediaFileName = "演示: 4K UHD 蓝光原盘 (Profile 7 FEL).mkv"
                        engine.loadedMediaURL = URL(fileURLWithPath: "/demo.mkv")
                        engine.totalDuration = 7200.0
                        engine.isPlaying = true
                    }
                    Button("试看: 流媒体 Profile 5 (IPT 色彩校正)") {
                        engine.loadDemoStream(profile: .profile5)
                        engine.mediaFileName = "演示: 流媒体抓取 (Profile 5 IPT).mp4"
                        engine.loadedMediaURL = URL(fileURLWithPath: "/demo.mp4")
                        engine.totalDuration = 5400.0
                        engine.isPlaying = true
                    }
                } label: {
                    HStack {
                        Image(systemName: "play.circle")
                        Text("无文件？试用内置片源")
                    }
                    .font(.headline)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }
            
            HStack(spacing: 8) {
                Circle()
                    .fill(engine.bestExternalDisplay?.isDolbyVisionReady == true ? Color.green : Color.yellow)
                    .frame(width: 8, height: 8)
                
                if let best = engine.bestExternalDisplay {
                    Text("当前屏幕: \(best.name) \(best.isDolbyVisionReady ? "(支持杜比直通)" : "(HDR 渲染)")")
                } else {
                    Text("当前使用内建 Liquid Retina XDR 屏幕呈现")
                }
            }
            .font(.caption)
            .foregroundColor(.secondary)
            .padding(.top, 8)
            
            Spacer()
            
            RoundedRectangle(cornerRadius: 16)
                .stroke(isDropTargeted ? Color.orange : Color.white.opacity(0.18), style: StrokeStyle(lineWidth: 2, dash: [8]))
                .frame(height: 90)
                .overlay(
                    Text(isDropTargeted ? "松开鼠标立即载入播放" : "支持从访达拖入 .mkv / .mp4 / .mov / .ts 视频")
                        .font(.caption)
                        .foregroundColor(.secondary)
                )
                .padding(.horizontal, 50)
                .padding(.bottom, 24)
        }
    }
    
    // MARK: - 状态 B: 播放中界面
    
    private var activeVideoPlayerView: some View {
        VStack(spacing: 0) {
            // 顶部条
            HStack {
                Button(action: {
                    engine.stopPlayback()
                    engine.loadedMediaURL = nil
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                        Text("返回选择")
                    }
                }
                .buttonStyle(.plain)
                .foregroundColor(.white.opacity(0.85))
                
                Text(engine.mediaFileName)
                    .font(.subheadline.bold())
                    .foregroundColor(.white)
                    .lineLimit(1)
                    .truncationMode(.middle)
                
                Spacer()
                
                HStack(spacing: 6) {
                    Image(systemName: "sparkles.tv.fill")
                    Text(engine.currentProfile.description)
                }
                .font(.caption.bold())
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Color.orange.opacity(0.9))
                .foregroundColor(.white)
                .cornerRadius(6)
                
                if engine.isProfile7Rewritten {
                    Text("tvOS 算法: Profile 7 -> 8.1 色彩已修复")
                        .font(.caption.bold())
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.purple.opacity(0.85))
                        .foregroundColor(.white)
                        .cornerRadius(6)
                }
                
                Button(action: {
                    engine.toggleExternalPresentation()
                }) {
                    HStack(spacing: 6) {
                        Image(systemName: engine.isExternalPresentationActive ? "stop.fill" : "play.tv.fill")
                        Text(engine.isExternalPresentationActive ? "退出外屏全屏" : "投屏到电视 (点亮杜比)")
                    }
                    .font(.caption.bold())
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(engine.isExternalPresentationActive ? Color.red : Color.green)
                    .foregroundColor(.white)
                    .cornerRadius(6)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Color.black.opacity(0.85))
            
            // 视频渲染画布
            ZStack {
                MetalVideoView(engine: engine)
                    .edgesIgnoringSafeArea(.all)
                    .onHover { hovering in
                        withAnimation(.easeInOut(duration: 0.2)) {
                            isHoveringVideo = hovering
                        }
                    }
                
                if isHoveringVideo || !engine.isPlaying {
                    VStack {
                        Spacer()
                        playerControlOverlay
                            .padding(20)
                            .transition(.opacity)
                    }
                }
            }
        }
    }
    
    // MARK: - 悬浮控制条
    
    private var playerControlOverlay: some View {
        VStack(spacing: 8) {
            Slider(value: Binding(
                get: { engine.playbackProgress },
                set: { newProgress in
                    engine.seek(to: newProgress)
                }
            ))
            .accentColor(.orange)
            
            HStack(spacing: 16) {
                Button(action: {
                    engine.togglePlayback()
                }) {
                    Image(systemName: engine.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title2)
                        .foregroundColor(.white)
                        .frame(width: 40, height: 40)
                        .background(Circle().fill(Color.orange))
                }
                .buttonStyle(.plain)
                
                Text("\(formatTime(engine.currentPlaybackTime)) / \(formatTime(engine.totalDuration))")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(.white.opacity(0.9))
                
                Spacer()
                
                HStack(spacing: 6) {
                    Text("场景峰值:")
                        .foregroundColor(.gray)
                    Text("\(Int(engine.maxLuminanceNits)) nits")
                        .foregroundColor(.yellow)
                        .bold()
                }
                .font(.caption)
                
                Picker("", selection: $engine.renderMode) {
                    Text("LLDV 隧道直通").tag(DVRenderMode.lldvTunneling)
                    Text("Apple 原生 EDR").tag(DVRenderMode.nativeAppleEDR)
                }
                .pickerStyle(SegmentedPickerStyle())
                .frame(width: 200)
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.black.opacity(0.88)))
    }
    
    // MARK: - 文件选择与拖拽处理 (全兼容方案)
    
    private func openFilePicker() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canCreateDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [
            UTType.movie,
            UTType.video,
            UTType.quickTimeMovie,
            UTType.mpeg4Movie,
            UTType(filenameExtension: "mkv") ?? .movie,
            UTType(filenameExtension: "ts") ?? .movie
        ]
        
        if panel.runModal() == .OK, let url = panel.url {
            engine.loadMediaFile(url: url)
        }
    }
    
    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        
        // 尝试方式 1: 直接读取 URL 对象
        if provider.canLoadObject(ofClass: URL.self) {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let validURL = url {
                    Task { @MainActor in
                        self.engine.loadMediaFile(url: validURL)
                    }
                }
            }
            return true
        }
        
        // 尝试方式 2: 读取底层数据并转换为 URL
        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
            var targetURL: URL?
            if let u = item as? URL {
                targetURL = u
            } else if let nsURL = item as? NSURL {
                targetURL = nsURL as URL
            } else if let data = item as? Data, let u = URL(dataRepresentation: data, relativeTo: nil) {
                targetURL = u
            } else if let path = item as? String {
                targetURL = URL(fileURLWithPath: path)
            }
            
            if let finalURL = targetURL {
                Task { @MainActor in
                    self.engine.loadMediaFile(url: finalURL)
                }
            }
        }
        return true
    }
    
    private func formatTime(_ seconds: Double) -> String {
        guard !seconds.isNaN && !seconds.isInfinite else { return "00:00" }
        let totalSecs = Int(seconds)
        let m = totalSecs / 60
        let s = totalSecs % 60
        return String(format: "%02d:%02d", m, s)
    }
}
