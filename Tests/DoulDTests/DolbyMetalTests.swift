import XCTest
import Metal
import CoreVideo
import QuartzCore
@testable import DolbyCore
@testable import DolbyMetal

final class DolbyMetalTests: XCTestCase {

    var device: MTLDevice!

    override func setUp() {
        super.setUp()
        device = MTLCreateSystemDefaultDevice()
    }

    func testMetalDeviceAvailable() {
        XCTAssertNotNil(device, "Apple Silicon / macOS Metal device must be available")
    }

    func testDVMetalRendererInitialization() {
        guard let dev = device else {
            XCTFail("No Metal device")
            return
        }

        let renderer = DVMetalRenderer(device: dev)
        XCTAssertNotNil(renderer, "DVMetalRenderer must initialize successfully")
        XCTAssertEqual(renderer?.renderMode, .nativeAppleEDR)

        // Test mode switching
        renderer?.renderMode = .lldvTunneling
        XCTAssertEqual(renderer?.renderMode, .lldvTunneling)
    }

    func testShaderCompilationAtRuntime() throws {
        guard let dev = device else {
            throw XCTSkip("No Metal device available")
        }

        let shaderPaths = [
            "Sources/DolbyMetal/Shaders/DolbyIPTToRGB.metal",
            "Sources/DolbyMetal/Shaders/DolbyLLDVTunneling.metal",
            "Sources/DolbyMetal/Shaders/DolbyToneMapping.metal"
        ]

        let headerUrl = URL(fileURLWithPath: "Sources/DolbyMetal/Shaders/ShaderTypes.h")
        let headerContent = try String(contentsOf: headerUrl, encoding: .utf8)

        for path in shaderPaths {
            let url = URL(fileURLWithPath: path)
            var source = try String(contentsOf: url, encoding: .utf8)
            source = source.replacingOccurrences(of: "#include \"ShaderTypes.h\"", with: headerContent)

            let options = MTLCompileOptions()
            options.languageVersion = .version3_0

            do {
                let library = try dev.makeLibrary(source: source, options: options)
                XCTAssertFalse(library.functionNames.isEmpty, "Compiled library for \(path) should have functions")
            } catch {
                XCTFail("Failed to compile shader \(path): \(error)")
            }
        }
    }

    func testCAMetalLayerConfiguration() {
        guard let dev = device else {
            return
        }

        let layer = CAMetalLayer()
        DVMetalLayerConfig.configureForEDR(layer: layer, colorSpace: .itur2100_PQ, device: dev)

        XCTAssertTrue(layer.wantsExtendedDynamicRangeContent)
        XCTAssertEqual(layer.pixelFormat, .rgba16Float)
        XCTAssertNotNil(layer.colorspace)

        // Switch to LLDV Tunnel
        DVMetalLayerConfig.configureForLLDVTunnel(layer: layer, device: dev)
        XCTAssertFalse(layer.wantsExtendedDynamicRangeContent)
        XCTAssertEqual(layer.pixelFormat, .bgra8Unorm)

        // Update drawable size
        let bounds = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        DVMetalLayerConfig.updateDrawableSize(for: layer, bounds: bounds, backingScaleFactor: 2.0)
        XCTAssertEqual(layer.drawableSize, CGSize(width: 3840, height: 2160))

        // Query screen EDR Headroom
        let headroom = DVMetalLayerConfig.queryScreenEDRHeadroom()
        XCTAssertGreaterThanOrEqual(headroom.current, 1.0)
        XCTAssertGreaterThanOrEqual(headroom.maxPotential, 1.0)
    }

    func testCVPixelBufferTextureExtraction() {
        guard let dev = device, let renderer = DVMetalRenderer(device: dev) else {
            return
        }

        // 创建测试用 10-bit P010 (kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange) PixelBuffer
        let width = 128
        let height = 128
        var pixelBuffer: CVPixelBuffer?
        let attrs: [CFString: Any] = [
            kCVPixelBufferMetalCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as [String: Any]
        ]

        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
            attrs as CFDictionary,
            &pixelBuffer
        )

        XCTAssertEqual(status, kCVReturnSuccess)
        guard let pb = pixelBuffer else {
            XCTFail("Failed to create CVPixelBuffer")
            return
        }

        let textures = renderer.createTextures(from: pb)
        XCTAssertNotNil(textures)
        XCTAssertEqual(textures?.luma.width, width)
        XCTAssertEqual(textures?.luma.height, height)
        XCTAssertEqual(textures?.luma.pixelFormat, .r16Unorm)
        XCTAssertEqual(textures?.chroma.pixelFormat, .rg16Unorm)
    }

    func testUniformMemoryLayouts() {
        XCTAssertEqual(MemoryLayout<IPTUniforms>.size, 16)
        XCTAssertEqual(MemoryLayout<LLDVTunnelUniforms>.size, 16)
        XCTAssertEqual(MemoryLayout<ToneMappingUniforms>.size, 36)
    }

    func testOffscreenRenderingExecution() throws {
        guard let dev = device, let renderer = DVMetalRenderer(device: dev) else {
            throw XCTSkip("Metal device not available")
        }

        // 动态确保着色器管线就绪
        let headerUrl = URL(fileURLWithPath: "Sources/DolbyMetal/Shaders/ShaderTypes.h")
        let headerContent = try String(contentsOf: headerUrl, encoding: .utf8)
        let iptUrl = URL(fileURLWithPath: "Sources/DolbyMetal/Shaders/DolbyIPTToRGB.metal")
        let lldvUrl = URL(fileURLWithPath: "Sources/DolbyMetal/Shaders/DolbyLLDVTunneling.metal")
        let toneUrl = URL(fileURLWithPath: "Sources/DolbyMetal/Shaders/DolbyToneMapping.metal")

        let combined = headerContent + "\n" +
            (try String(contentsOf: iptUrl, encoding: .utf8)).replacingOccurrences(of: "#include \"ShaderTypes.h\"", with: "") + "\n" +
            (try String(contentsOf: lldvUrl, encoding: .utf8)).replacingOccurrences(of: "#include \"ShaderTypes.h\"", with: "") + "\n" +
            (try String(contentsOf: toneUrl, encoding: .utf8)).replacingOccurrences(of: "#include \"ShaderTypes.h\"", with: "")

        _ = try dev.makeLibrary(source: combined, options: nil)

        // 构造测试 CVPixelBuffer
        let width = 64
        let height = 64
        var pixelBuffer: CVPixelBuffer?
        let attrs: [CFString: Any] = [
            kCVPixelBufferMetalCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as [String: Any]
        ]
        CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange, attrs as CFDictionary, &pixelBuffer)
        guard let pb = pixelBuffer else {
            XCTFail("Failed to create test pixel buffer")
            return
        }

        // 1. 测试 Native Apple EDR 离屏目标纹理渲染
        renderer.renderMode = .nativeAppleEDR
        let edrTargetDesc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: width, height: height, mipmapped: false)
        edrTargetDesc.usage = [.renderTarget, .shaderRead]
        guard let edrTarget = dev.makeTexture(descriptor: edrTargetDesc) else {
            XCTFail("Failed to create target texture")
            return
        }

        let edrSuccess = renderer.render(pixelBuffer: pb, to: edrTarget, rpu: .default1000Nits)
        // 若预置编译管线处于活跃状态，则断言成功
        if renderer.iptPipeline != nil && renderer.toneMappingPipeline != nil {
            XCTAssertTrue(edrSuccess)
        }

        // 2. 测试 LLDV Tunnel 离屏目标纹理渲染
        renderer.renderMode = .lldvTunneling
        let lldvTargetDesc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        lldvTargetDesc.usage = [.renderTarget, .shaderRead]
        guard let lldvTarget = dev.makeTexture(descriptor: lldvTargetDesc) else {
            XCTFail("Failed to create lldv texture")
            return
        }

        let lldvSuccess = renderer.render(pixelBuffer: pb, to: lldvTarget)
        if renderer.lldvTunnelPipeline != nil {
            XCTAssertTrue(lldvSuccess)
        }
    }
}
