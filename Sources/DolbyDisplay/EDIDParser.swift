import Foundation
import CoreGraphics
import IOKit
import IOKit.graphics
import os.log

private let logger = Logger(subsystem: "com.dould.DolbyDisplay", category: "EDIDParser")

// MARK: - Dolby Vision Modes & Models

/// 支持的杜比视界工作模式
public enum DolbyVisionMode: String, Sendable, CustomStringConvertible {
    /// 标准杜比视界 (TV-Led / Sink-Led, RGB 8-bit 伪装隧道传输)
    case standard = "Standard DV (Sink-Led)"
    /// 低延迟杜比视界 (Player-Led / Source-Led, YCbCr 4:2:2 12-bit / RGB 10/12-bit)
    case lldv = "Low Latency DV (LLDV / Source-Led)"
    /// 同时支持标准杜比视界与 LLDV
    case both = "Standard & LLDV (Dual Supported)"
    /// 不支持杜比视界
    case unsupported = "Unsupported"

    public var description: String { rawValue }

    public var isSupported: Bool {
        return self != .unsupported
    }
}

/// 杜比视界 VSVDB 版本规范
public enum DolbyVisionVersion: String, Sendable {
    case v1 = "Version 1 (24-byte Payload)"
    case v2 = "Version 2 (12-15 byte Payload)"
    case unknown = "Unknown Version"
}

/// 显示器色彩原色基准坐标 (CIE 1931 xy)
public struct DisplayColorPrimaries: Sendable, Equatable {
    public let red: (x: Double, y: Double)
    public let green: (x: Double, y: Double)
    public let blue: (x: Double, y: Double)
    public let white: (x: Double, y: Double)

    public init(red: (x: Double, y: Double),
                green: (x: Double, y: Double),
                blue: (x: Double, y: Double),
                white: (x: Double, y: Double)) {
        self.red = red
        self.green = green
        self.blue = blue
        self.white = white
    }

    /// 标准 BT.2020 原色坐标
    public static let bt2020 = DisplayColorPrimaries(
        red: (0.708, 0.292),
        green: (0.170, 0.797),
        blue: (0.131, 0.046),
        white: (0.3127, 0.3290)
    )

    /// 标准 DCI-P3 (D65) 原色坐标
    public static let dciP3 = DisplayColorPrimaries(
        red: (0.680, 0.320),
        green: (0.265, 0.690),
        blue: (0.150, 0.060),
        white: (0.3127, 0.3290)
    )

    /// 标准 BT.709 / sRGB 原色坐标
    public static let bt709 = DisplayColorPrimaries(
        red: (0.640, 0.330),
        green: (0.300, 0.600),
        blue: (0.150, 0.060),
        white: (0.3127, 0.3290)
    )

    public static func == (lhs: DisplayColorPrimaries, rhs: DisplayColorPrimaries) -> Bool {
        return abs(lhs.red.x - rhs.red.x) < 0.001 &&
               abs(lhs.red.y - rhs.red.y) < 0.001 &&
               abs(lhs.green.x - rhs.green.x) < 0.001 &&
               abs(lhs.green.y - rhs.green.y) < 0.001 &&
               abs(lhs.blue.x - rhs.blue.x) < 0.001 &&
               abs(lhs.blue.y - rhs.blue.y) < 0.001 &&
               abs(lhs.white.x - rhs.white.x) < 0.001 &&
               abs(lhs.white.y - rhs.white.y) < 0.001
    }
}

/// 杜比视界 Vendor-Specific Video Data Block 解析结果
public struct DolbyVisionCapability: Sendable {
    public let isSupported: Bool
    public let mode: DolbyVisionMode
    public let version: DolbyVisionVersion
    public let dmVersionMajor: Int
    public let supports2160p60: Bool
    public let targetMaxLuminance: Double // 单位：nits
    public let targetMinLuminance: Double // 单位：nits
    public let colorPrimaries: DisplayColorPrimaries
    public let rawPayload: Data

    public static let unsupported = DolbyVisionCapability(
        isSupported: false,
        mode: .unsupported,
        version: .unknown,
        dmVersionMajor: 0,
        supports2160p60: false,
        targetMaxLuminance: 0.0,
        targetMinLuminance: 0.0,
        colorPrimaries: .bt709,
        rawPayload: Data()
    )
}

/// HDR 静态元数据 (CTA-861 Tag 7 Sub-tag 6)
public struct HDRStaticMetadataCapability: Sendable {
    public let isSupported: Bool
    public let supportsTraditionalSDR: Bool
    public let supportsTraditionalHDR: Bool
    public let supportsSMPTE2084: Bool // PQ (HDR10 / Dolby Vision)
    public let supportsHLG: Bool       // ARIB STD-B67
    public let desiredMaxLuminance: Double? // nits
    public let desiredMaxFrameAverageLuminance: Double? // nits
    public let desiredMinLuminance: Double? // nits
}

/// 完整的 EDID 解析信息结构体
public struct ParsedEDID: Sendable {
    public let manufacturer: String
    public let productCode: UInt16
    public let serialNumber: UInt32
    public let displayName: String
    public let edidVersion: String
    public let extensionBlockCount: Int
    public let dolbyVision: DolbyVisionCapability
    public let hdrStaticMetadata: HDRStaticMetadataCapability?
    public let rawData: Data
}

// MARK: - EDIDParser

/// IOKit EDID 提取器与 CEA-861 / 杜比 VSVDB 深度解析器
public final class EDIDParser: Sendable {

    /// 杜比实验室 IEEE 注册专有 OUI: 0x00D046
    public static let dolbyIEEE_OUI: UInt32 = 0x00D046

    public init() {}

    // MARK: - IOKit 注册表抓取

    /// 从 IOKit 注册表提取指定 CGDirectDisplayID 对应的原始 EDID 二进制数据
    /// - Parameter displayID: CoreGraphics 显示器 ID
    /// - Returns: 原始 EDID 二进制 Data，若未找到则返回 nil
    public static func fetchEDID(for displayID: CGDirectDisplayID) -> Data? {
        let matching = IOServiceMatching("IODisplayConnect")
        var iterator: io_iterator_t = 0
        let kr = IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator)
        guard kr == KERN_SUCCESS else {
            logger.error("Failed to query IODisplayConnect services: \(kr)")
            return nil
        }
        defer { IOObjectRelease(iterator) }

        let targetVendor = CGDisplayVendorNumber(displayID)
        let targetModel = CGDisplayModelNumber(displayID)
        let targetSerial = CGDisplaySerialNumber(displayID)

        var service = IOIteratorNext(iterator)
        var fallbackEDID: Data? = nil

        while service != 0 {
            defer {
                IOObjectRelease(service)
                service = IOIteratorNext(iterator)
            }

            guard let info = IODisplayCreateInfoDictionary(service, IOOptionBits(kIODisplayOnlyPreferredName))?
                .takeRetainedValue() as? [String: Any] else {
                continue
            }

            guard let edidData = info[kIODisplayEDIDKey] as? Data else {
                continue
            }

            if fallbackEDID == nil {
                fallbackEDID = edidData
            }

            // 匹配 VendorID 与 ProductID
            let vendorID = (info[kDisplayVendorID] as? UInt32) ?? (info["IODisplayVendorID"] as? UInt32) ?? 0
            let productID = (info[kDisplayProductID] as? UInt32) ?? (info["IODisplayProductID"] as? UInt32) ?? 0
            let serialNum = (info[kDisplaySerialNumber] as? UInt32) ?? (info["IODisplaySerialNumber"] as? UInt32) ?? 0

            if vendorID == targetVendor && productID == targetModel {
                if targetSerial == 0 || serialNum == 0 || serialNum == targetSerial {
                    logger.debug("Matched IOKit EDID for displayID \(displayID) (vendor: \(vendorID), model: \(productID))")
                    return edidData
                }
            }
        }

        logger.debug("No exact vendor/model match for displayID \(displayID), returning fallback EDID if available")
        return fallbackEDID
    }

    /// 获取系统中所有连接显示器的 EDID 数据字典
    /// - Returns: 字典映射 [CGDirectDisplayID: Data]
    public static func fetchAllDisplayEDIDs() -> [CGDirectDisplayID: Data] {
        var results: [CGDirectDisplayID: Data] = [:]
        var activeDisplays = [CGDirectDisplayID](repeating: 0, count: 16)
        var displayCount: UInt32 = 0

        guard CGGetActiveDisplayList(16, &activeDisplays, &displayCount) == .success else {
            return results
        }

        for i in 0..<Int(displayCount) {
            let displayID = activeDisplays[i]
            if let edid = fetchEDID(for: displayID) {
                results[displayID] = edid
            }
        }

        return results
    }

    // MARK: - EDID 与 CEA-861 深度解析

    /// 解析指定 EDID 二进制数据
    /// - Parameter data: 原始 EDID 字节流 (至少 128 字节)
    /// - Returns: 解析后的 ParsedEDID 结果，格式异常则返回 nil
    public static func parse(data: Data) -> ParsedEDID? {
        guard data.count >= 128 else {
            logger.error("EDID buffer size too small: \(data.count) bytes (expected at least 128)")
            return nil
        }

        // 1. 验证 Base EDID 头部魔数 00 FF FF FF FF FF FF 00
        let magic: [UInt8] = [0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x00]
        guard data.prefix(8).elementsEqual(magic) else {
            logger.error("EDID magic header mismatch")
            return nil
        }

        // 2. 提取厂商代码 (EISA 3-letter code, Bytes 8-9)
        let mfgByte1 = UInt16(data[8])
        let mfgByte2 = UInt16(data[9])
        let mfgPacked = (mfgByte1 << 8) | mfgByte2
        let char1 = Character(UnicodeScalar(UInt8(((mfgPacked >> 10) & 0x1F) + 64)))
        let char2 = Character(UnicodeScalar(UInt8(((mfgPacked >> 5) & 0x1F) + 64)))
        let char3 = Character(UnicodeScalar(UInt8((mfgPacked & 0x1F) + 64)))
        let manufacturer = "\(char1)\(char2)\(char3)"

        // 3. 产品代码与序列号 (Bytes 10-15)
        let productCode = UInt16(data[10]) | (UInt16(data[11]) << 8)
        let serialNumber = UInt32(data[12]) | (UInt32(data[13]) << 8) |
                           (UInt32(data[14]) << 16) | (UInt32(data[15]) << 24)

        // 4. EDID 版本与修订号 (Bytes 18-19)
        let edidVer = "\(data[18]).\(data[19])"

        // 5. 显示器名称提取 (检查 4 个 18-byte 描述符块 Bytes 54-125)
        var displayName = "Unknown Display"
        for descriptorIndex in 0..<4 {
            let offset = 54 + (descriptorIndex * 18)
            guard offset + 18 <= 126 else { break }
            let descriptor = data.subdata(in: offset..<(offset + 18))
            // 标志位：前两个字节为 0x0000 且第三个为 0x00 时代表 Display Descriptor
            if descriptor[0] == 0x00 && descriptor[1] == 0x00 && descriptor[2] == 0x00 {
                let tag = descriptor[3]
                if tag == 0xFC { // Monitor Name Tag
                    let rawBytes = descriptor.subdata(in: 5..<18)
                    let cleanBytes = rawBytes.prefix { $0 != 0x0A && $0 != 0x00 }
                    if let string = String(data: cleanBytes, encoding: .ascii)?
                        .trimmingCharacters(in: .whitespacesAndNewlines), !string.isEmpty {
                        displayName = string
                    }
                }
            }
        }

        // 6. 扩展块数量 (Byte 126)
        let extensionBlocks = Int(data[126])
        var dolbyCapability: DolbyVisionCapability = .unsupported
        var hdrStaticCapability: HDRStaticMetadataCapability? = nil

        // 7. 遍历所有扩展块 (每个扩展块 128 字节)
        if extensionBlocks > 0 && data.count >= 128 * (1 + extensionBlocks) {
            for extIndex in 1...extensionBlocks {
                let blockOffset = extIndex * 128
                let blockData = data.subdata(in: blockOffset..<(blockOffset + 128))
                let tag = blockData[0]

                // CEA-861 / CTA-861 扩展块 Tag 为 0x02
                if tag == 0x02 {
                    let parsedBlocks = parseCEAExtensionBlock(blockData: blockData)
                    if parsedBlocks.dolby.isSupported {
                        dolbyCapability = parsedBlocks.dolby
                    }
                    if let hdr = parsedBlocks.hdrStatic {
                        hdrStaticCapability = hdr
                    }
                }
            }
        }

        return ParsedEDID(
            manufacturer: manufacturer,
            productCode: productCode,
            serialNumber: serialNumber,
            displayName: displayName,
            edidVersion: edidVer,
            extensionBlockCount: extensionBlocks,
            dolbyVision: dolbyCapability,
            hdrStaticMetadata: hdrStaticCapability,
            rawData: data
        )
    }

    // MARK: - CEA-861 扩展块解析逻辑

    private struct CEAParsedResult {
        var dolby: DolbyVisionCapability = .unsupported
        var hdrStatic: HDRStaticMetadataCapability? = nil
    }

    private static func parseCEAExtensionBlock(blockData: Data) -> CEAParsedResult {
        var result = CEAParsedResult()
        guard blockData.count >= 128 else { return result }

        // Byte 2: DTD (Detailed Timing Descriptors) 起始偏移量
        // 数据块集合位于 Byte 4 ..< dtdOffset
        let dtdOffset = Int(blockData[2])
        guard dtdOffset >= 4 && dtdOffset <= 127 else { return result }

        var offset = 4
        while offset < dtdOffset {
            let header = blockData[offset]
            let tag = (header >> 5) & 0x07
            let length = Int(header & 0x1F)
            let blockPayloadStart = offset + 1
            let blockPayloadEnd = blockPayloadStart + length

            guard blockPayloadEnd <= dtdOffset else {
                break
            }

            let payload = blockData.subdata(in: blockPayloadStart..<blockPayloadEnd)

            if tag == 3 {
                // Tag 3: Vendor-Specific Data Block (VSDB)
                if let dv = parseVSDBForDolbyVision(payload: payload) {
                    result.dolby = dv
                }
            } else if tag == 7 {
                // Tag 7: Extended Data Block (使用扩展标签)
                if payload.count >= 1 {
                    let extendedTag = payload[0]
                    let extendedPayload = payload.subdata(in: 1..<payload.count)

                    if extendedTag == 0x01 {
                        // Extended Tag 0x01: Vendor-Specific Video Data Block (VSVDB)
                        if let dv = parseVSVDBForDolbyVision(payload: extendedPayload) {
                            result.dolby = dv
                        }
                    } else if extendedTag == 0x06 {
                        // Extended Tag 0x06: HDR Static Metadata Data Block
                        result.hdrStatic = parseHDRStaticMetadataBlock(payload: extendedPayload)
                    }
                }
            }

            offset = blockPayloadEnd
        }

        return result
    }

    // MARK: - 杜比专有块解析 (IEEE OUI: 0x00D046)

    /// 解析 Tag 3 (VSDB)
    private static func parseVSDBForDolbyVision(payload: Data) -> DolbyVisionCapability? {
        guard payload.count >= 3 else { return nil }
        // IEEE OUI 以 Little-Endian 存储: 0x46, 0xD0, 0x00
        let oui = UInt32(payload[0]) | (UInt32(payload[1]) << 8) | (UInt32(payload[2]) << 16)
        guard oui == dolbyIEEE_OUI else { return nil }

        let dvData = payload.subdata(in: 3..<payload.count)
        return decodeDolbyVisionPayload(dvData)
    }

    /// 解析 Extended Tag 0x01 (VSVDB)
    private static func parseVSVDBForDolbyVision(payload: Data) -> DolbyVisionCapability? {
        guard payload.count >= 3 else { return nil }
        let oui = UInt32(payload[0]) | (UInt32(payload[1]) << 8) | (UInt32(payload[2]) << 16)
        guard oui == dolbyIEEE_OUI else { return nil }

        let dvData = payload.subdata(in: 3..<payload.count)
        return decodeDolbyVisionPayload(dvData)
    }

    /// 解析杜比专有负载 (根据 Dolby Vision V1 与 V2 规范解算)
    private static func decodeDolbyVisionPayload(_ dvData: Data) -> DolbyVisionCapability {
        guard dvData.count >= 2 else {
            return .unsupported
        }

        let byte0 = dvData[0]
        let versionBits = (byte0 >> 5) & 0x07
        let dmVersionMajor = Int((byte0 >> 2) & 0x07)
        let supports2160p60 = (byte0 & 0x01) != 0

        let byte1 = dvData[1]
        var mode: DolbyVisionMode = .unsupported
        var version: DolbyVisionVersion = .unknown
        var targetMaxLuminance: Double = 1000.0
        var targetMinLuminance: Double = 0.005
        var primaries: DisplayColorPrimaries = .bt2020

        if versionBits == 0 {
            // Version 1 (通常 24-25 字节)
            version = .v1
            let supportYUV422 = (byte1 & 0x01) != 0
            if supportYUV422 {
                mode = .both // 同时支持标准 RGB 8-bit Tunnel 与 LLDV 12-bit YUV422
            } else {
                mode = .standard
            }

            // V1: 目标最大与最小亮度解析
            if dvData.count >= 22 {
                // Byte 20: Target Max Luminance Code
                let maxLumCode = dvData[20]
                if maxLumCode > 0 {
                    // 经验解算公式：100 + code * 25 ~ 50 nits
                    targetMaxLuminance = max(100.0, 100.0 + Double(maxLumCode) * 35.0)
                }
                // Byte 21: Target Min Luminance Code
                let minLumCode = dvData[21]
                targetMinLuminance = pow(Double(minLumCode) / 255.0, 2.0) * 0.05
            }

            // V1 原色坐标解算 (如果包含完整 24 字节坐标)
            if dvData.count >= 18 {
                primaries = extractV1Primaries(dvData: dvData)
            }
        } else if versionBits == 1 {
            // Version 2 (通常 12-15 字节，如 LG C1/C2/G3/G4, Sony A90J 等)
            version = .v2
            let standardFlag = (byte1 & 0x01) != 0
            let lldvFlag = (byte1 & 0x02) != 0

            if standardFlag && lldvFlag {
                mode = .both
            } else if lldvFlag {
                mode = .lldv
            } else if standardFlag {
                mode = .standard
            } else {
                // 某些固件仅设置了低延迟模式位在 byte1 高位
                mode = (byte1 & 0x03) > 0 ? .both : .lldv
            }

            // V2: 解算最大/最小亮度
            if dvData.count >= 5 {
                let maxLumVal = dvData[3]
                if maxLumVal > 0 {
                    // Dolby V2 Tmax 解算: 100 + val * 25 nits
                    targetMaxLuminance = 100.0 + Double(maxLumVal) * 25.0
                }
                let minLumVal = dvData[4]
                targetMinLuminance = pow(Double(minLumVal) / 255.0, 2.0) * 0.05
            }

            // 检查原色模式
            if dvData.count >= 7 {
                let colorimetryFlag = (dvData[2] >> 1) & 0x01
                primaries = (colorimetryFlag == 1) ? .dciP3 : .bt2020
            }
        } else {
            // 未知高版本 Dolby Vision 块
            version = .unknown
            mode = .both
            targetMaxLuminance = 1000.0
            targetMinLuminance = 0.005
        }

        return DolbyVisionCapability(
            isSupported: mode.isSupported,
            mode: mode,
            version: version,
            dmVersionMajor: dmVersionMajor,
            supports2160p60: supports2160p60,
            targetMaxLuminance: targetMaxLuminance,
            targetMinLuminance: targetMinLuminance,
            colorPrimaries: primaries,
            rawPayload: dvData
        )
    }

    private static func extractV1Primaries(dvData: Data) -> DisplayColorPrimaries {
        // V1 色彩坐标通常在偏移 2..14
        guard dvData.count >= 14 else { return .bt2020 }
        let rx = Double(dvData[2]) / 255.0 * 0.8
        let ry = Double(dvData[3]) / 255.0 * 0.8
        let gx = Double(dvData[4]) / 255.0 * 0.8
        let gy = Double(dvData[5]) / 255.0 * 0.9
        let bx = Double(dvData[6]) / 255.0 * 0.3
        let by = Double(dvData[7]) / 255.0 * 0.3
        let wx = Double(dvData[8]) / 255.0 * 0.5
        let wy = Double(dvData[9]) / 255.0 * 0.5

        // 合理性校验，若接近 0 则回退至 BT.2020
        if rx > 0.5 && ry > 0.2 && gy > 0.6 {
            return DisplayColorPrimaries(
                red: (rx, ry),
                green: (gx, gy),
                blue: (bx, by),
                white: (wx, wy)
            )
        }
        return .bt2020
    }

    // MARK: - HDR 静态元数据块解析 (Extended Tag 0x06)

    private static func parseHDRStaticMetadataBlock(payload: Data) -> HDRStaticMetadataCapability {
        guard payload.count >= 2 else {
            return HDRStaticMetadataCapability(
                isSupported: false,
                supportsTraditionalSDR: false,
                supportsTraditionalHDR: false,
                supportsSMPTE2084: false,
                supportsHLG: false,
                desiredMaxLuminance: nil,
                desiredMaxFrameAverageLuminance: nil,
                desiredMinLuminance: nil
            )
        }

        let eotf = payload[0]
        let supportsSDR = (eotf & 0x01) != 0
        let supportsTraditionalHDR = (eotf & 0x02) != 0
        let supportsSMPTE2084 = (eotf & 0x04) != 0
        let supportsHLG = (eotf & 0x08) != 0

        var maxLum: Double? = nil
        var maxFrameAvgLum: Double? = nil
        var minLum: Double? = nil

        // Byte 2: Desired Content Max Luminance (formula: 50 * 2^(val / 32))
        if payload.count >= 3 && payload[2] > 0 {
            maxLum = 50.0 * pow(2.0, Double(payload[2]) / 32.0)
        }
        // Byte 3: Desired Max Frame-average Luminance
        if payload.count >= 4 && payload[3] > 0 {
            maxFrameAvgLum = 50.0 * pow(2.0, Double(payload[3]) / 32.0)
        }
        // Byte 4: Desired Min Luminance (formula: (MaxLum * (val/255)^2) / 100)
        if payload.count >= 5 && payload[4] > 0, let maxL = maxLum {
            minLum = (maxL * pow(Double(payload[4]) / 255.0, 2.0)) / 100.0
        }

        return HDRStaticMetadataCapability(
            isSupported: supportsSMPTE2084 || supportsHLG,
            supportsTraditionalSDR: supportsSDR,
            supportsTraditionalHDR: supportsTraditionalHDR,
            supportsSMPTE2084: supportsSMPTE2084,
            supportsHLG: supportsHLG,
            desiredMaxLuminance: maxLum,
            desiredMaxFrameAverageLuminance: maxFrameAvgLum,
            desiredMinLuminance: minLum
        )
    }
}
