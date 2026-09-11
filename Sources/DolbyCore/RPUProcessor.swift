//
//  RPUProcessor.swift
//  DolbyCore
//
//  Created for Doul D - macOS Dolby Vision Playback & Display Engine.
//  Swift 6 Strict Concurrency Compliant.
//

import Foundation

// MARK: - BitReader & BitWriter

/// 高性能比特位读取器，支持变长位宽读取与无符号/有符号指数哥伦布编码 (ue/se)
public final class BitReader: @unchecked Sendable {
    private let data: [UInt8]
    private var byteOffset: Int = 0
    private var bitOffset: Int = 0 // 0..7 从最高有效位 (MSB) 开始

    public init(data: Data) {
        self.data = Array(data)
    }

    public init(bytes: [UInt8]) {
        self.data = bytes
    }

    /// 当前读取的绝对比特位置
    public var bitPosition: Int {
        return byteOffset * 8 + bitOffset
    }

    /// 剩余未读取比特数
    public var bitsRemaining: Int {
        let totalBits = data.count * 8
        let consumedBits = byteOffset * 8 + bitOffset
        return max(0, totalBits - consumedBits)
    }

    /// 跳过指定位数的比特
    public func skipBits(_ count: Int) {
        guard count > 0 else { return }
        let total = byteOffset * 8 + bitOffset + count
        byteOffset = min(total / 8, data.count)
        bitOffset = (byteOffset >= data.count) ? 0 : (total % 8)
    }

    /// 读取 1 个比特
    public func readBit() -> Bool {
        guard byteOffset < data.count else { return false }
        let currentByte = data[byteOffset]
        let bit = (currentByte >> (7 - bitOffset)) & 0x01
        bitOffset += 1
        if bitOffset == 8 {
            bitOffset = 0
            byteOffset += 1
        }
        return bit == 1
    }

    /// 读取指定位数 (1..32) 的比特并转换为无符号整数
    public func readBits(_ count: Int) -> UInt32 {
        guard count > 0 else { return 0 }
        var result: UInt32 = 0
        for _ in 0..<count {
            result = (result << 1) | (readBit() ? 1 : 0)
        }
        return result
    }

    /// 读取指定位数 (1..64) 的比特并转换为 64 位无符号整数
    public func readBits64(_ count: Int) -> UInt64 {
        guard count > 0 else { return 0 }
        var result: UInt64 = 0
        for _ in 0..<count {
            result = (result << 1) | (readBit() ? 1 : 0)
        }
        return result
    }

    /// 读取无符号指数哥伦布编码 ue(v)
    public func readUE() -> UInt32 {
        var leadingZeros = 0
        while !readBit() && bitsRemaining > 0 {
            leadingZeros += 1
        }
        if leadingZeros == 0 {
            return 0
        }
        let info = readBits(leadingZeros)
        return (1 << leadingZeros) - 1 + info
    }

    /// 读取有符号指数哥伦布编码 se(v)
    public func readSE() -> Int32 {
        let codeNum = readUE()
        if codeNum % 2 == 0 {
            return -Int32(codeNum / 2)
        } else {
            return Int32((codeNum + 1) / 2)
        }
    }

    /// 对齐到下一个字节边界
    public func alignToByte() {
        if bitOffset != 0 {
            bitOffset = 0
            byteOffset += 1
        }
    }

    /// 当前读取的字节位置
    public var currentBytePosition: Int {
        return byteOffset
    }
}

/// 高性能比特位写入器，支持任意位宽拼装与指数哥伦布编码
public final class BitWriter: @unchecked Sendable {
    private var buffer: [UInt8] = []
    private var currentByte: UInt8 = 0
    private var bitOffset: Int = 0 // 0..7

    public init(capacity: Int = 128) {
        buffer.reserveCapacity(capacity)
    }

    /// 写入单个比特
    public func writeBit(_ bit: Bool) {
        if bit {
            currentByte |= (1 << (7 - bitOffset))
        }
        bitOffset += 1
        if bitOffset == 8 {
            buffer.append(currentByte)
            currentByte = 0
            bitOffset = 0
        }
    }

    /// 写入指定位数的整数 (最高 32 位)
    public func writeBits(_ value: UInt32, count: Int) {
        guard count > 0 else { return }
        for i in (0..<count).reversed() {
            let bit = ((value >> i) & 1) == 1
            writeBit(bit)
        }
    }

    /// 写入无符号指数哥伦布码 ue(v)
    public func writeUE(_ value: UInt32) {
        let valPlus1 = value + 1
        let bitLength = 32 - valPlus1.leadingZeroBitCount
        let leadingZeros = bitLength - 1
        for _ in 0..<leadingZeros {
            writeBit(false)
        }
        writeBits(valPlus1, count: bitLength)
    }

    /// 写入有符号指数哥伦布码 se(v)
    public func writeSE(_ value: Int32) {
        if value <= 0 {
            writeUE(UInt32(-value * 2))
        } else {
            writeUE(UInt32(value * 2 - 1))
        }
    }

    /// 对齐到字节末尾 (填 0 或填 1)
    public func alignToByte(fillBit: Bool = false) {
        while bitOffset != 0 {
            writeBit(fillBit)
        }
    }

    /// 获取最终序列化好的 Data
    public func toData() -> Data {
        var finalBuffer = buffer
        if bitOffset != 0 {
            finalBuffer.append(currentByte)
        }
        return Data(finalBuffer)
    }
}

// MARK: - RPUProcessor

/// 杜比视界 RPU 核心解析、重写与元数据重构处理器
/// 核心功能：
/// 1. 解析 Profile 7/8/5 RPU NALU 单元及其 Level 1-6 元数据
/// 2. 实现 Profile 7 (蓝光原盘双层 FEL/MEL) 实时重写为 Profile 8.1 算法 (清除 EL 空间重采样与增强层残差)
/// 3. 生成 24 字节的标准 Dolby Vision Configuration Box (`dvcC` / `dv81` 原子数据)
public final class RPUProcessor: Sendable {

    public init() {}

    // MARK: - 1. 解析 RPU NALU 动态元数据

    /// 从 RPU NALU (NALU 62) 数据中解析完整的杜比视界元数据
    /// - Parameter rpuNALUData: 可以是包含 2 字节头部的原始 NALU 或纯 RBSP 载荷
    /// - Returns: 解析成功的 DolbyVisionMetadata 模型，解析失败返回 nil
    public func parse(rpuData: Data) -> DolbyVisionMetadata? {
        guard !rpuData.isEmpty else { return nil }

        // 1. 如果包含 NALU 62 头部 (0x7C 或 0x7E)，跳过 2 字节头部；若输入包含起始码也作对应规整
        var effectiveData = rpuData
        if effectiveData.count >= 4 && effectiveData[0] == 0 && effectiveData[1] == 0 {
            if let firstNAL = NALUParser.parse(annexBData: effectiveData).first(where: { $0.isDolbyVisionRPU }) {
                effectiveData = firstNAL.rbspData
            }
        } else if effectiveData.count >= 2 && ((effectiveData[0] >> 1) & 0x3F) == 62 {
            effectiveData = NALUParser.unescapeEBSP(effectiveData.subdata(in: 2..<effectiveData.count))
        } else {
            effectiveData = NALUParser.unescapeEBSP(effectiveData)
        }

        guard effectiveData.count >= 4 else { return nil }

        let reader = BitReader(data: effectiveData)

        // 2. 解析 rpu_data_header
        let rpuType = UInt8(reader.readBits(6))
        guard rpuType == 2 else {
            return nil
        }

        let rpuFormat = UInt16(reader.readBits(11))
        let vdrRpuProfile = UInt8(reader.readBits(4))
        let vdrRpuLevel = UInt8(reader.readBits(4))
        let vdrSeqInfoPresent = reader.readBit()

        var header = RpuDataHeader(
            rpuType: rpuType,
            rpuFormat: rpuFormat,
            vdrRpuProfile: vdrRpuProfile,
            vdrRpuLevel: vdrRpuLevel,
            vdrSeqInfoPresent: vdrSeqInfoPresent
        )

        if vdrSeqInfoPresent {
            header.chromaResamplingExplicitFilterFlag = reader.readBit()
            header.coefDataType = UInt8(reader.readBits(2))
            header.coefLog2Denom = UInt8(reader.readBits(2))
            header.vdrRpuNormalizedIdc = UInt8(reader.readBits(2))
            header.blVideoFullRangeFlag = reader.readBit()
            header.blBitDepth = UInt8(8 + reader.readUE())
            header.elBitDepth = UInt8(8 + reader.readUE())
            header.vdrBitDepth = UInt8(8 + reader.readUE())
            header.spatialResamplingFilterFlag = reader.readBit()
            _ = reader.readBits(3) // reserved_zero_3bits
            header.elSpatialResamplingFilterFlag = reader.readBit()
            header.disableResidualFlag = reader.readBit()
        }

        let vdrDMMetadataPresent = reader.readBit()
        let usePrevVdrRpu = reader.readBit()

        var level1: DolbyLevel1Metadata?
        var level2List: [DolbyLevel2Metadata] = []
        var level3: DolbyLevel3Metadata?
        var level4: DolbyLevel4Metadata?
        var level5: DolbyLevel5Metadata?
        var level6: DolbyLevel6Metadata?

        // 3. 解析动态显示管理元数据 (vdr_dm_data_payload)
        if vdrDMMetadataPresent && !usePrevVdrRpu && reader.bitsRemaining >= 16 {
            while reader.bitsRemaining >= 24 {
                let extBlockLevel = UInt8(reader.readBits(8))
                let extBlockLength = Int(reader.readBits(16))

                if extBlockLevel == 255 {
                    break
                }

                guard reader.bitsRemaining >= extBlockLength * 8 else { break }
                let blockStartBit = reader.bitPosition

                switch extBlockLevel {
                case 1:
                    // Level 1: 画面动态亮度 (min_PQ, max_PQ, avg_PQ)
                    if extBlockLength >= 5 && reader.bitsRemaining >= 36 {
                        let minPQ = UInt16(reader.readBits(12))
                        let maxPQ = UInt16(reader.readBits(12))
                        let avgPQ = UInt16(reader.readBits(12))
                        level1 = DolbyLevel1Metadata(minPQ: minPQ, maxPQ: maxPQ, avgPQ: avgPQ)
                    }
                case 2:
                    // Level 2: 目标微调元数据
                    if extBlockLength >= 11 && reader.bitsRemaining >= 86 {
                        let targetMaxPQ = UInt16(reader.readBits(12))
                        let trimSlope = UInt16(reader.readBits(12))
                        let trimOffset = UInt16(reader.readBits(12))
                        let trimPower = UInt16(reader.readBits(12))
                        let trimChromaWeight = UInt16(reader.readBits(12))
                        let trimSaturationGain = UInt16(reader.readBits(12))
                        let msWeight = Int16(reader.readBits(14))
                        level2List.append(DolbyLevel2Metadata(
                            targetMaxPQ: targetMaxPQ,
                            trimSlope: trimSlope,
                            trimOffset: trimOffset,
                            trimPower: trimPower,
                            trimChromaWeight: trimChromaWeight,
                            trimSaturationGain: trimSaturationGain,
                            msWeight: msWeight
                        ))
                    }
                case 3:
                    // Level 3: Level 1 偏移校正
                    if extBlockLength >= 5 && reader.bitsRemaining >= 36 {
                        let minPQOff = UInt16(reader.readBits(12))
                        let maxPQOff = UInt16(reader.readBits(12))
                        let avgPQOff = UInt16(reader.readBits(12))
                        level3 = DolbyLevel3Metadata(minPQOffset: minPQOff, maxPQOffset: maxPQOff, avgPQOffset: avgPQOff)
                    }
                case 4:
                    // Level 4: 锚定元数据
                    if extBlockLength >= 3 && reader.bitsRemaining >= 24 {
                        let anchorPQ = UInt16(reader.readBits(12))
                        let anchorPower = UInt16(reader.readBits(12))
                        level4 = DolbyLevel4Metadata(anchorPQ: anchorPQ, anchorPower: anchorPower)
                    }
                case 5:
                    // Level 5: 裁剪与有效画面
                    if extBlockLength >= 7 && reader.bitsRemaining >= 52 {
                        let left = UInt16(reader.readBits(13))
                        let right = UInt16(reader.readBits(13))
                        let top = UInt16(reader.readBits(13))
                        let bottom = UInt16(reader.readBits(13))
                        level5 = DolbyLevel5Metadata(activeAreaLeftOffset: left, activeAreaRightOffset: right, activeAreaTopOffset: top, activeAreaBottomOffset: bottom)
                    }
                case 6:
                    // Level 6: 静态 HDR10 元数据 (MaxCLL, MaxFALL, 监视器最大/最小亮度)
                    if extBlockLength >= 8 && reader.bitsRemaining >= 64 {
                        let maxLum = UInt16(reader.readBits(16))
                        let minLum = UInt16(reader.readBits(16))
                        let maxCLL = UInt16(reader.readBits(16))
                        let maxFALL = UInt16(reader.readBits(16))
                        level6 = DolbyLevel6Metadata(
                            maxDisplayMasteringLuminance: maxLum,
                            minDisplayMasteringLuminance: minLum,
                            maxCLL: maxCLL,
                            maxFALL: maxFALL
                        )
                    }
                default:
                    break
                }

                // 精准跳过本扩展块剩余的未读字节 (保证块与块之间严格字节对齐)
                let consumedInBlock = reader.bitPosition - blockStartBit
                let remainingInBlock = (extBlockLength * 8) - consumedInBlock
                if remainingInBlock > 0 {
                    reader.skipBits(remainingInBlock)
                }
            }
        }

        return DolbyVisionMetadata(
            header: header,
            level1: level1,
            level2: level2List,
            level3: level3,
            level4: level4,
            level5: level5,
            level6: level6
        )
    }

    // MARK: - 2. 核心重构算法：Profile 7 实时重写为 Profile 8.1

    /// 将蓝光原盘双层 (FEL/MEL) Profile 7 的 RPU 实时重构为合法的 Profile 8.1 规范
    ///
    /// 核心逻辑与偏色消除机理：
    /// 1. UHD 蓝光原盘 Profile 7 包含双层增强结构，其 RPU 头部指示了 EL 空间重采样与残差信号。
    /// 2. 当 macOS / tvOS 或非双层播放器直接渲染 Profile 7 时，因缺乏硬件双层解码或误读了重采样指示，
    ///    会导致严重的红绿反转或发紫发绿现象。
    /// 3. 本算法实时修改 `vdr_rpu_profile` 为 1 (Profile 8 规范)，将 `el_spatial_resampling_filter_flag` 强制置为 0，
    ///    并将 `disable_residual_flag` 设为 1，确保基础层 (Rec.2020 PQ 10-bit) 能被显示子系统正确感知并执行精准的单层动态色调映射。
    ///
    /// - Parameter sourceRPUData: 原始 Profile 7 RPU 数据 (可为 NALU 单元、含起始码流或纯载荷)
    /// - Returns: 重构后的合法 Profile 8.1 NALU 62 数据 (附带 4 字节起始码 00 00 00 01)
    public func convertProfile7To8_1(sourceRPUData: Data) -> Data? {
        guard var metadata = parse(rpuData: sourceRPUData) else {
            return nil
        }

        // 修改 Profile 标记为 1 (Dolby Vision Profile 8.1 在 RPU 头部中的标准指示)
        metadata.header.vdrRpuProfile = 1

        // 清除 EL 空间重采样滤波标志 (Profile 7 FEL 专用，Profile 8.1 不存在 EL，必须置 0)
        metadata.header.elSpatialResamplingFilterFlag = false

        // 禁用增强层残差计算，强制纯基础层动态色调映射
        metadata.header.disableResidualFlag = true

        // 如果未解析到 Level 1，则注入安全的默认动态范围 (0.005 nits ~ 1000 nits)
        if metadata.level1 == nil {
            metadata.level1 = DolbyLevel1Metadata(minPQ: 7, maxPQ: 3079, avgPQ: 2081)
        }

        // 如果未解析到 Level 6，则注入标准的 1000 nits HDR10 静态元数据
        if metadata.level6 == nil {
            metadata.level6 = DolbyLevel6Metadata(
                maxDisplayMasteringLuminance: 1000,
                minDisplayMasteringLuminance: 50,
                maxCLL: 1000,
                maxFALL: 400
            )
        }

        // 重新序列化为符合 Profile 8.1 规范的 RBSP 比特流
        let newRBSP = serializeRBSP(metadata: metadata)

        // 封装防竞争字节并添加 NALU 62 头部及 Annex B 起始码
        return NALUParser.packageRPUNALU(rbsp: newRBSP)
    }

    /// 将 DolbyVisionMetadata 模型序列化为合法的 RPU RBSP 载荷
    public func serializeRBSP(metadata: DolbyVisionMetadata) -> Data {
        let writer = BitWriter(capacity: 256)

        // 1. 序列化 rpu_data_header
        writer.writeBits(UInt32(metadata.header.rpuType), count: 6)     // rpu_type = 2
        writer.writeBits(UInt32(metadata.header.rpuFormat), count: 11)  // rpu_format
        writer.writeBits(UInt32(metadata.header.vdrRpuProfile), count: 4) // 1 (Profile 8)
        writer.writeBits(UInt32(metadata.header.vdrRpuLevel), count: 4)   // level = 0
        writer.writeBit(metadata.header.vdrSeqInfoPresent)             // vdr_seq_info_present_flag

        if metadata.header.vdrSeqInfoPresent {
            writer.writeBit(metadata.header.chromaResamplingExplicitFilterFlag)
            writer.writeBits(UInt32(metadata.header.coefDataType), count: 2)
            writer.writeBits(UInt32(metadata.header.coefLog2Denom), count: 2)
            writer.writeBits(UInt32(metadata.header.vdrRpuNormalizedIdc), count: 2)
            writer.writeBit(metadata.header.blVideoFullRangeFlag)
            writer.writeUE(UInt32(max(0, Int(metadata.header.blBitDepth) - 8)))
            writer.writeUE(UInt32(max(0, Int(metadata.header.elBitDepth) - 8)))
            writer.writeUE(UInt32(max(0, Int(metadata.header.vdrBitDepth) - 8)))
            writer.writeBit(metadata.header.spatialResamplingFilterFlag)
            writer.writeBits(0, count: 3) // reserved_zero_3bits
            writer.writeBit(metadata.header.elSpatialResamplingFilterFlag) // 强制 0
            writer.writeBit(metadata.header.disableResidualFlag)           // 强制 1
        }

        // vdr_dm_metadata_present_flag = 1
        writer.writeBit(true)
        // use_prev_vdr_rpu_flag = 0
        writer.writeBit(false)

        // 2. 序列化 Level 1 动态元数据 (画面最大/最小/平均亮度)
        if let l1 = metadata.level1 {
            writer.writeBits(1, count: 8)  // ext_block_level = 1
            writer.writeBits(5, count: 16) // ext_block_length = 5 字节 (36 bits + padding)
            writer.writeBits(UInt32(l1.minPQ), count: 12)
            writer.writeBits(UInt32(l1.maxPQ), count: 12)
            writer.writeBits(UInt32(l1.avgPQ), count: 12)
            writer.writeBits(0, count: 4) // 补齐 5 字节
        }

        // 3. 序列化 Level 2 目标色调映射微调块
        for l2 in metadata.level2 {
            writer.writeBits(2, count: 8)   // ext_block_level = 2
            writer.writeBits(11, count: 16) // ext_block_length = 11 字节
            writer.writeBits(UInt32(l2.targetMaxPQ), count: 12)
            writer.writeBits(UInt32(l2.trimSlope), count: 12)
            writer.writeBits(UInt32(l2.trimOffset), count: 12)
            writer.writeBits(UInt32(l2.trimPower), count: 12)
            writer.writeBits(UInt32(l2.trimChromaWeight), count: 12)
            writer.writeBits(UInt32(l2.trimSaturationGain), count: 12)
            writer.writeBits(UInt32(UInt16(bitPattern: l2.msWeight)), count: 14)
            writer.writeBits(0, count: 2) // 补齐 11 字节
        }

        // 4. 序列化 Level 5 有效画幅元数据
        if let l5 = metadata.level5 {
            writer.writeBits(5, count: 8)  // ext_block_level = 5
            writer.writeBits(7, count: 16) // ext_block_length = 7 字节
            writer.writeBits(UInt32(l5.activeAreaLeftOffset), count: 13)
            writer.writeBits(UInt32(l5.activeAreaRightOffset), count: 13)
            writer.writeBits(UInt32(l5.activeAreaTopOffset), count: 13)
            writer.writeBits(UInt32(l5.activeAreaBottomOffset), count: 13)
            writer.writeBits(0, count: 4) // 补齐 7 字节
        }

        // 5. 序列化 Level 6 静态 HDR10 元数据 (MaxCLL / MaxFALL)
        if let l6 = metadata.level6 {
            writer.writeBits(6, count: 8)  // ext_block_level = 6
            writer.writeBits(8, count: 16) // ext_block_length = 8 字节 (64 bits)
            writer.writeBits(UInt32(l6.maxDisplayMasteringLuminance), count: 16)
            writer.writeBits(UInt32(l6.minDisplayMasteringLuminance), count: 16)
            writer.writeBits(UInt32(l6.maxCLL), count: 16)
            writer.writeBits(UInt32(l6.maxFALL), count: 16)
        }

        // 6. 写入结束块 (ext_block_level = 255)
        writer.writeBits(255, count: 8)
        writer.writeBits(0, count: 16)

        // 字节对齐
        writer.alignToByte(fillBit: false)

        return writer.toData()
    }

    // MARK: - 3. 生成 24 字节的标准 Dolby Vision Configuration Box

    /// 生成符合 ISO Base Media File Format 规范的 24 字节 `DOVIDecoderConfigurationRecord`
    ///
    /// 二进制规格定义：
    /// - Byte 0: `dv_version_major` = 1
    /// - Byte 1: `dv_version_minor` = 0
    /// - Byte 2: `(dv_profile << 1) | ((dv_level >> 5) & 1)`
    /// - Byte 3: `((dv_level & 0x1F) << 3) | (rpu_present << 2) | (el_present << 1) | bl_present`
    /// - Byte 4: `(dv_bl_signal_compatibility_id << 4) | reserved_4bits`
    /// - Byte 5..23: 19 字节保留为 0x00
    ///
    /// - Parameters:
    ///   - profile: 杜比视界 Profile (默认为 Profile 8.1)
    ///   - level: 杜比视界 Level (默认为 6，对应 4K@60fps)
    ///   - rpuPresent: 是否存在 RPU (默认 true)
    ///   - elPresent: 是否存在增强层 (Profile 8.1 必须为 false)
    ///   - blPresent: 是否存在基础层 (默认 true)
    /// - Returns: 严格为 24 字节长度的二进制配置记录数据
    public static func makeDecoderConfigurationRecord(
        profile: DolbyProfile = .profile81,
        level: UInt8 = 6,
        rpuPresent: Bool = true,
        elPresent: Bool = false,
        blPresent: Bool = true
    ) -> Data {
        var data = Data(count: 24)

        data[0] = 1 // dv_version_major
        data[1] = 0 // dv_version_minor

        let p = profile.profileNumber & 0x7F
        let l = level & 0x3F

        // Byte 2: dv_profile (7 bits) + dv_level 高 1 bit
        data[2] = (p << 1) | ((l >> 5) & 0x01)

        // Byte 3: dv_level 低 5 bits + rpu (1 bit) + el (1 bit) + bl (1 bit)
        let rpuFlag: UInt8 = rpuPresent ? 1 : 0
        let elFlag: UInt8 = elPresent ? 1 : 0
        let blFlag: UInt8 = blPresent ? 1 : 0
        data[3] = ((l & 0x1F) << 3) | (rpuFlag << 2) | (elFlag << 1) | blFlag

        // Byte 4: dv_bl_signal_compatibility_id (4 bits) + 4 bits reserved (0)
        let compatId = profile.blCompatibilityID & 0x0F
        data[4] = (compatId << 4)

        // Bytes 5..23: 19 字节保留全为 0x00 (Data 初始化默认全 0)
        return data
    }

    /// 生成完整的 ISOBMFF 原子结构 (Box: 4 字节长度 + 4 字节 FourCC + 24 字节 Record = 32 字节)
    /// - Parameters:
    ///   - fourCC: 原子代码 (例如 "dvcC", "dvvC", "dv81")
    ///   - profile: 杜比视界 Profile
    ///   - level: 级别
    /// - Returns: 32 字节的标准 Box 结构
    public static func makeConfigurationBox(
        fourCC: String = "dv81",
        profile: DolbyProfile = .profile81,
        level: UInt8 = 6
    ) -> Data {
        var boxData = Data()
        boxData.reserveCapacity(32)

        // 1. Box Size: 32 bytes (Big Endian)
        var totalSize: UInt32 = UInt32(32).bigEndian
        withUnsafeBytes(of: &totalSize) { boxData.append(contentsOf: $0) }

        // 2. FourCC: 4 字节
        let fourCCBytes = Array(fourCC.utf8.prefix(4))
        boxData.append(contentsOf: fourCCBytes)
        while boxData.count < 8 {
            boxData.append(0x20)
        }

        // 3. 24 字节 DOVIDecoderConfigurationRecord
        let record = makeDecoderConfigurationRecord(profile: profile, level: level)
        boxData.append(record)

        return boxData
    }
}
