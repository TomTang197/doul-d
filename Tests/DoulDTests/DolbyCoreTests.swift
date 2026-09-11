import XCTest
import CoreMedia
import CoreVideo
@testable import DolbyCore

final class DolbyCoreTests: XCTestCase {

    // MARK: - 1. DolbyProfile & ColorSpace Tests

    func testDolbyVisionProfiles() {
        // Profile 5 (Streaming IPT)
        let p5 = DolbyProfile.profile5
        XCTAssertEqual(p5.profileNumber, 5)
        XCTAssertEqual(p5.colorSpace, .ipt)
        XCTAssertFalse(p5.isDualLayer)
        XCTAssertEqual(p5.blCompatibilityID, 0)
        XCTAssertEqual(p5.preferredFourCC, "dvcC")

        // Profile 7 FEL / MEL (UHD Blu-ray)
        let p7fel = DolbyProfile.profile7FEL
        let p7mel = DolbyProfile.profile7MEL
        XCTAssertEqual(p7fel.profileNumber, 7)
        XCTAssertEqual(p7mel.profileNumber, 7)
        XCTAssertEqual(p7fel.colorSpace, .rec2020PQ)
        XCTAssertTrue(p7fel.isDualLayer)
        XCTAssertTrue(p7mel.isDualLayer)
        XCTAssertEqual(p7fel.blCompatibilityID, 6)

        // Profile 8.1 (HDR10 Base + Dynamic RPU)
        let p81 = DolbyProfile.profile81
        XCTAssertEqual(p81.profileNumber, 8)
        XCTAssertEqual(p81.colorSpace, .rec2020PQ)
        XCTAssertFalse(p81.isDualLayer)
        XCTAssertEqual(p81.blCompatibilityID, 1)
        XCTAssertEqual(p81.preferredFourCC, "dv81")
        XCTAssertEqual(DolbyProfile.profile8_1, p81)

        // Profile 8.4 (HLG Base)
        let p84 = DolbyProfile.profile84
        XCTAssertEqual(p84.profileNumber, 8)
        XCTAssertEqual(p84.colorSpace, .rec2020HLG)
        XCTAssertFalse(p84.isDualLayer)
        XCTAssertEqual(p84.blCompatibilityID, 4)
    }

    func testColorSpaceAttachments() {
        let ipt = DolbyColorSpace.ipt
        XCTAssertEqual(ipt.cvColorPrimaries, kCVImageBufferColorPrimaries_ITU_R_2020)
        XCTAssertEqual(ipt.cvTransferFunction, kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ)

        let rec2020PQ = DolbyColorSpace.rec2020PQ
        XCTAssertEqual(rec2020PQ.cvColorPrimaries, kCVImageBufferColorPrimaries_ITU_R_2020)
        XCTAssertEqual(rec2020PQ.cvTransferFunction, kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ)
        XCTAssertEqual(rec2020PQ.cvMatrix, kCVImageBufferYCbCrMatrix_ITU_R_2020)

        let hlg = DolbyColorSpace.rec2020HLG
        XCTAssertEqual(hlg.cvTransferFunction, kCVImageBufferTransferFunction_ITU_R_2100_HLG)

        let rec709 = DolbyColorSpace.rec709
        XCTAssertEqual(rec709.cvColorPrimaries, kCVImageBufferColorPrimaries_ITU_R_709_2)
    }

    func testHEVCNALUTypes() {
        let rpuType = HEVCNALUType.unspec62
        XCTAssertEqual(rpuType.rawValue, 62)
        XCTAssertTrue(rpuType.isDolbyVisionRPU)
        XCTAssertFalse(rpuType.isVCL)

        let elType = HEVCNALUType.unspec63
        XCTAssertEqual(elType.rawValue, 63)
        XCTAssertTrue(elType.isDolbyVisionEL)

        let idr = HEVCNALUType.idrWRADL
        XCTAssertTrue(idr.isVCL)
        XCTAssertTrue(idr.isKeyframe)
    }

    func testLevel1PQToNits() {
        // PQ 0 对应 0 nits
        XCTAssertEqual(DolbyLevel1Metadata.pqToNits(0), 0.0, accuracy: 0.001)

        // 1000 nits 大约对应 PQ 3079
        let nits1000 = DolbyLevel1Metadata.pqToNits(3079)
        XCTAssertEqual(nits1000, 1000.0, accuracy: 50.0)

        // 100 nits (SDR 参考白点) 大约对应 PQ 2081
        let nits100 = DolbyLevel1Metadata.pqToNits(2081)
        XCTAssertEqual(nits100, 100.0, accuracy: 10.0)
    }

    // MARK: - 2. NALUParser & Emulation Prevention Tests

    func testAnnexBParsing() {
        // 构造包含 SPS (33), PPS (34), RPU (62) 的 Annex B 比特流
        var stream = Data()

        // 1. 4-byte start code + SPS (nal_unit_type = 33 -> 0x42 0x01)
        stream.append(contentsOf: [0x00, 0x00, 0x00, 0x01, 0x42, 0x01, 0xAA, 0xBB])

        // 2. 3-byte start code + PPS (nal_unit_type = 34 -> 0x44 0x01)
        stream.append(contentsOf: [0x00, 0x00, 0x01, 0x44, 0x01, 0xCC])

        // 3. 4-byte start code + Dolby RPU (nal_unit_type = 62 -> 0x7C 0x01)
        stream.append(contentsOf: [0x00, 0x00, 0x00, 0x01, 0x7C, 0x01, 0x08, 0x1F, 0xEE])

        let units = NALUParser.parse(annexBData: stream)
        XCTAssertEqual(units.count, 3)

        XCTAssertEqual(units[0].type.rawValue, 33)
        XCTAssertEqual(units[0].startCodeLength, 4)

        XCTAssertEqual(units[1].type.rawValue, 34)
        XCTAssertEqual(units[1].startCodeLength, 3)

        XCTAssertEqual(units[2].type.rawValue, 62)
        XCTAssertTrue(units[2].isDolbyVisionRPU)

        // 提取 RPU 专有过滤
        let rpus = NALUParser.extractRPUNALUs(from: stream)
        XCTAssertEqual(rpus.count, 1)
        XCTAssertEqual(rpus[0].type.rawValue, 62)
    }

    func testEmulationPreventionUnescapeAndEscape() {
        // 测试 00 00 03 01 (防竞争码 0x03)
        let ebsp = Data([0x11, 0x00, 0x00, 0x03, 0x01, 0x22, 0x00, 0x00, 0x03, 0x02, 0x33])
        let rbsp = NALUParser.unescapeEBSP(ebsp)
        XCTAssertEqual(rbsp, Data([0x11, 0x00, 0x00, 0x01, 0x22, 0x00, 0x00, 0x02, 0x33]))

        // 重新转义逃逸
        let reEscaped = NALUParser.escapeRBSP(rbsp)
        XCTAssertEqual(reEscaped, ebsp)
    }

    func testNALUStreamParserChunks() {
        let streamParser = NALUStreamParser()

        // 模拟网络分包流式输入
        // chunk 1: 包含 NALU 62 起始码和部分数据，尚未闭合
        let chunk1 = Data([0x00, 0x00, 0x00, 0x01, 0x7C, 0x01, 0x08, 0x12])
        let parsed1 = streamParser.append(data: chunk1)
        XCTAssertTrue(parsed1.isEmpty) // 未闭合，暂不输出

        // chunk 2: 补充数据并引入下一个起始码 (PPS 34)
        let chunk2 = Data([0x34, 0x00, 0x00, 0x01, 0x44, 0x01, 0xFF])
        let parsed2 = streamParser.append(data: chunk2)
        XCTAssertEqual(parsed2.count, 1)
        XCTAssertEqual(parsed2[0].type.rawValue, 62)

        // flush 输出残留的最后一个 NALU (PPS 34)
        let flushed = streamParser.flush()
        XCTAssertEqual(flushed.count, 1)
        XCTAssertEqual(flushed[0].type.rawValue, 34)
    }

    // MARK: - 3. RPUProcessor & Profile 7 -> 8.1 重构测试

    func testBitReaderAndWriter() {
        let writer = BitWriter()
        writer.writeBits(2, count: 6) // 000010
        writer.writeBits(0x07FE, count: 11)
        writer.writeBit(true)
        writer.writeBit(false)
        writer.writeUE(5) // ue(5)
        writer.writeSE(-3) // se(-3)
        writer.alignToByte()

        let data = writer.toData()
        let reader = BitReader(data: data)

        XCTAssertEqual(reader.readBits(6), 2)
        XCTAssertEqual(reader.readBits(11), 0x07FE)
        XCTAssertTrue(reader.readBit())
        XCTAssertFalse(reader.readBit())
        XCTAssertEqual(reader.readUE(), 5)
        XCTAssertEqual(reader.readSE(), -3)
    }

    func testProfile7To8_1Rewrite() {
        let processor = RPUProcessor()

        // 1. 模拟构造 UHD 蓝光原盘 Profile 7 FEL RPU
        let header = RpuDataHeader(
            rpuType: 2,
            rpuFormat: 0x07FE,
            vdrRpuProfile: 0, // Profile 7 在 RPU 头部中的原始标记
            vdrRpuLevel: 0,
            vdrSeqInfoPresent: true,
            chromaResamplingExplicitFilterFlag: false,
            coefDataType: 0,
            coefLog2Denom: 23,
            vdrRpuNormalizedIdc: 1,
            blVideoFullRangeFlag: false,
            blBitDepth: 10,
            elBitDepth: 12, // 12-bit FEL
            vdrBitDepth: 12,
            spatialResamplingFilterFlag: false,
            elSpatialResamplingFilterFlag: true, // FEL 开启空间重采样 (造成系统偏色根源)
            disableResidualFlag: false          // 开启增强层残差
        )

        let metadataP7 = DolbyVisionMetadata(
            header: header,
            level1: DolbyLevel1Metadata(minPQ: 10, maxPQ: 3079, avgPQ: 2000),
            level6: DolbyLevel6Metadata(maxDisplayMasteringLuminance: 1000, minDisplayMasteringLuminance: 50, maxCLL: 1000, maxFALL: 350)
        )

        let p7RBSP = processor.serializeRBSP(metadata: metadataP7)
        let p7NALU = NALUParser.packageRPUNALU(rbsp: p7RBSP)

        // 2. 执行核心重构算法：Profile 7 -> Profile 8.1
        guard let p81NALU = processor.convertProfile7To8_1(sourceRPUData: p7NALU) else {
            XCTFail("Failed to convert Profile 7 to Profile 8.1")
            return
        }

        // 3. 解析重构后的 RPU 验证各项关键字段
        guard let reconstructed = processor.parse(rpuData: p81NALU) else {
            XCTFail("Failed to parse reconstructed Profile 8.1 RPU")
            return
        }

        // 验证 Profile 标号已更改为 1 (Profile 8 规范)
        XCTAssertEqual(reconstructed.header.vdrRpuProfile, 1)

        // 验证已彻底清除 EL 空间重采样滤波标志 (消除偏色)
        XCTAssertFalse(reconstructed.header.elSpatialResamplingFilterFlag)

        // 验证已强制禁用增强层残差
        XCTAssertTrue(reconstructed.header.disableResidualFlag)

        // 验证动态元数据无损保留
        XCTAssertNotNil(reconstructed.level1)
        XCTAssertEqual(reconstructed.level1?.minPQ, 10)
        XCTAssertEqual(reconstructed.level1?.maxPQ, 3079)
        XCTAssertEqual(reconstructed.level1?.avgPQ, 2000)

        // 验证静态元数据保留
        XCTAssertNotNil(reconstructed.level6)
        XCTAssertEqual(reconstructed.level6?.maxCLL, 1000)
        XCTAssertEqual(reconstructed.level6?.maxFALL, 350)
    }

    func testDecoderConfigurationRecordGeneration() {
        // 生成标准 24 字节记录
        let record = RPUProcessor.makeDecoderConfigurationRecord(
            profile: .profile81,
            level: 6,
            rpuPresent: true,
            elPresent: false,
            blPresent: true
        )

        XCTAssertEqual(record.count, 24)

        // 验证二进制布局
        XCTAssertEqual(record[0], 1) // dv_version_major
        XCTAssertEqual(record[1], 0) // dv_version_minor

        // Profile 8 = 0b0001000, Level 6 = 0b000110
        // Byte 2: (8 << 1) | (6 >> 5) = 16 = 0x10
        XCTAssertEqual(record[2], 0x10)

        // Byte 3: ((6 & 0x1F) << 3) | (1 << 2) | (0 << 1) | 1 = 0x30 | 4 | 0 | 1 = 0x35
        XCTAssertEqual(record[3], 0x35)

        // Byte 4: dv_bl_signal_compatibility_id = 1 (HDR10 兼容) -> (1 << 4) = 0x10
        XCTAssertEqual(record[4], 0x10)

        // 验证 32 字节完整 Box
        let box = RPUProcessor.makeConfigurationBox(fourCC: "dv81", profile: .profile81, level: 6)
        XCTAssertEqual(box.count, 32)
        let fourCCString = String(decoding: box.subdata(in: 4..<8), as: UTF8.self)
        XCTAssertEqual(fourCCString, "dv81")
    }

    // MARK: - 4. CMSampleBuffer & CoreMedia 扩展测试

    func testDolbyVisionFormatDescriptionCreation() {
        let formatDesc = CMVideoFormatDescription.makeDolbyVisionFormatDescription(
            width: 3840,
            height: 2160,
            profile: .profile81,
            level: 6,
            level6: DolbyLevel6Metadata(maxCLL: 1000, maxFALL: 400)
        )

        XCTAssertNotNil(formatDesc)
        guard let desc = formatDesc else { return }

        let extensions = CMFormatDescriptionGetExtensions(desc) as? [String: Any]
        XCTAssertNotNil(extensions)

        // 验证 SampleDescriptionExtensionAtoms
        let atoms = extensions?[kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms as String] as? [String: Any]
        XCTAssertNotNil(atoms)
        XCTAssertNotNil(atoms?["dvcC"])
        XCTAssertNotNil(atoms?["dv81"])

        if let dvcCData = atoms?["dvcC"] as? Data {
            XCTAssertEqual(dvcCData.count, 24)
        }

        // 验证色彩空间扩展
        let colorPrimaries = extensions?[kCMFormatDescriptionExtension_ColorPrimaries as String] as? String
        XCTAssertEqual(colorPrimaries, kCVImageBufferColorPrimaries_ITU_R_2020 as String)

        let transferFunction = extensions?[kCMFormatDescriptionExtension_TransferFunction as String] as? String
        XCTAssertEqual(transferFunction, kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ as String)

        // 验证 CLLI 扩展
        let clli = extensions?[kCMFormatDescriptionExtension_ContentLightLevelInfo as String] as? Data
        XCTAssertEqual(clli?.count, 4)
    }

    func testCMSampleBufferWithPixelBuffer() throws {
        // 创建测试 CVPixelBuffer (1920 x 1080, 10-bit 420 YpCbCr)
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            1920,
            1080,
            kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
            nil,
            &pixelBuffer
        )
        XCTAssertEqual(status, kCVReturnSuccess)
        guard let pb = pixelBuffer else { return }

        var baseFormat: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pb, formatDescriptionOut: &baseFormat)
        guard let baseFmt = baseFormat else { return }

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 60),
            presentationTimeStamp: .zero,
            decodeTimeStamp: .invalid
        )

        var sampleBuffer: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pb,
            formatDescription: baseFmt,
            sampleTiming: &timing,
            sampleBufferOut: &sampleBuffer
        )

        guard let originalBuffer = sampleBuffer else {
            XCTFail("Failed to create base CMSampleBuffer")
            return
        }

        let fakeRPU = Data([0x00, 0x00, 0x00, 0x01, 0x7C, 0x01, 0x08, 0x11, 0x22])

        // 注入杜比视界元数据
        let dolbyBuffer = try originalBuffer.injectingDolbyVision(
            rpuNALUData: fakeRPU,
            profile: .profile81,
            level: 6
        )

        // 验证 RPU 数据附件提取
        let extractedRPU = dolbyBuffer.dolbyVisionRPUData
        XCTAssertEqual(extractedRPU, fakeRPU)
    }

    func testCMSampleBufferWithBlockBuffer() throws {
        // 创建测试 HEVC 压缩数据块 (CMBlockBuffer)
        let fakeHEVCData = Data([0x00, 0x00, 0x00, 0x01, 0x42, 0x01, 0x11, 0x22, 0x33, 0x44])
        var blockBuffer: CMBlockBuffer?
        let blockStatus = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: fakeHEVCData.count,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: fakeHEVCData.count,
            flags: kCMBlockBufferAssureMemoryNowFlag,
            blockBufferOut: &blockBuffer
        )
        XCTAssertEqual(blockStatus, noErr)
        guard let bb = blockBuffer else { return }

        fakeHEVCData.withUnsafeBytes { rawPtr in
            guard let addr = rawPtr.baseAddress else { return }
            CMBlockBufferReplaceDataBytes(with: addr, blockBuffer: bb, offsetIntoDestination: 0, dataLength: fakeHEVCData.count)
        }

        guard let baseFmt = CMVideoFormatDescription.makeDolbyVisionFormatDescription(
            codecType: kCMVideoCodecType_HEVC,
            width: 3840,
            height: 2160,
            profile: .profile81,
            level: 6
        ) else {
            XCTFail("Failed to create format description")
            return
        }

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 60),
            presentationTimeStamp: .zero,
            decodeTimeStamp: .invalid
        )

        var sampleBuffer: CMSampleBuffer?
        CMSampleBufferCreate(
            allocator: kCFAllocatorDefault,
            dataBuffer: bb,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: baseFmt,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 0,
            sampleSizeArray: nil,
            sampleBufferOut: &sampleBuffer
        )

        guard let originalBuffer = sampleBuffer else {
            XCTFail("Failed to create compressed CMSampleBuffer")
            return
        }

        let fakeRPU = Data([0x00, 0x00, 0x00, 0x01, 0x7C, 0x01, 0x08, 0x11, 0x22])

        // 注入杜比视界元数据
        let dolbyBuffer = try originalBuffer.injectingDolbyVision(
            rpuNALUData: fakeRPU,
            profile: .profile81,
            level: 6
        )

        guard let dolbyFmt = CMSampleBufferGetFormatDescription(dolbyBuffer) else {
            XCTFail("Missing format description")
            return
        }

        let ext = CMFormatDescriptionGetExtensions(dolbyFmt) as? [String: Any]
        let atoms = ext?[kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms as String] as? [String: Any]
        XCTAssertNotNil(atoms?["dv81"])
        XCTAssertNotNil(atoms?["dvcC"])

        let extractedRPU = dolbyBuffer.dolbyVisionRPUData
        XCTAssertEqual(extractedRPU, fakeRPU)
    }
}
