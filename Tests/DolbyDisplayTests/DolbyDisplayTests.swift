import XCTest
import CoreGraphics
@testable import DolbyDisplay

final class DolbyDisplayTests: XCTestCase {

    // MARK: - 辅助生成合成 EDID

    private func createSyntheticEDID(withDolbyPayload dvPayload: [UInt8], isV2: Bool = true) -> Data {
        var baseBlock = [UInt8](repeating: 0, count: 128)
        // 1. Magic Header
        baseBlock[0] = 0x00
        baseBlock[1] = 0xFF
        baseBlock[2] = 0xFF
        baseBlock[3] = 0xFF
        baseBlock[4] = 0xFF
        baseBlock[5] = 0xFF
        baseBlock[6] = 0xFF
        baseBlock[7] = 0x00

        // 2. Manufacturer "GSM" (LG)
        // G=7, S=19, M=13
        let mfg: UInt16 = (7 << 10) | (19 << 5) | 13
        baseBlock[8] = UInt8(mfg >> 8)
        baseBlock[9] = UInt8(mfg & 0xFF)

        // 3. Product code
        baseBlock[10] = 0x34
        baseBlock[11] = 0x12

        // 4. EDID 1.3
        baseBlock[18] = 0x01
        baseBlock[19] = 0x03

        // 5. Monitor Name Descriptor at offset 54
        baseBlock[54] = 0x00
        baseBlock[55] = 0x00
        baseBlock[56] = 0x00
        baseBlock[57] = 0xFC // Monitor Name Tag
        baseBlock[58] = 0x00
        let nameBytes = Array("LG OLED TV\n ".utf8)
        for (idx, b) in nameBytes.prefix(13).enumerated() {
            baseBlock[59 + idx] = b
        }

        // 6. Extension block count = 1
        baseBlock[126] = 0x01

        // Checksum for baseBlock
        let baseSum = baseBlock.prefix(127).reduce(0) { ($0 + Int($1)) & 0xFF }
        baseBlock[127] = UInt8((256 - baseSum) & 0xFF)

        // 7. CEA-861 Extension Block
        var extBlock = [UInt8](repeating: 0, count: 128)
        extBlock[0] = 0x02 // CEA-861 Tag
        extBlock[1] = 0x03 // Revision 3
        extBlock[2] = 0x50 // DTD offset
        extBlock[3] = 0x00

        // 构造 Extended Tag 0x01 (VSVDB) 杜比视界数据块
        // VSVDB Payload: [Extended Tag 0x01, OUI byte0, OUI byte1, OUI byte2] + dvPayload
        let vsvdbPayload: [UInt8] = [0x01, 0x46, 0xD0, 0x00] + dvPayload
        let vsvdbHeader: UInt8 = (7 << 5) | UInt8(vsvdbPayload.count & 0x1F)

        var ctaData: [UInt8] = [vsvdbHeader] + vsvdbPayload

        // 追加 HDR Static Metadata Data Block (Tag 7, ExtTag 0x06)
        // EOTF: 0x0C (SMPTE ST 2084 + HLG)
        let hdrPayload: [UInt8] = [0x06, 0x0C, 0x00, 128, 128, 0]
        let hdrHeader: UInt8 = (7 << 5) | UInt8(hdrPayload.count & 0x1F)
        ctaData.append(hdrHeader)
        ctaData.append(contentsOf: hdrPayload)

        for (idx, b) in ctaData.enumerated() {
            extBlock[4 + idx] = b
        }

        // Checksum for extBlock
        let extSum = extBlock.prefix(127).reduce(0) { ($0 + Int($1)) & 0xFF }
        extBlock[127] = UInt8((256 - extSum) & 0xFF)

        return Data(baseBlock + extBlock)
    }

    // MARK: - 测试用例

    func testEDIDParserBaseHeaderAndMetadata() {
        let dvV2Payload: [UInt8] = [
            0x21, // Version 1 (V2 spec: version=1, dm=0, 2160p60=1)
            0x03, // Both Standard & LLDV supported
            0x00, // Colorimetry: BT.2020
            36,   // Tmax: 100 + 36 * 25 = 1000 nits
            0     // Tmin: 0.0 nits
        ]

        let edidData = createSyntheticEDID(withDolbyPayload: dvV2Payload, isV2: true)
        let parsed = EDIDParser.parse(data: edidData)

        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?.manufacturer, "GSM")
        XCTAssertEqual(parsed?.productCode, 0x1234)
        XCTAssertEqual(parsed?.displayName, "LG OLED TV")
        XCTAssertEqual(parsed?.extensionBlockCount, 1)
    }

    func testDolbyVisionV2DualModeParsing() {
        let dvV2Payload: [UInt8] = [
            0x21, // Version 1 in bits 7..5 (Dolby V2)
            0x03, // Both Standard & LLDV
            0x00,
            36,   // 1000 nits
            10
        ]

        let edidData = createSyntheticEDID(withDolbyPayload: dvV2Payload, isV2: true)
        guard let parsed = EDIDParser.parse(data: edidData) else {
            XCTFail("Failed to parse EDID")
            return
        }

        XCTAssertTrue(parsed.dolbyVision.isSupported)
        XCTAssertEqual(parsed.dolbyVision.mode, .both)
        XCTAssertEqual(parsed.dolbyVision.version, .v2)
        XCTAssertEqual(parsed.dolbyVision.targetMaxLuminance, 1000.0, accuracy: 1.0)
        XCTAssertTrue(parsed.dolbyVision.supports2160p60)
        XCTAssertEqual(parsed.dolbyVision.colorPrimaries, .bt2020)
    }

    func testDolbyVisionV1StandardModeParsing() {
        // V1 payload: version=0
        var v1Payload = [UInt8](repeating: 0, count: 24)
        v1Payload[0] = 0x01 // Version 0, 2160p60=1
        v1Payload[1] = 0x00 // Standard only (no YUV422 12-bit)
        v1Payload[20] = 20  // Max Lum code: 100 + 20 * 35 = 800 nits

        let edidData = createSyntheticEDID(withDolbyPayload: v1Payload, isV2: false)
        guard let parsed = EDIDParser.parse(data: edidData) else {
            XCTFail("Failed to parse EDID")
            return
        }

        XCTAssertTrue(parsed.dolbyVision.isSupported)
        XCTAssertEqual(parsed.dolbyVision.mode, .standard)
        XCTAssertEqual(parsed.dolbyVision.version, .v1)
        XCTAssertGreaterThan(parsed.dolbyVision.targetMaxLuminance, 700.0)
    }

    func testHDRStaticMetadataBlockParsing() {
        let dvV2Payload: [UInt8] = [0x21, 0x03, 0x00, 36, 0]
        let edidData = createSyntheticEDID(withDolbyPayload: dvV2Payload)
        let parsed = EDIDParser.parse(data: edidData)

        XCTAssertNotNil(parsed?.hdrStaticMetadata)
        XCTAssertTrue(parsed?.hdrStaticMetadata?.supportsSMPTE2084 == true)
        XCTAssertTrue(parsed?.hdrStaticMetadata?.supportsHLG == true)
    }

    func testCoreDisplayBridgeInitializationAndProbing() {
        let bridge = CoreDisplayBridge.shared
        let mainDisplayID = CGMainDisplayID()
        let caps = bridge.probeDisplayCapabilities(displayID: mainDisplayID)

        XCTAssertEqual(caps.displayID, mainDisplayID)
        XCTAssertGreaterThanOrEqual(caps.nominalBitDepth, 8)
    }

    @MainActor
    func testDisplayEDRManagerCurrentState() {
        let manager = DisplayEDRManager.shared
        manager.updateAllScreenStates()

        let states = manager.currentStates
        XCTAssertFalse(states.isEmpty)

        let mainID = CGMainDisplayID()
        if let mainState = states[mainID] {
            XCTAssertGreaterThanOrEqual(mainState.currentHeadroom, 1.0)
            XCTAssertGreaterThanOrEqual(mainState.maxPotentialHeadroom, 1.0)
        }
    }

    @MainActor
    func testExternalDisplayCoordinatorEvaluation() {
        let coordinator = ExternalDisplayCoordinator.shared
        let evals = coordinator.evaluateAllDisplays()

        XCTAssertFalse(evals.isEmpty)
        let best = coordinator.findBestDisplayForDolbyVision()
        XCTAssertNotNil(best)
        XCTAssertGreaterThan(best?.score ?? 0, 0)
    }
}
