import Foundation
import Metal
import CoreVideo
import CoreGraphics
import simd
import QuartzCore
import DolbyCore
import os.log

private let logger = Logger(subsystem: "com.dould.DolbyMetal", category: "DVMetalRenderer")

// MARK: - 渲染管线模式与配置

/// 杜比视界 Metal 渲染器运行模式
public enum DVRenderMode: String, Sendable, CaseIterable {
    /// 原生 Apple EDR 模式 (结合 CAMetalLayer 16-bit Float 与 EDR 峰值亮度硬件加速)
    case nativeAppleEDR = "Native Apple EDR (16-bit Float)"
    /// 杜比视界 LLDV / Standard 隧道伪装模式 (12-bit YUV 4:2:2 封装进 RGB 4:4:4，供 HDMI 外接电视点亮杜比视界)
    case lldvTunneling = "LLDV RGB 4:4:4 Tunneling"
}

/// 顶点数据定义 (与 ShaderTypes.h 中的 Vertex2D 对齐)
public struct DVVertex {
    public var position: simd_float2
    public var texCoords: simd_float2

    public init(position: simd_float2, texCoords: simd_float2) {
        self.position = position
        self.texCoords = texCoords
    }
}

// MARK: - DVMetalRenderer

/// 基于 Apple Metal 的高性能杜比视界与 LLDV 渲染引擎
/// 支持杜比 Profile 5 IPT 色彩矩阵还原、LLDV 隧道位重排编码与 EDR 动态色调映射
public final class DVMetalRenderer: @unchecked Sendable {

    // MARK: - Metal 核心组件

    public let device: MTLDevice
    public let commandQueue: MTLCommandQueue

    /// CoreVideo Metal 零拷贝纹理高速缓存
    private var textureCache: CVMetalTextureCache?

    /// 全屏 Quad 顶点缓冲区
    private let vertexBuffer: MTLBuffer

    // MARK: - 管线状态缓存

    /// 1. Profile 5 IPT -> 线性 RGB 渲染管线状态
    public private(set) var iptPipeline: MTLRenderPipelineState?

    /// 2. LLDV 伪装隧道打包渲染管线状态
    public private(set) var lldvTunnelPipeline: MTLRenderPipelineState?

    /// 3. EDR / PQ 动态色调映射渲染管线状态
    public private(set) var toneMappingPipeline: MTLRenderPipelineState?

    // MARK: - 当前渲染参数状态

    /// 当前运行模式 (可在 nativeAppleEDR 与 lldvTunneling 之间实时平滑切换)
    public var renderMode: DVRenderMode = .nativeAppleEDR

    /// 当前帧的 RPU 动态元数据 (默认为 1000 nits 母版标准)
    public var currentRPU: RPUMetadata = .default1000Nits

    /// 当前显示器的 EDR 峰值 Headroom 倍数 (通常 1.0 ~ 16.0)
    public var edrHeadroom: Float = 1.0

    /// SDR 参考白点基准亮度 (单位: nits，默认 100.0)
    public var sdrWhiteLuminance: Float = 100.0

    /// 中间纹理缓存 (用于两步 Pass 渲染)
    private var intermediateTexture: MTLTexture?

    // MARK: - 初始化方法

    public init?(device: MTLDevice? = MTLCreateSystemDefaultDevice()) {
        guard let dev = device else {
            logger.error("No Metal-compatible GPU device available on this system.")
            return nil
        }
        self.device = dev

        guard let queue = dev.makeCommandQueue() else {
            logger.error("Failed to create MTLCommandQueue.")
            return nil
        }
        self.commandQueue = queue

        // 1. 初始化 CoreVideo 零拷贝纹理高速缓存
        var cache: CVMetalTextureCache?
        let cacheStatus = CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, dev, nil, &cache)
        guard cacheStatus == kCVReturnSuccess, let validCache = cache else {
            logger.error("Failed to create CVMetalTextureCache: \(cacheStatus)")
            return nil
        }
        self.textureCache = validCache

        // 2. 初始化标准全屏三角形带 (Triangle Strip) Quad 顶点数据
        let quadVertices: [DVVertex] = [
            DVVertex(position: simd_float2(-1.0, -1.0), texCoords: simd_float2(0.0, 1.0)),
            DVVertex(position: simd_float2( 1.0, -1.0), texCoords: simd_float2(1.0, 1.0)),
            DVVertex(position: simd_float2(-1.0,  1.0), texCoords: simd_float2(0.0, 0.0)),
            DVVertex(position: simd_float2( 1.0,  1.0), texCoords: simd_float2(1.0, 0.0))
        ]
        guard let vBuffer = dev.makeBuffer(
            bytes: quadVertices,
            length: MemoryLayout<DVVertex>.stride * quadVertices.count,
            options: .storageModeShared
        ) else {
            logger.error("Failed to allocate vertex buffer.")
            return nil
        }
        self.vertexBuffer = vBuffer

        // 3. 加载着色器库并构建管线
        buildRenderPipelines()
    }

    // MARK: - 管线构建逻辑

    private func buildRenderPipelines() {
        var defaultLibrary: MTLLibrary?

        // 尝试从 SPM Bundle.module 加载预编译 metallib
        #if SWIFT_PACKAGE
        if let moduleLib = try? device.makeDefaultLibrary(bundle: Bundle.module) {
            defaultLibrary = moduleLib
            logger.info("Loaded Metal library from Bundle.module.")
        }
        #endif

        // 备用方案 1：尝试系统默认 Default Library
        if defaultLibrary == nil {
            defaultLibrary = device.makeDefaultLibrary()
        }

        // 备用方案 2：动态从源码构建 (保证在各环境及无独立 metallib 时 100% 成功构建)
        if defaultLibrary == nil || defaultLibrary?.makeFunction(name: "dolbyIPTToRGBFragmentShader") == nil {
            if let dynLib = compileShadersFromSource() {
                defaultLibrary = dynLib
            }
        }

        guard let lib = defaultLibrary else {
            logger.warning("Could not build Metal library.")
            return
        }

        // 1. 构建 IPT -> RGB Pipeline (.rgba16Float 适合母版高动态范围)
        if let vert = lib.makeFunction(name: "iptVertexShader"),
           let frag = lib.makeFunction(name: "dolbyIPTToRGBFragmentShader") {
            let desc = MTLRenderPipelineDescriptor()
            desc.label = "DolbyVision.IPTToRGB"
            desc.vertexFunction = vert
            desc.fragmentFunction = frag
            desc.colorAttachments[0].pixelFormat = .rgba16Float
            self.iptPipeline = try? device.makeRenderPipelineState(descriptor: desc)
        }

        // 2. 构建 LLDV 隧道 Pipeline (.bgra8Unorm 或 .rgba8Unorm 模拟 HDMI 传输)
        if let vert = lib.makeFunction(name: "dolbyLLDVTunnelVertexShader"),
           let frag = lib.makeFunction(name: "dolbyLLDVTunnelFragmentShader") {
            let desc = MTLRenderPipelineDescriptor()
            desc.label = "DolbyVision.LLDVTunnel"
            desc.vertexFunction = vert
            desc.fragmentFunction = frag
            desc.colorAttachments[0].pixelFormat = .bgra8Unorm
            self.lldvTunnelPipeline = try? device.makeRenderPipelineState(descriptor: desc)
        }

        // 3. 构建 EDR 色调映射 Pipeline (.rgba16Float 配合 Apple EDR 扩展线性显示)
        if let vert = lib.makeFunction(name: "dolbyToneMappingVertexShader"),
           let frag = lib.makeFunction(name: "dolbyToneMappingFragmentShader") {
            let desc = MTLRenderPipelineDescriptor()
            desc.label = "DolbyVision.EDRToneMapping"
            desc.vertexFunction = vert
            desc.fragmentFunction = frag
            desc.colorAttachments[0].pixelFormat = .rgba16Float
            self.toneMappingPipeline = try? device.makeRenderPipelineState(descriptor: desc)
        }

        logger.info("Render pipelines build status: IPT=\(self.iptPipeline != nil), LLDV=\(self.lldvTunnelPipeline != nil), ToneMapping=\(self.toneMappingPipeline != nil)")
    }

    /// 动态源码编译回退方案
    private func compileShadersFromSource() -> MTLLibrary? {
        let options = MTLCompileOptions()
        options.languageVersion = .version3_0

        // 尝试从 Bundle.module 查找着色器文件
        #if SWIFT_PACKAGE
        let shaderNames = ["DolbyIPTToRGB", "DolbyLLDVTunneling", "DolbyToneMapping"]
        var combinedSource = ""

        if let headerURL = Bundle.module.url(forResource: "ShaderTypes", withExtension: "h", subdirectory: "Shaders"),
           let header = try? String(contentsOf: headerURL, encoding: .utf8) {
            combinedSource += header + "\n"
        }

        for name in shaderNames {
            if let fileURL = Bundle.module.url(forResource: name, withExtension: "metal", subdirectory: "Shaders"),
               let content = try? String(contentsOf: fileURL, encoding: .utf8) {
                let cleaned = content.replacingOccurrences(of: "#include \"ShaderTypes.h\"", with: "")
                combinedSource += cleaned + "\n"
            }
        }

        if !combinedSource.isEmpty, let lib = try? device.makeLibrary(source: combinedSource, options: options) {
            return lib
        }
        #endif

        return nil
    }

    // MARK: - CVPixelBuffer 纹理抽取

    /// 从 CVPixelBuffer (P010 / 4:2:0 BiPlanar / 4:4:4) 快速抽取 Metal 零拷贝纹理对
    /// - Parameter pixelBuffer: 解码器输出的原始 CVPixelBuffer
    /// - Returns: 元组包含 (亮度 Y 纹理, 色度 UV 纹理)
    public func createTextures(from pixelBuffer: CVPixelBuffer) -> (luma: MTLTexture, chroma: MTLTexture)? {
        guard let cache = self.textureCache else { return nil }

        let pixelFormat = CVPixelBufferGetPixelFormatType(pixelBuffer)
        let planeCount = CVPixelBufferGetPlaneCount(pixelBuffer)

        var lumaMTLPixelFormat: MTLPixelFormat = .r8Unorm
        var chromaMTLPixelFormat: MTLPixelFormat = .rg8Unorm

        // 判断高位深 10-bit / 12-bit (P010, x420 等)
        if pixelFormat == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange ||
           pixelFormat == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange {
            lumaMTLPixelFormat = .r16Unorm
            chromaMTLPixelFormat = .rg16Unorm
        }

        // 1. 提取 Plane 0 (Y 亮度 / I 强度)
        let lumaWidth = CVPixelBufferGetWidthOfPlane(pixelBuffer, 0)
        let lumaHeight = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)

        var lumaCVTexture: CVMetalTexture?
        let lumaStatus = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            cache,
            pixelBuffer,
            nil,
            lumaMTLPixelFormat,
            lumaWidth,
            lumaHeight,
            0,
            &lumaCVTexture
        )

        guard lumaStatus == kCVReturnSuccess,
              let lumaValidCV = lumaCVTexture,
              let lumaTexture = CVMetalTextureGetTexture(lumaValidCV) else {
            logger.error("Failed to extract luma texture: \(lumaStatus)")
            return nil
        }

        // 2. 提取 Plane 1 (UV 色度 / PT 轴)
        let chromaPlaneIndex = min(1, planeCount - 1)
        let chromaWidth = CVPixelBufferGetWidthOfPlane(pixelBuffer, chromaPlaneIndex)
        let chromaHeight = CVPixelBufferGetHeightOfPlane(pixelBuffer, chromaPlaneIndex)

        var chromaCVTexture: CVMetalTexture?
        let chromaStatus = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            cache,
            pixelBuffer,
            nil,
            chromaMTLPixelFormat,
            chromaWidth,
            chromaHeight,
            chromaPlaneIndex,
            &chromaCVTexture
        )

        guard chromaStatus == kCVReturnSuccess,
              let chromaValidCV = chromaCVTexture,
              let chromaTexture = CVMetalTextureGetTexture(chromaValidCV) else {
            logger.error("Failed to extract chroma texture: \(chromaStatus)")
            return nil
        }

        return (lumaTexture, chromaTexture)
    }

    // MARK: - 主渲染入口

    /// 渲染一帧杜比视界画面至指定的 CAMetalDrawable
    /// - Parameters:
    ///   - pixelBuffer: 包含当前视频帧的 CVPixelBuffer
    ///   - drawable: CAMetalLayer 当前的 drawable 呈现目标
    ///   - rpu: 关联的杜比动态元数据 (可选，若不提供则使用内部当前缓存)
    /// - Returns: 是否成功提交渲染指令
    @discardableResult
    public func render(
        pixelBuffer: CVPixelBuffer,
        to drawable: CAMetalDrawable,
        rpu: RPUMetadata? = nil
    ) -> Bool {
        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            return false
        }

        let success = render(
            pixelBuffer: pixelBuffer,
            to: drawable.texture,
            rpu: rpu,
            commandBuffer: commandBuffer
        )

        if success {
            commandBuffer.present(drawable)
            commandBuffer.commit()
        }

        return success
    }

    /// 渲染一帧杜比视界画面至指定的目标 MTLTexture (支持离屏渲染与导出)
    /// - Parameters:
    ///   - pixelBuffer: 包含当前视频帧的 CVPixelBuffer
    ///   - destinationTexture: 输出目标纹理
    ///   - rpu: 关联的杜比动态元数据
    ///   - commandBuffer: 指定的外部 CommandBuffer (若为 nil 则内部创建并自动提交)
    /// - Returns: 是否成功渲染
    @discardableResult
    public func render(
        pixelBuffer: CVPixelBuffer,
        to destinationTexture: MTLTexture,
        rpu: RPUMetadata? = nil,
        commandBuffer: MTLCommandBuffer? = nil
    ) -> Bool {
        if let newRPU = rpu {
            self.currentRPU = newRPU
        }

        guard let textures = createTextures(from: pixelBuffer) else {
            return false
        }

        let cmdBuffer: MTLCommandBuffer
        let shouldCommit: Bool

        if let existing = commandBuffer {
            cmdBuffer = existing
            shouldCommit = false
        } else {
            guard let created = commandQueue.makeCommandBuffer() else { return false }
            cmdBuffer = created
            shouldCommit = true
        }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)

        switch renderMode {
        case .nativeAppleEDR:
            renderNativeAppleEDR(
                lumaTexture: textures.luma,
                chromaTexture: textures.chroma,
                targetTexture: destinationTexture,
                width: width,
                height: height,
                commandBuffer: cmdBuffer
            )

        case .lldvTunneling:
            renderLLDVTunneling(
                lumaTexture: textures.luma,
                chromaTexture: textures.chroma,
                targetTexture: destinationTexture,
                width: width,
                height: height,
                commandBuffer: cmdBuffer
            )
        }

        if shouldCommit {
            cmdBuffer.commit()
        }

        return true
    }

    // MARK: - 模式 1: 原生 Apple EDR 渲染管线实现

    private func renderNativeAppleEDR(
        lumaTexture: MTLTexture,
        chromaTexture: MTLTexture,
        targetTexture: MTLTexture,
        width: Int,
        height: Int,
        commandBuffer: MTLCommandBuffer
    ) {
        // 确保两步 Pass 中间纹理就绪
        ensureIntermediateTexture(width: width, height: height)
        guard let intermediate = intermediateTexture else { return }

        // --- Pass 1: IPT -> 线性 RGB 转换 ---
        guard let iptPipe = self.iptPipeline else { return }
        let pass1Desc = MTLRenderPassDescriptor()
        pass1Desc.colorAttachments[0].texture = intermediate
        pass1Desc.colorAttachments[0].loadAction = .dontCare
        pass1Desc.colorAttachments[0].storeAction = .store

        if let encoder1 = commandBuffer.makeRenderCommandEncoder(descriptor: pass1Desc) {
            encoder1.label = "Pass1.IPTToLinearRGB"
            encoder1.setRenderPipelineState(iptPipe)
            encoder1.setVertexBuffer(vertexBuffer, offset: 0, index: 0)

            encoder1.setFragmentTexture(lumaTexture, index: 0)
            encoder1.setFragmentTexture(chromaTexture, index: 1)

            var iptUniforms = IPTUniforms(
                targetGamut: 0, // 0 = BT.2020 宽色域
                usePQEOTF: (currentRPU.profile == .profile5) ? 1 : 0,
                invGamma: Float(1.0 / 0.43),
                chromaOffset: 0.5
            )
            encoder1.setFragmentBytes(&iptUniforms, length: MemoryLayout<IPTUniforms>.stride, index: 1)

            encoder1.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            encoder1.endEncoding()
        }

        // --- Pass 2: EDR 动态色调映射 -> 目标纹理 ---
        guard let tonePipe = self.toneMappingPipeline else { return }
        let pass2Desc = MTLRenderPassDescriptor()
        pass2Desc.colorAttachments[0].texture = targetTexture
        pass2Desc.colorAttachments[0].loadAction = .dontCare
        pass2Desc.colorAttachments[0].storeAction = .store

        if let encoder2 = commandBuffer.makeRenderCommandEncoder(descriptor: pass2Desc) {
            encoder2.label = "Pass2.EDRToneMapping"
            encoder2.setRenderPipelineState(tonePipe)
            encoder2.setVertexBuffer(vertexBuffer, offset: 0, index: 0)

            encoder2.setFragmentTexture(intermediate, index: 2)

            var toneUniforms = ToneMappingUniforms(
                sourceMinLuminance: currentRPU.minLuminance,
                sourceMaxLuminance: currentRPU.maxLuminance,
                sourceAvgLuminance: currentRPU.avgLuminance,
                targetMaxLuminance: sdrWhiteLuminance * max(edrHeadroom, 1.0),
                targetMinLuminance: 0.001,
                targetEDRHeadroom: edrHeadroom,
                sdrWhiteLuminance: sdrWhiteLuminance,
                outputMode: 0, // 0: Apple EDR 扩展浮点
                kneePoint: currentRPU.kneePoint
            )
            encoder2.setFragmentBytes(&toneUniforms, length: MemoryLayout<ToneMappingUniforms>.stride, index: 1)

            encoder2.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            encoder2.endEncoding()
        }
    }

    // MARK: - 模式 2: LLDV RGB 4:4:4 伪装隧道渲染管线实现

    private func renderLLDVTunneling(
        lumaTexture: MTLTexture,
        chromaTexture: MTLTexture,
        targetTexture: MTLTexture,
        width: Int,
        height: Int,
        commandBuffer: MTLCommandBuffer
    ) {
        guard let lldvPipe = self.lldvTunnelPipeline else { return }

        let passDesc = MTLRenderPassDescriptor()
        passDesc.colorAttachments[0].texture = targetTexture
        passDesc.colorAttachments[0].loadAction = .dontCare
        passDesc.colorAttachments[0].storeAction = .store

        if let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: passDesc) {
            encoder.label = "Pass.LLDVTunnelPackaging"
            encoder.setRenderPipelineState(lldvPipe)
            encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)

            encoder.setFragmentTexture(lumaTexture, index: 0)
            encoder.setFragmentTexture(chromaTexture, index: 1)

            var tunnelUniforms = LLDVTunnelUniforms(
                outputBitDepth: 8, // 标准 8-bit RGB 伪装隧道
                frameWidth: UInt32(width),
                frameHeight: UInt32(height),
                bitReorderMode: 0  // 0: Dolby 专利高低位对齐
            )
            encoder.setFragmentBytes(&tunnelUniforms, length: MemoryLayout<LLDVTunnelUniforms>.stride, index: 1)

            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            encoder.endEncoding()
        }
    }

    // MARK: - 辅助中间纹理维护

    private func ensureIntermediateTexture(width: Int, height: Int) {
        if let existing = intermediateTexture,
           existing.width == width,
           existing.height == height {
            return
        }

        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float,
            width: width,
            height: height,
            mipmapped: false
        )
        desc.usage = [.renderTarget, .shaderRead]
        desc.storageMode = .private
        self.intermediateTexture = device.makeTexture(descriptor: desc)
    }
}
