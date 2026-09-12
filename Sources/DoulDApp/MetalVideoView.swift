import SwiftUI
import AppKit
import Metal
import QuartzCore
import DolbyMetal

public struct MetalVideoView: NSViewRepresentable {
    @ObservedObject public var engine: PlaybackEngine
    
    public init(engine: PlaybackEngine) {
        self.engine = engine
    }
    
    public func makeNSView(context: Context) -> NSMetalViewHost {
        let view = NSMetalViewHost(engine: engine)
        return view
    }
    
    public func updateNSView(_ nsView: NSMetalViewHost, context: Context) {
        nsView.updateConfiguration()
    }
}

public final class NSMetalViewHost: NSView {
    private let engine: PlaybackEngine
    public private(set) var metalLayer: CAMetalLayer!
    
    public init(engine: PlaybackEngine) {
        self.engine = engine
        super.init(frame: .zero)
        self.wantsLayer = true
        setupMetalLayer()
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    private func setupMetalLayer() {
        guard let device = engine.metalRenderer?.device else { return }
        let layer = CAMetalLayer()
        layer.device = device
        self.layer = layer
        self.metalLayer = layer
        self.engine.hostMetalLayer = layer
        updateConfiguration()
    }
    
    public func updateConfiguration() {
        guard let metalLayer = self.metalLayer else { return }
        if engine.renderMode == .lldvTunneling {
            DVMetalLayerConfig.configureForLLDVTunnel(layer: metalLayer)
        } else {
            DVMetalLayerConfig.configureForEDR(layer: metalLayer)
        }
        
        let scale = self.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
        DVMetalLayerConfig.updateDrawableSize(for: metalLayer, bounds: self.bounds, backingScaleFactor: scale)
    }
    
    public override func layout() {
        super.layout()
        updateConfiguration()
    }
    
    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateConfiguration()
    }
}
