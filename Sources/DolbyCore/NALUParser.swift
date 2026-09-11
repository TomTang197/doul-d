//
//  NALUParser.swift
//  DolbyCore
//
//  Created for Doul D - macOS Dolby Vision Playback & Display Engine.
//  Swift 6 Strict Concurrency Compliant.
//

import Foundation

// MARK: - NALUnit Model

/// HEVC NAL (Network Abstraction Layer) 单元模型
public struct NALUnit: Sendable, Hashable {
    /// NALU 单元类型
    public let type: HEVCNALUType
    /// 图层编号 (nuh_layer_id, 6-bit)
    public let layerId: UInt8
    /// 时域编号 (nuh_temporal_id_plus1, 3-bit)
    public let temporalIdPlus1: UInt8
    /// 起始码长度 (3 字节 00 00 01 或 4 字节 00 00 00 01)
    public let startCodeLength: Int
    /// 2 字节 NALU 头部数据
    public let headerData: Data
    /// 载荷数据 (EBSP，包含防竞争码 0x03，不含起始码和头部 2 字节)
    public let payloadData: Data
    /// 原始完整 NALU 数据 (包含 2 字节头部和载荷，不含起始码)
    public let rawNALUData: Data
    /// 在源比特流中的字节偏移范围 (包含起始码)
    public let streamRange: Range<Int>

    public init(
        type: HEVCNALUType,
        layerId: UInt8,
        temporalIdPlus1: UInt8,
        startCodeLength: Int,
        headerData: Data,
        payloadData: Data,
        rawNALUData: Data,
        streamRange: Range<Int>
    ) {
        self.type = type
        self.layerId = layerId
        self.temporalIdPlus1 = temporalIdPlus1
        self.startCodeLength = startCodeLength
        self.headerData = headerData
        self.payloadData = payloadData
        self.rawNALUData = rawNALUData
        self.streamRange = streamRange
    }

    /// 是否为杜比视界 RPU 单元 (NALU 62)
    public var isDolbyVisionRPU: Bool {
        type.isDolbyVisionRPU
    }

    /// 是否为杜比视界 EL 或增强层单元 (NALU 63)
    public var isDolbyVisionEL: Bool {
        type.isDolbyVisionEL
    }

    /// 是否为 VCL 图像切片数据
    public var isVCL: Bool {
        type.isVCL
    }

    /// 获取脱离防竞争码后的真实载荷数据 (RBSP - Raw Byte Sequence Payload)
    public var rbspData: Data {
        NALUParser.unescapeEBSP(payloadData)
    }
}

// MARK: - NALUParser

/// 高性能 HEVC Annex B 比特流解析器
/// 支持快速检索 00 00 01 / 00 00 00 01 起始码，高效提取 NALU 单元及 RPU (NALU 62)
public enum NALUParser: Sendable {

    /// 解析一段完整的 HEVC Annex B 比特流数据，切分出所有 NALU 单元
    /// - Parameter data: Annex B 字节流
    /// - Returns: 解析得到的 NALU 数组
    public static func parse(annexBData data: Data) -> [NALUnit] {
        var naluList: [NALUnit] = []
        let count = data.count
        guard count >= 5 else { return [] }

        data.withUnsafeBytes { rawBuffer in
            guard let ptr = rawBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }

            var startOffsets: [(startCodeOffset: Int, startCodeLen: Int)] = []
            var i = 0

            // 1. 扫描所有起始码位置
            while i < count - 2 {
                if ptr[i] == 0 && ptr[i + 1] == 0 {
                    if ptr[i + 2] == 1 {
                        // 发现 00 00 01
                        let isFourByte = (i > 0 && ptr[i - 1] == 0)
                        let offset = isFourByte ? (i - 1) : i
                        let len = isFourByte ? 4 : 3
                        startOffsets.append((offset, len))
                        i += 3
                        continue
                    } else if ptr[i + 2] == 0 && i + 3 < count && ptr[i + 3] == 1 {
                        // 显式发现 00 00 00 01
                        startOffsets.append((i, 4))
                        i += 4
                        continue
                    }
                }
                i += 1
            }

            guard !startOffsets.isEmpty else { return }

            // 2. 根据前后起始码切分各个 NALU
            for idx in 0..<startOffsets.count {
                let current = startOffsets[idx]
                let naluDataStart = current.startCodeOffset + current.startCodeLen
                let nextStartCodeOffset = (idx + 1 < startOffsets.count) ? startOffsets[idx + 1].startCodeOffset : count

                guard nextStartCodeOffset >= naluDataStart + 2 else { continue }

                // 解析 2 字节 HEVC NAL Header
                let byte0 = ptr[naluDataStart]
                let byte1 = ptr[naluDataStart + 1]

                // forbidden_zero_bit 必须为 0
                guard (byte0 & 0x80) == 0 else { continue }

                let nalUnitTypeRaw = (byte0 >> 1) & 0x3F
                let layerId = ((byte0 & 0x01) << 5) | ((byte1 >> 3) & 0x1F)
                let temporalId = byte1 & 0x07

                let headerData = data.subdata(in: naluDataStart..<(naluDataStart + 2))
                let payloadData = data.subdata(in: (naluDataStart + 2)..<nextStartCodeOffset)
                let rawNALUData = data.subdata(in: naluDataStart..<nextStartCodeOffset)
                let streamRange = current.startCodeOffset..<nextStartCodeOffset

                let unit = NALUnit(
                    type: HEVCNALUType(rawValue: nalUnitTypeRaw),
                    layerId: layerId,
                    temporalIdPlus1: temporalId,
                    startCodeLength: current.startCodeLen,
                    headerData: headerData,
                    payloadData: payloadData,
                    rawNALUData: rawNALUData,
                    streamRange: streamRange
                )
                naluList.append(unit)
            }
        }

        return naluList
    }

    /// 仅提取比特流中的杜比视界 RPU (NALU 62)
    /// - Parameter data: Annex B 字节流
    /// - Returns: 所有解析到的 RPU 单元
    public static func extractRPUNALUs(from data: Data) -> [NALUnit] {
        return parse(annexBData: data).filter { $0.isDolbyVisionRPU }
    }

    // MARK: - Emulation Prevention (防竞争字节转义/反转义)

    /// 将 EBSP (Encapsulated Byte Sequence Payload) 反转义为 RBSP (Raw Byte Sequence Payload)
    /// 移除 Annex B 比特流中的防竞争字节 0x03 (0x00 0x00 0x03 -> 0x00 0x00)
    public static func unescapeEBSP(_ ebsp: Data) -> Data {
        let count = ebsp.count
        guard count >= 3 else { return ebsp }

        var rbsp = Data()
        rbsp.reserveCapacity(count)

        ebsp.withUnsafeBytes { rawBuffer in
            guard let ptr = rawBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            var i = 0
            while i < count {
                if i + 2 < count && ptr[i] == 0x00 && ptr[i + 1] == 0x00 && ptr[i + 2] == 0x03 {
                    // 如果 00 00 03 后面跟着 00, 01, 02, 03，则移除 0x03
                    if i + 3 < count && ptr[i + 3] <= 0x03 {
                        rbsp.append(0x00)
                        rbsp.append(0x00)
                        i += 3
                        continue
                    } else if i + 3 == count {
                        // 结尾处的 00 00 03
                        rbsp.append(0x00)
                        rbsp.append(0x00)
                        i += 3
                        continue
                    }
                }
                rbsp.append(ptr[i])
                i += 1
            }
        }

        return rbsp
    }

    /// 将 RBSP 编码为安全传输的 EBSP，在可能造成歧义的 0x00 0x00 序列后注入 0x03
    public static func escapeRBSP(_ rbsp: Data) -> Data {
        let count = rbsp.count
        guard count >= 2 else { return rbsp }

        var ebsp = Data()
        ebsp.reserveCapacity(count + (count / 10))

        rbsp.withUnsafeBytes { rawBuffer in
            guard let ptr = rawBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            var zeroCount = 0

            for i in 0..<count {
                let byte = ptr[i]
                if zeroCount >= 2 && byte <= 0x03 {
                    ebsp.append(0x03)
                    zeroCount = 0
                }

                ebsp.append(byte)

                if byte == 0x00 {
                    zeroCount += 1
                } else {
                    zeroCount = 0
                }
            }
        }

        return ebsp
    }

    /// 包装 RBSP 载荷生成合法的 NALU 62 (Dolby Vision RPU) 完整字节
    /// - Parameters:
    ///   - rbsp: 未转义的 RPU 载荷
    ///   - startCode: 优选的起始码 (默认为 4 字节 00 00 00 01)
    /// - Returns: 包含起始码、NALU 62 头部和转义 EBSP 的完整数据
    public static func packageRPUNALU(rbsp: Data, startCode: Data = Data([0x00, 0x00, 0x00, 0x01])) -> Data {
        var output = startCode
        // NALU 62 Header: byte0 = (0 << 7) | (62 << 1) | 0 = 0x7C; byte1 = (0 << 3) | 1 = 0x01
        output.append(contentsOf: [0x7C, 0x01])
        output.append(escapeRBSP(rbsp))
        return output
    }
}

// MARK: - NALUStreamParser (流式解析器)

/// 具备跨 Chunk 拼接能力的流式 HEVC Annex B 解析器
/// 针对网络实时流、管道分块输入（例如 FFmpeg 解复用管道）提供无锁连续流式切片
public final class NALUStreamParser: @unchecked Sendable {
    private var buffer = Data()
    private let lock = NSLock()

    public init() {}

    /// 输入新的分块数据，并解析返回所有已完成的完整 NALU
    public func append(data: Data) -> [NALUnit] {
        lock.lock()
        defer { lock.unlock() }

        buffer.append(data)
        let count = buffer.count
        guard count >= 5 else { return [] }

        var startOffsets: [(startCodeOffset: Int, startCodeLen: Int)] = []
        buffer.withUnsafeBytes { rawBuffer in
            guard let ptr = rawBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            var i = 0
            while i < count - 2 {
                if ptr[i] == 0 && ptr[i + 1] == 0 {
                    if ptr[i + 2] == 1 {
                        let isFourByte = (i > 0 && ptr[i - 1] == 0)
                        let offset = isFourByte ? (i - 1) : i
                        let len = isFourByte ? 4 : 3
                        startOffsets.append((offset, len))
                        i += 3
                        continue
                    } else if ptr[i + 2] == 0 && i + 3 < count && ptr[i + 3] == 1 {
                        startOffsets.append((i, 4))
                        i += 4
                        continue
                    }
                }
                i += 1
            }
        }

        // 必须至少观察到下一个起始码，前面的 NALU 才是真正闭合完整的
        guard startOffsets.count >= 2 else {
            return []
        }

        let lastCompleteEnd = startOffsets.last!.startCodeOffset
        let completeData = buffer.subdata(in: 0..<lastCompleteEnd)
        let parsed = NALUParser.parse(annexBData: completeData)

        // 缓冲区保留最后一个起始码开始的未闭合数据
        buffer = buffer.subdata(in: lastCompleteEnd..<buffer.count)

        return parsed
    }

    /// 刷新并输出缓冲区中残留的最后一个 NALU
    public func flush() -> [NALUnit] {
        lock.lock()
        defer { lock.unlock() }

        guard !buffer.isEmpty else { return [] }
        let parsed = NALUParser.parse(annexBData: buffer)
        buffer.removeAll()
        return parsed
    }

    /// 重置流解析器状态
    public func reset() {
        lock.lock()
        defer { lock.unlock() }
        buffer.removeAll()
    }
}
