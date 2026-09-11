//
//  ShaderTypes.swift
//  DolbyMetal
//
//  Swift representation of ShaderTypes.h uniforms for Metal pipelines.
//

import Foundation
import simd

/// 1. Dolby IPT -> RGB 色彩转换常量缓冲区
public struct IPTUniforms {
    public var targetGamut: UInt32
    public var usePQEOTF: UInt32
    public var invGamma: Float
    public var chromaOffset: Float

    public init(
        targetGamut: UInt32 = 0,
        usePQEOTF: UInt32 = 1,
        invGamma: Float = 1.0 / 0.43,
        chromaOffset: Float = 0.5
    ) {
        self.targetGamut = targetGamut
        self.usePQEOTF = usePQEOTF
        self.invGamma = invGamma
        self.chromaOffset = chromaOffset
    }
}

/// 2. LLDV RGB 4:4:4 隧道封装常量缓冲区
public struct LLDVTunnelUniforms {
    public var outputBitDepth: UInt32
    public var frameWidth: UInt32
    public var frameHeight: UInt32
    public var bitReorderMode: UInt32

    public init(
        outputBitDepth: UInt32 = 8,
        frameWidth: UInt32,
        frameHeight: UInt32,
        bitReorderMode: UInt32 = 0
    ) {
        self.outputBitDepth = outputBitDepth
        self.frameWidth = frameWidth
        self.frameHeight = frameHeight
        self.bitReorderMode = bitReorderMode
    }
}

/// 3. EDR / PQ 色调映射常量缓冲区
public struct ToneMappingUniforms {
    public var sourceMinLuminance: Float
    public var sourceMaxLuminance: Float
    public var sourceAvgLuminance: Float

    public var targetMaxLuminance: Float
    public var targetMinLuminance: Float
    public var targetEDRHeadroom: Float

    public var sdrWhiteLuminance: Float
    public var outputMode: UInt32
    public var kneePoint: Float

    public init(
        sourceMinLuminance: Float = 0.005,
        sourceMaxLuminance: Float = 1000.0,
        sourceAvgLuminance: Float = 200.0,
        targetMaxLuminance: Float = 1600.0,
        targetMinLuminance: Float = 0.005,
        targetEDRHeadroom: Float = 1.0,
        sdrWhiteLuminance: Float = 100.0,
        outputMode: UInt32 = 0,
        kneePoint: Float = 0.5
    ) {
        self.sourceMinLuminance = sourceMinLuminance
        self.sourceMaxLuminance = sourceMaxLuminance
        self.sourceAvgLuminance = sourceAvgLuminance
        self.targetMaxLuminance = targetMaxLuminance
        self.targetMinLuminance = targetMinLuminance
        self.targetEDRHeadroom = targetEDRHeadroom
        self.sdrWhiteLuminance = sdrWhiteLuminance
        self.outputMode = outputMode
        self.kneePoint = kneePoint
    }
}
