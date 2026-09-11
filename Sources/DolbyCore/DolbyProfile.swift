//
//  DolbyProfile.swift
//  DolbyCore
//
//  Created for Doul D - macOS Dolby Vision Playback & Display Engine.
//  Swift 6 Strict Concurrency Compliant.
//

import Foundation
import CoreMedia
import CoreVideo

// MARK: - Dolby Vision Profiles

/// 杜比视界 Profile 规格定义
///
/// 涵盖主流流媒体、蓝光光盘及移动设备摄录规格：
/// - Profile 5: 流媒体单层专有 IPT 色彩空间 (IPTPQc2)，无基础层 SDR/HDR 回退
/// - Profile 7: UHD 蓝光原盘双层 (FEL 12-bit / MEL 10-bit)，基础层为 HDR10
/// - Profile 8.1: 单层 HDR10 (Rec.2020 PQ) 兼容，支持回退到标准 HDR10
/// - Profile 8.2: 单层 SDR (Rec.709) 兼容
/// - Profile 8.4: 单层 HLG (Rec.2020 HLG) 兼容，广泛应用于 Apple 硬件 (iPhone/QuickTime)
public enum DolbyProfile: String, Sendable, Equatable, Hashable, CaseIterable, CustomStringConvertible {
    /// Profile 4: 10-bit/12-bit 双层兼容规范
    case profile4 = "Profile 4 (Dual-Layer 10/12-bit)"
    /// Profile 5: 流媒体专有单层，使用 IPT 色彩空间 (IPTPQc2)
    case profile5 = "Profile 5 (IPT-PQ Single Layer)"
    /// Profile 7: UHD 蓝光原盘双层 (BL+EL+RPU, MEL/FEL)
    case profile7 = "Profile 7 (UHD Blu-ray Dual Layer)"
    /// Profile 7 FEL: 蓝光原盘双层 Full Enhancement Layer (12-bit 重构)
    case profile7FEL = "Profile 7 FEL (Full Enhancement Layer 12-bit)"
    /// Profile 7 MEL: 蓝光原盘双层 Minimal Enhancement Layer (10-bit 元数据层)
    case profile7MEL = "Profile 7 MEL (Minimal Enhancement Layer 10-bit)"
    /// Profile 8.1: 单层兼容 HDR10 (Rec.2020 PQ)，无增强层
    case profile81 = "Profile 8.1 (HDR10 Base + Dynamic RPU)"
    /// Profile 8.2: 单层兼容 SDR (Rec.709)
    case profile82 = "Profile 8.2 (SDR Base + Dynamic RPU)"
    /// Profile 8.4: 单层兼容 HLG (Rec.2020 HLG)，Apple 设备原生格式
    case profile84 = "Profile 8.4 (HLG Base + Dolby RPU)"
    /// Profile 9: AVC/H.264 编码的单层 SDR/HDR 格式
    case profile9 = "Profile 9 (AVC/SDR)"

    // MARK: - 静态别名支持

    public static let profile8_1 = DolbyProfile.profile81
    public static let profile8_2 = DolbyProfile.profile82
    public static let profile8_4 = DolbyProfile.profile84

    /// 杜比视界 Profile 编号 (如 5, 7, 8, 9)
    public var profileNumber: UInt8 {
        switch self {
        case .profile4: return 4
        case .profile5: return 5
        case .profile7, .profile7FEL, .profile7MEL: return 7
        case .profile81, .profile82, .profile84: return 8
        case .profile9: return 9
        }
    }

    /// 基础层信号兼容性 ID (`dv_bl_signal_compatibility_id`)
    /// - 0: 不兼容标准 HDR/SDR (如 Profile 5)
    /// - 1: 兼容标准 HDR10 (如 Profile 8.1)
    /// - 2: 兼容标准 SDR (如 Profile 8.2)
    /// - 4: 兼容标准 HLG (如 Profile 8.4)
    /// - 6: 蓝光原盘标准 UHD Blu-ray HDR10 (Profile 7)
    public var blCompatibilityID: UInt8 {
        switch self {
        case .profile5: return 0
        case .profile81: return 1
        case .profile82: return 2
        case .profile84: return 4
        case .profile7, .profile7FEL, .profile7MEL: return 6
        case .profile4, .profile9: return 0
        }
    }

    /// 是否为双层结构 (Base Layer + Enhancement Layer)
    public var isDualLayer: Bool {
        switch self {
        case .profile4, .profile7, .profile7FEL, .profile7MEL:
            return true
        case .profile5, .profile81, .profile82, .profile84, .profile9:
            return false
        }
    }

    /// 对应的主要色彩空间
    public var colorSpace: DolbyColorSpace {
        switch self {
        case .profile5:
            return .ipt
        case .profile7, .profile7FEL, .profile7MEL, .profile81:
            return .rec2020PQ
        case .profile84:
            return .rec2020HLG
        case .profile82, .profile9:
            return .rec709
        case .profile4:
            return .rec2020PQ
        }
    }

    /// 对应的 ISOBMFF 优选 FourCC 原子标号
    public var preferredFourCC: String {
        switch self {
        case .profile5, .profile7, .profile7FEL, .profile7MEL:
            return "dvcC"
        case .profile81:
            return "dv81"
        case .profile82, .profile84, .profile9:
            return "dvvC"
        case .profile4:
            return "dvcC"
        }
    }

    public var description: String {
        return rawValue
    }
}

/// 类型别名兼容
public typealias DolbyVisionProfile = DolbyProfile

// MARK: - Color Space Definitions

/// 杜比视界支持的色彩空间及曲线定义
public enum DolbyColorSpace: Sendable, Hashable, CustomStringConvertible {
    /// 杜比专有 IPT 色彩空间 (IPTPQc2, 基于 ICtCp 的感知量化空间)
    case ipt
    /// ITU-R BT.2020 色域 + SMPTE ST 2084 感知量化 (PQ) 传递函数 (标准 HDR10)
    case rec2020PQ
    /// ITU-R BT.2020 色域 + ARIB STD-B67 混合对数伽马 (HLG) 传递函数
    case rec2020HLG
    /// ITU-R BT.709 色域 + BT.709 传递函数 (SDR)
    case rec709

    /// CoreVideo 色彩原色常量
    public var cvColorPrimaries: CFString {
        switch self {
        case .ipt, .rec2020PQ, .rec2020HLG:
            return kCVImageBufferColorPrimaries_ITU_R_2020
        case .rec709:
            return kCVImageBufferColorPrimaries_ITU_R_709_2
        }
    }

    /// CoreVideo 传递函数常量
    public var cvTransferFunction: CFString {
        switch self {
        case .ipt, .rec2020PQ:
            return kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ
        case .rec2020HLG:
            return kCVImageBufferTransferFunction_ITU_R_2100_HLG
        case .rec709:
            return kCVImageBufferTransferFunction_ITU_R_709_2
        }
    }

    /// CoreVideo YCbCr 转换矩阵常量
    public var cvMatrix: CFString {
        switch self {
        case .ipt:
            return kCVImageBufferYCbCrMatrix_ITU_R_2020
        case .rec2020PQ, .rec2020HLG:
            return kCVImageBufferYCbCrMatrix_ITU_R_2020
        case .rec709:
            return kCVImageBufferYCbCrMatrix_ITU_R_709_2
        }
    }

    public var description: String {
        switch self {
        case .ipt:
            return "Dolby IPT (IPTPQc2, ST 2084 PQ)"
        case .rec2020PQ:
            return "Rec.2020 / ST 2084 PQ (HDR10)"
        case .rec2020HLG:
            return "Rec.2020 / ARIB STD-B67 (HLG)"
        case .rec709:
            return "Rec.709 / BT.709 (SDR)"
        }
    }
}

// MARK: - HEVC NALU Types

/// HEVC NALU 单元类型定义 (ITU-T H.265 / ISO/IEC 23008-2)
/// 重点包含杜比视界 RPU (UNSPEC62) 和 EL 单元 (UNSPEC63)
public struct HEVCNALUType: RawRepresentable, Sendable, Hashable, CustomStringConvertible {
    public let rawValue: UInt8

    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    // VCL NAL Units (0 - 31)
    public static let trailN        = HEVCNALUType(rawValue: 0)
    public static let trailR        = HEVCNALUType(rawValue: 1)
    public static let tsaN          = HEVCNALUType(rawValue: 2)
    public static let tsaR          = HEVCNALUType(rawValue: 3)
    public static let stsaN         = HEVCNALUType(rawValue: 4)
    public static let stsaR         = HEVCNALUType(rawValue: 5)
    public static let radlN         = HEVCNALUType(rawValue: 6)
    public static let radlR         = HEVCNALUType(rawValue: 7)
    public static let raslN         = HEVCNALUType(rawValue: 8)
    public static let raslR         = HEVCNALUType(rawValue: 9)
    public static let idrWRADL      = HEVCNALUType(rawValue: 19)
    public static let idrNLPR       = HEVCNALUType(rawValue: 20)
    public static let craNut        = HEVCNALUType(rawValue: 21)

    // Non-VCL NAL Units (32 - 63)
    public static let vpsNut        = HEVCNALUType(rawValue: 32)
    public static let spsNut        = HEVCNALUType(rawValue: 33)
    public static let ppsNut        = HEVCNALUType(rawValue: 34)
    public static let audNut        = HEVCNALUType(rawValue: 35)
    public static let eosNut        = HEVCNALUType(rawValue: 36)
    public static let eobNut        = HEVCNALUType(rawValue: 37)
    public static let fdNut         = HEVCNALUType(rawValue: 38)
    public static let prefixSeiNut  = HEVCNALUType(rawValue: 39)
    public static let suffixSeiNut  = HEVCNALUType(rawValue: 40)

    /// 杜比视界专有 RPU (Reference Processing Unit) 单元：NALU 62 (UNSPEC62)
    public static let unspec62      = HEVCNALUType(rawValue: 62)
    /// 杜比视界专有 EL (Enhancement Layer) / 扩展单元：NALU 63 (UNSPEC63)
    public static let unspec63      = HEVCNALUType(rawValue: 63)

    /// 是否为杜比视界 RPU 元数据单元 (NALU 62)
    public var isDolbyVisionRPU: Bool {
        return rawValue == 62
    }

    /// 是否为杜比视界 EL 或增强数据单元 (NALU 63)
    public var isDolbyVisionEL: Bool {
        return rawValue == 63
    }

    /// 是否属于图像切片层 (VCL)
    public var isVCL: Bool {
        return rawValue <= 31
    }

    /// 是否为关键帧 / 帧内刷新 (IDR / CRA / BLA)
    public var isKeyframe: Bool {
        return rawValue >= 16 && rawValue <= 23
    }

    /// 是否为参数集 (VPS / SPS / PPS)
    public var isParameterSet: Bool {
        return rawValue == 32 || rawValue == 33 || rawValue == 34
    }

    public var description: String {
        switch self.rawValue {
        case 0: return "TRAIL_N (0)"
        case 1: return "TRAIL_R (1)"
        case 19: return "IDR_W_RADL (19)"
        case 20: return "IDR_N_LP (20)"
        case 21: return "CRA_NUT (21)"
        case 32: return "VPS_NUT (32)"
        case 33: return "SPS_NUT (33)"
        case 34: return "PPS_NUT (34)"
        case 35: return "AUD_NUT (35)"
        case 39: return "PREFIX_SEI_NUT (39)"
        case 40: return "SUFFIX_SEI_NUT (40)"
        case 62: return "DOLBY_VISION_RPU (UNSPEC62)"
        case 63: return "DOLBY_VISION_EL (UNSPEC63)"
        default: return "NALU_\(rawValue)"
        }
    }
}

// MARK: - RPU Header & Metadata Structures

/// 杜比视界 RPU 头部数据结构 (`rpu_data_header`)
public struct RpuDataHeader: Sendable, Hashable {
    /// RPU 类型 (一般为 2)
    public var rpuType: UInt8
    /// RPU 格式标识 (11-bit)
    public var rpuFormat: UInt16
    /// VDR RPU Profile (Profile 7 为 0 或 1，Profile 8 为 1)
    public var vdrRpuProfile: UInt8
    /// VDR RPU Level
    public var vdrRpuLevel: UInt8
    /// 序列信息是否存在标志
    public var vdrSeqInfoPresent: Bool
    /// 色度重采样显式滤波标志
    public var chromaResamplingExplicitFilterFlag: Bool
    /// 系数数据类型
    public var coefDataType: UInt8
    /// 系数 log2 分母
    public var coefLog2Denom: UInt8
    /// 归一化指示符 (2-bit)
    public var vdrRpuNormalizedIdc: UInt8
    /// 基础层视频是否为 Full Range (0..255)
    public var blVideoFullRangeFlag: Bool
    /// 基础层色深 (8 + blBitDepthMinus8, 通常为 10-bit)
    public var blBitDepth: UInt8
    /// 增强层色深 (通常为 10 或 12-bit)
    public var elBitDepth: UInt8
    /// VDR 重建色深 (通常为 12 或 14-bit)
    public var vdrBitDepth: UInt8
    /// 空间重采样滤波标志
    public var spatialResamplingFilterFlag: Bool
    /// 增强层空间重采样滤波标志 (Profile 7 FEL 中置 1，重写为 Profile 8 时必须清除为 0)
    public var elSpatialResamplingFilterFlag: Bool
    /// 残差禁用标志 (Profile 8 单层中置 1，不使用 EL 残差)
    public var disableResidualFlag: Bool

    public init(
        rpuType: UInt8 = 2,
        rpuFormat: UInt16 = 0x07FE,
        vdrRpuProfile: UInt8 = 1,
        vdrRpuLevel: UInt8 = 0,
        vdrSeqInfoPresent: Bool = true,
        chromaResamplingExplicitFilterFlag: Bool = false,
        coefDataType: UInt8 = 0,
        coefLog2Denom: UInt8 = 23,
        vdrRpuNormalizedIdc: UInt8 = 1,
        blVideoFullRangeFlag: Bool = false,
        blBitDepth: UInt8 = 10,
        elBitDepth: UInt8 = 10,
        vdrBitDepth: UInt8 = 12,
        spatialResamplingFilterFlag: Bool = false,
        elSpatialResamplingFilterFlag: Bool = false,
        disableResidualFlag: Bool = true
    ) {
        self.rpuType = rpuType
        self.rpuFormat = rpuFormat
        self.vdrRpuProfile = vdrRpuProfile
        self.vdrRpuLevel = vdrRpuLevel
        self.vdrSeqInfoPresent = vdrSeqInfoPresent
        self.chromaResamplingExplicitFilterFlag = chromaResamplingExplicitFilterFlag
        self.coefDataType = coefDataType
        self.coefLog2Denom = coefLog2Denom
        self.vdrRpuNormalizedIdc = vdrRpuNormalizedIdc
        self.blVideoFullRangeFlag = blVideoFullRangeFlag
        self.blBitDepth = blBitDepth
        self.elBitDepth = elBitDepth
        self.vdrBitDepth = vdrBitDepth
        self.spatialResamplingFilterFlag = spatialResamplingFilterFlag
        self.elSpatialResamplingFilterFlag = elSpatialResamplingFilterFlag
        self.disableResidualFlag = disableResidualFlag
    }
}

/// 杜比视界 Level 1 动态元数据 (画面亮度范围)
public struct DolbyLevel1Metadata: Sendable, Hashable {
    /// 最小感知亮度 (12-bit PQ 码值，0..4095)
    public var minPQ: UInt16
    /// 最大感知亮度 (12-bit PQ 码值，0..4095)
    public var maxPQ: UInt16
    /// 平均感知亮度 (12-bit PQ 码值，0..4095)
    public var avgPQ: UInt16

    public init(minPQ: UInt16, maxPQ: UInt16, avgPQ: UInt16) {
        self.minPQ = minPQ
        self.maxPQ = maxPQ
        self.avgPQ = avgPQ
    }

    /// 将 12-bit PQ 码值转换为近似物理亮度 (nits / cd/m²)
    public static func pqToNits(_ pq: UInt16) -> Double {
        let normalized = Double(pq) / 4095.0
        let m1: Double = 2610.0 / 16384.0
        let m2: Double = (2523.0 / 4096.0) * 128.0
        let c1: Double = 3424.0 / 4096.0
        let c2: Double = (2413.0 / 4096.0) * 32.0
        let c3: Double = (2392.0 / 4096.0) * 32.0

        let num = max(pow(normalized, 1.0 / m2) - c1, 0.0)
        let den = c2 - c3 * pow(normalized, 1.0 / m2)
        guard den > 0 else { return 0.0 }
        return 10000.0 * pow(num / den, 1.0 / m1)
    }

    /// 最大物理亮度估计 (nits)
    public var maxLuminanceNits: Double {
        Self.pqToNits(maxPQ)
    }

    /// 最小物理亮度估计 (nits)
    public var minLuminanceNits: Double {
        Self.pqToNits(minPQ)
    }

    /// 平均物理亮度估计 (nits)
    public var avgLuminanceNits: Double {
        Self.pqToNits(avgPQ)
    }
}

/// 杜比视界 Level 2 目标显示微调元数据 (Trim Pass)
public struct DolbyLevel2Metadata: Sendable, Hashable {
    public var targetMaxPQ: UInt16
    public var trimSlope: UInt16
    public var trimOffset: UInt16
    public var trimPower: UInt16
    public var trimChromaWeight: UInt16
    public var trimSaturationGain: UInt16
    public var msWeight: Int16

    public init(
        targetMaxPQ: UInt16 = 2081, // 约 100 nits (SDR 目标)
        trimSlope: UInt16 = 2048,
        trimOffset: UInt16 = 2048,
        trimPower: UInt16 = 2048,
        trimChromaWeight: UInt16 = 2048,
        trimSaturationGain: UInt16 = 2048,
        msWeight: Int16 = 0
    ) {
        self.targetMaxPQ = targetMaxPQ
        self.trimSlope = trimSlope
        self.trimOffset = trimOffset
        self.trimPower = trimPower
        self.trimChromaWeight = trimChromaWeight
        self.trimSaturationGain = trimSaturationGain
        self.msWeight = msWeight
    }
}

/// 杜比视界 Level 3 元数据 (Level 1 偏移校正)
public struct DolbyLevel3Metadata: Sendable, Hashable {
    public var minPQOffset: UInt16
    public var maxPQOffset: UInt16
    public var avgPQOffset: UInt16

    public init(minPQOffset: UInt16 = 0, maxPQOffset: UInt16 = 0, avgPQOffset: UInt16 = 0) {
        self.minPQOffset = minPQOffset
        self.maxPQOffset = maxPQOffset
        self.avgPQOffset = avgPQOffset
    }
}

/// 杜比视界 Level 4 元数据 (锚定元数据)
public struct DolbyLevel4Metadata: Sendable, Hashable {
    public var anchorPQ: UInt16
    public var anchorPower: UInt16

    public init(anchorPQ: UInt16 = 0, anchorPower: UInt16 = 0) {
        self.anchorPQ = anchorPQ
        self.anchorPower = anchorPower
    }
}

/// 杜比视界 Level 5 元数据 (有效画幅与黑边切除)
public struct DolbyLevel5Metadata: Sendable, Hashable {
    public var activeAreaLeftOffset: UInt16
    public var activeAreaRightOffset: UInt16
    public var activeAreaTopOffset: UInt16
    public var activeAreaBottomOffset: UInt16

    public init(
        activeAreaLeftOffset: UInt16 = 0,
        activeAreaRightOffset: UInt16 = 0,
        activeAreaTopOffset: UInt16 = 0,
        activeAreaBottomOffset: UInt16 = 0
    ) {
        self.activeAreaLeftOffset = activeAreaLeftOffset
        self.activeAreaRightOffset = activeAreaRightOffset
        self.activeAreaTopOffset = activeAreaTopOffset
        self.activeAreaBottomOffset = activeAreaBottomOffset
    }
}

/// 杜比视界 Level 6 静态 HDR10 元数据 (母带显示器与内容峰值)
public struct DolbyLevel6Metadata: Sendable, Hashable {
    /// 母带监视器最大亮度 (nits, 例如 1000 或 4000)
    public var maxDisplayMasteringLuminance: UInt16
    /// 母带监视器最小亮度 (0.0001 nits, 例如 50 代表 0.0050 nits)
    public var minDisplayMasteringLuminance: UInt16
    /// 最大内容光照等级 (MaxCLL, nits)
    public var maxCLL: UInt16
    /// 最大单帧平均光照等级 (MaxFALL, nits)
    public var maxFALL: UInt16

    public init(
        maxDisplayMasteringLuminance: UInt16 = 1000,
        minDisplayMasteringLuminance: UInt16 = 50,
        maxCLL: UInt16 = 1000,
        maxFALL: UInt16 = 400
    ) {
        self.maxDisplayMasteringLuminance = maxDisplayMasteringLuminance
        self.minDisplayMasteringLuminance = minDisplayMasteringLuminance
        self.maxCLL = maxCLL
        self.maxFALL = maxFALL
    }
}

/// 聚合杜比视界元数据模型
public struct DolbyVisionMetadata: Sendable, Hashable {
    public var header: RpuDataHeader
    public var level1: DolbyLevel1Metadata?
    public var level2: [DolbyLevel2Metadata]
    public var level3: DolbyLevel3Metadata?
    public var level4: DolbyLevel4Metadata?
    public var level5: DolbyLevel5Metadata?
    public var level6: DolbyLevel6Metadata?

    public init(
        header: RpuDataHeader = RpuDataHeader(),
        level1: DolbyLevel1Metadata? = nil,
        level2: [DolbyLevel2Metadata] = [],
        level3: DolbyLevel3Metadata? = nil,
        level4: DolbyLevel4Metadata? = nil,
        level5: DolbyLevel5Metadata? = nil,
        level6: DolbyLevel6Metadata? = nil
    ) {
        self.header = header
        self.level1 = level1
        self.level2 = level2
        self.level3 = level3
        self.level4 = level4
        self.level5 = level5
        self.level6 = level6
    }
}
