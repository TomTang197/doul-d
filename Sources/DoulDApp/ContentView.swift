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
            // 背景层
            Color.black.edgesIgnoringSafeArea(.all)
            
            if engine.loadedMediaURL == nil {
                // 状态 A: 未加载视频，展示极简拖拽与打开引导页
                emptyStateDropView
            } else {
                // 状态 B: 正在播放视频界面
                activeVideoPlayerView
            }
        }
        .frame(minWidth: 900, minHeight: 620)
        // 窗口支持全局文件拖放
        .onDrop(of: [UTType.fileURL], isTargeted: $isDropTargeted) { providers in
            handleDrop(providers: providers)
        }
    }
    
    // MARK: - 状态 A: 极简拖拽引导界面
    
    private var emptyStateDropView: some View {
        VStack(spacing: 24) {
            Spacer()
            
            ZStack {
                Circle()
                    .fill(isDropTargeted ? Color.orange.opacity(0.2) : Color.white.opacity(0.05))
                    .frame(width: 140, height: 140)
                
                Image(systemName: isDropTargeted ? "arrow.down.circle.fill" : "film.stack.fill")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 64, height: 64)
                    .foregroundColor(isDropTargeted ? .orange : .white.opacity(0.85))
            }
            
            VStack(spacing: 8) {
                Text("拖入杜比视界视频文件到这里播放")
                    .font(.title2.bold())
                    .foregroundColor(.white)
                
                Text("自动识别 4K 蓝光原盘 (Profile 7) 与流媒体 (Profile 5/8)，消除偏色并直通外屏")
                    .font(.callout)
                    .foregroundColor(.gray)
                    .multilineTextAlignment(.center)
            }
            
            HStack(spacing: 16) {
                Button(action: openFilePicker) {
                    HStack {
                        Image(systemName: "folder.fill")
                        Text("选择本地视频文件...")
                    }
                    .font(.headline)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
                .controlSize(.large)
                
                // 快速演示按钮 (无文件时方便体验)
                Menu {
                    Button("体验蓝光原盘 Profile 7 (4000 nits)") {
                        engine.loadDemoStream(profile: .profile7FEL)
                        engine.mediaFileName = "演示: 4K UHD 蓝光原盘 (Profile 7 FEL).mkv"
                        engine.loadedMediaURL = URL(fileURLWithPath: "/demo.mkv")
                        engine.totalDuration = 7200.0
                        engine.isPlaying = true
                    }
                    Button("体验流媒体 Profile 5 (IPT 色彩校正)") {
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
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }
            
            // 外接屏幕状态提示
            HStack(spacing: 8) {
                Circle()
                    .fill(engine.bestExternalDisplay?.isDolbyVisionReady == true ? Color.green : Color.yellow)
                    .frame(width: 8, height: 8)
                
                if let best = engine.bestExternalDisplay {
                    Text("当前就绪屏幕: \(best.name) \(best.isDolbyVisionReady ? "(支持杜比直通)" : "(HDR 渲染)")")
                } else {
                    Text("当前使用内建 Liquid Retina XDR 屏幕呈现")
                }
            }
            .font(.caption)
            .foregroundColor(.secondary)
            .padding(.top, 12)
            
            Spacer()
            
            // 底部拖拽虚线框
            RoundedRectangle(cornerRadius: 16)
                .stroke(isDropTargeted ? Color.orange : Color.white.opacity(0.15), style: StrokeStyle(lineWidth: 2, dash: [8]))
                .frame(height: 100)
                .overlay(
                    Text(isDropTargeted ? "松开鼠标即可载入播放" : "支持 .mkv / .mp4 / .mov / .m4v / .ts")
                        .font(.caption)
                        .foregroundColor(.secondary)
                )
                .padding(.horizontal, 48)
                .padding(.bottom, 24)
        }
    }
    
    // MARK: - 状态 B: 播放中界面
    
    private var activeVideoPlayerView: some View {
        VStack(spacing: 0) {
            // 顶部条：文件名与状态
            HStack {
                Button(action: {
                    engine.stopPlayback()
                    engine.loadedMediaURL = nil
                }) {
                    Image(systemName: "chevron.left")
                    Text("返回")
                }
                .buttonStyle(.plain)
                .foregroundColor(.white.opacity(0.8))
                
                Text(engine.mediaFileName)
                    .font(.subheadline.bold())
                    .foregroundColor(.white)
                    .lineLimit(1)
                    .truncationMode(.middle)
                
                Spacer()
                
                // 杜比 Profile 胶囊
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
                
                // 外屏投屏主按钮
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
            .background(Color.black.opacity(0.8))
            
            // 视频渲染区
            ZStack {
                MetalVideoView(engine: engine)
                    .edgesIgnoringSafeArea(.all)
                    .onHover { hovering in
                        withAnimation(.easeInOut(duration: 0.2)) {
                            isHoveringVideo = hovering
                        }
                    }
                
                // 悬浮播放控制条 (悬停时显示)
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
    
    // MARK: - 悬浮播放控制条
    
    private var playerControlOverlay: some View {
        VStack(spacing: 8) {
            // 进度条
            Slider(value: Binding(
                get: { engine.playbackProgress },
                set: { newProgress in
                    engine.seek(to: newProgress)
                }
            ))
            .accentColor(.orange)
            
            HStack(spacing: 16) {
                // 播放/暂停
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
                
                // 时间显示
                Text("\(formatTime(engine.currentPlaybackTime)) / \(formatTime(engine.totalDuration))")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(.white.opacity(0.9))
                
                Spacer()
                
                // 实时动态亮度
                HStack(spacing: 6) {
                    Text("峰值亮度:")
                        .foregroundColor(.gray)
                    Text("\(Int(engine.maxLuminanceNits)) nits")
                        .foregroundColor(.yellow)
                        .bold()
                }
                .font(.caption)
                
                // 渲染模式
                Picker("", selection: $engine.renderMode) {
                    Text("LLDV 隧道直通").tag(DVRenderMode.lldvTunneling)
                    Text("Apple 原生 EDR").tag(DVRenderMode.nativeAppleEDR)
                }
                .pickerStyle(SegmentedPickerStyle())
                .frame(width: 200)
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.black.opacity(0.85)))
    }
    
    // MARK: - 文件选择与拖放处理
    
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
        
        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
            guard let data = item as? Data,
                  let url = URL(dataRepresentation: data, relativeTo: nil) else {
                return
            }
            
            Task { @MainActor in
                self.engine.loadMediaFile(url: url)
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
