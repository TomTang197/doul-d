//
//  CMSampleBuffer+Dolby.swift
//  DolbyCore
//
//  Created for Doul D - macOS Dolby Vision Playback & Display Engine.
//  Swift 6 Strict Concurrency Compliant.
//

import Foundation
import CoreMedia
import CoreVideo
import AVFoundation

// MARK: - CMVideoFormatDescription 杜比视界扩展

extension CMVideoFormatDescription {

    /// 创建或重构注入了杜比视界 Profile 8.1 规格的 `CMVideoFormatDescription`
    ///
    /// 借鉴 tvOS AVFoundation 播放管线机制：
    /// 1. 向 `kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms` 注入 `dvcC` 与 `dv81` 24 字节原子配置
    /// 2. 注入 ITU-R BT.2020 原色、SMPTE ST 2084 PQ 传递函数以及 BT.2020 非恒定亮度矩阵
    /// 3. 若提供 Level 6 元数据，注入 Mastering Display Color Volume 与 Content Light Level 扩展
    ///
    /// - Parameters:
    ///   - codecType: 视频编码或像素格式 (压缩流默认为 kCMVideoCodecType_HEVC)
    ///   - width: 视频画面像素宽度
    ///   - height: 视频画面像素高度
    ///   - profile: 杜比视界 Profile (默认为 .profile81)
    ///   - level: 杜比视界 Level (默认 6，代表 4K@60)
    ///   - configRecord: 可选的自定义 24 字节 DOVI 配置记录，若为空则自动生成
    ///   - level6: 可选的 Level 6 静态 HDR 元数据 (MaxCLL/MaxFALL)
    /// - Returns: 成功配置杜比视界扩展的 `CMVideoFormatDescription`
    public static func makeDolbyVisionFormatDescription(
        codecType: CMVideoCodecType = kCMVideoCodecType_HEVC,
        width: Int32,
        height: Int32,
        profile: DolbyProfile = .profile81,
        level: UInt8 = 6,
        configRecord: Data? = nil,
        level6: DolbyLevel6Metadata? = nil
    ) -> CMVideoFormatDescription? {
        // 1. 获取 24 字节的 DOVIDecoderConfigurationRecord
        let record = configRecord ?? RPUProcessor.makeDecoderConfigurationRecord(profile: profile, level: level)

        // 2. 构造 SampleDescriptionExtensionAtoms 字典 (包含 dvcC 和 dv81 / dvvC)
        var atoms: [String: Any] = [
            "dvcC": record,
            profile.preferredFourCC: record
        ]
        if profile == .profile81 {
            atoms["dv81"] = record
            atoms["dvvC"] = record
        }

        // 3. 构建 CoreMedia 扩展字典
        var extensions: [String: Any] = [
            kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms as String: atoms,
            kCMFormatDescriptionExtension_ColorPrimaries as String: profile.colorSpace.cvColorPrimaries,
            kCMFormatDescriptionExtension_TransferFunction as String: profile.colorSpace.cvTransferFunction,
            kCMFormatDescriptionExtension_YCbCrMatrix as String: profile.colorSpace.cvMatrix,
            kCMFormatDescriptionExtension_FullRangeVideo as String: kCFBooleanFalse as Any,
            kCMFormatDescriptionExtension_FormatName as String: "HEVC (Dolby Vision Profile \(profile.profileNumber))"
        ]

        // 4. 若具备 Level 6 静态元数据，注入 ContentLightLevelInfo (MaxCLL / MaxFALL)
        if let l6 = level6 {
            var clliData = Data(count: 4)
            var maxCLLBig = l6.maxCLL.bigEndian
            var maxFALLBig = l6.maxFALL.bigEndian
            withUnsafeBytes(of: &maxCLLBig) { clliData.replaceSubrange(0..<2, with: $0) }
            withUnsafeBytes(of: &maxFALLBig) { clliData.replaceSubrange(2..<4, with: $0) }
            extensions[kCMFormatDescriptionExtension_ContentLightLevelInfo as String] = clliData
        }

        var formatDesc: CMVideoFormatDescription?
        let status = CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            codecType: codecType,
            width: width,
            height: height,
            extensions: extensions as CFDictionary,
            formatDescriptionOut: &formatDesc
        )

        guard status == noErr, let result = formatDesc else {
            return nil
        }
        return result
    }

    /// 基于已有的格式描述，注入杜比视界扩展生成新格式描述
    public func injectingDolbyVision(
        profile: DolbyProfile = .profile81,
        level: UInt8 = 6,
        configRecord: Data? = nil,
        level6: DolbyLevel6Metadata? = nil
    ) -> CMVideoFormatDescription? {
        let dimensions = CMVideoFormatDescriptionGetDimensions(self)
        let codec = CMFormatDescriptionGetMediaSubType(self)
        return CMVideoFormatDescription.makeDolbyVisionFormatDescription(
            codecType: codec,
            width: dimensions.width,
            height: dimensions.height,
            profile: profile,
            level: level,
            configRecord: configRecord,
            level6: level6
        )
    }
}

// MARK: - CVImageBuffer 杜比色彩空间注入

extension CVImageBuffer {

    /// 为解复用或解码后的 CVImageBuffer (CVPixelBuffer) 注入杜比色彩空间属性及元数据附件
    /// 确保 Metal 着色器与 Apple EDR 渲染管线识别其为 BT.2020 PQ / 杜比色彩空间
    public func injectDolbyVisionAttachments(colorSpace: DolbyColorSpace = .rec2020PQ) {
        CVBufferSetAttachment(
            self,
            kCVImageBufferColorPrimariesKey,
            colorSpace.cvColorPrimaries,
            .shouldPropagate
        )
        CVBufferSetAttachment(
            self,
            kCVImageBufferTransferFunctionKey,
            colorSpace.cvTransferFunction,
            .shouldPropagate
        )
        CVBufferSetAttachment(
            self,
            kCVImageBufferYCbCrMatrixKey,
            colorSpace.cvMatrix,
            .shouldPropagate
        )
    }
}

// MARK: - CMSampleBuffer 杜比视界封装与注入

extension CMSampleBuffer {

    /// 自定义杜比视界 RPU 帧附件键名
    public static let dolbyVisionRPUAttachmentKey: String = "com.dould.attachment.DolbyVisionRPU"

    /// 为当前 `CMSampleBuffer` 注入杜比视界 Profile 8.1 格式描述与系统附件
    ///
    /// 借鉴 tvOS/iOS 提交杜比视界帧的管线：
    /// 1. 更新内部 FormatDescription，注入 `dvcC`/`dv81` 原子与 BT.2020 PQ 属性
    /// 2. 若附带 CVPixelBuffer，为其同步配置底层 CVBuffer 原色和传递函数
    /// 3. 设置 `kCMSampleAttachmentKey_DisplayImmediately` 确保低延迟无卡顿送显
    /// 4. 将重构后的 Profile 8.1 RPU 挂载至 SampleBuffer 附件供渲染管线即时提取
    ///
    /// - Parameters:
    ///   - rpuNALUData: 重构后的合法的 Profile 8.1 RPU 数据 (NALU 62)
    ///   - profile: 目标杜比 Profile (默认 .profile81)
    ///   - level: 杜比 Level (默认 6)
    ///   - level6: 静态元数据
    /// - Returns: 注入杜比视界元数据后的全新 `CMSampleBuffer`
    public func injectingDolbyVision(
        rpuNALUData: Data,
        profile: DolbyProfile = .profile81,
        level: UInt8 = 6,
        level6: DolbyLevel6Metadata? = nil
    ) throws -> CMSampleBuffer {
        guard let originalFormat = CMSampleBufferGetFormatDescription(self) else {
            throw DolbyInjectionError.missingFormatDescription
        }

        var timing = CMSampleTimingInfo(
            duration: CMSampleBufferGetDuration(self),
            presentationTimeStamp: CMSampleBufferGetPresentationTimeStamp(self),
            decodeTimeStamp: CMSampleBufferGetDecodeTimeStamp(self)
        )

        var newSampleBuffer: CMSampleBuffer?

        // A. 若 SampleBuffer 封装的是未压缩的 CVPixelBuffer / CVImageBuffer
        if let imageBuffer = CMSampleBufferGetImageBuffer(self) {
            // 为底层像素缓冲注入色彩空间
            imageBuffer.injectDolbyVisionAttachments(colorSpace: profile.colorSpace)

            // 为 ImageBuffer 生成对应的格式描述
            var updatedFormat: CMVideoFormatDescription?
            let formatStatus = CMVideoFormatDescriptionCreateForImageBuffer(
                allocator: kCFAllocatorDefault,
                imageBuffer: imageBuffer,
                formatDescriptionOut: &updatedFormat
            )
            let dolbyFormat = (formatStatus == noErr && updatedFormat != nil) ? updatedFormat! : originalFormat

            let status = CMSampleBufferCreateReadyWithImageBuffer(
                allocator: kCFAllocatorDefault,
                imageBuffer: imageBuffer,
                formatDescription: dolbyFormat,
                sampleTiming: &timing,
                sampleBufferOut: &newSampleBuffer
            )

            guard status == noErr, let outputBuffer = newSampleBuffer else {
                throw DolbyInjectionError.sampleBufferCreationFailed(status)
            }

            // 设置附件：即时显示
            CMSampleBuffer.setDisplayImmediately(on: outputBuffer)
            // 挂载 RPU 数据
            CMSampleBuffer.attachRPUData(rpuNALUData, to: outputBuffer)

            return outputBuffer
        }

        // B. 若 SampleBuffer 封装的是压缩比特流 (CMBlockBuffer)
        if let dataBuffer = CMSampleBufferGetDataBuffer(self) {
            let dolbyFormat = originalFormat.injectingDolbyVision(
                profile: profile,
                level: level,
                level6: level6
            ) ?? originalFormat

            let numSamples = CMSampleBufferGetNumSamples(self)

            let status = CMSampleBufferCreate(
                allocator: kCFAllocatorDefault,
                dataBuffer: dataBuffer,
                dataReady: true,
                makeDataReadyCallback: nil,
                refcon: nil,
                formatDescription: dolbyFormat,
                sampleCount: numSamples,
                sampleTimingEntryCount: 1,
                sampleTimingArray: &timing,
                sampleSizeEntryCount: 0,
                sampleSizeArray: nil,
                sampleBufferOut: &newSampleBuffer
            )

            guard status == noErr, let outputBuffer = newSampleBuffer else {
                throw DolbyInjectionError.sampleBufferCreationFailed(status)
            }

            CMSampleBuffer.setDisplayImmediately(on: outputBuffer)
            CMSampleBuffer.attachRPUData(rpuNALUData, to: outputBuffer)

            return outputBuffer
        }

        throw DolbyInjectionError.unsupportedSampleBuffer
    }

    /// 设置 DisplayImmediately 附件
    private static func setDisplayImmediately(on buffer: CMSampleBuffer) {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: true) as? [CFMutableDictionary],
              !attachments.isEmpty else { return }
        let dict = attachments[0]
        CFDictionarySetValue(
            dict,
            Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
            Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
        )
    }

    /// 挂载 RPU 二进制数据到 SampleBuffer 附件
    public static func attachRPUData(_ rpuData: Data, to buffer: CMSampleBuffer) {
        CMSetAttachment(
            buffer,
            key: dolbyVisionRPUAttachmentKey as CFString,
            value: rpuData as CFData,
            attachmentMode: kCMAttachmentMode_ShouldPropagate
        )
    }

    /// 从 SampleBuffer 附件中提取杜比视界 RPU 数据
    public var dolbyVisionRPUData: Data? {
        guard let attachment = CMGetAttachment(self, key: Self.dolbyVisionRPUAttachmentKey as CFString, attachmentModeOut: nil) as? Data else {
            return nil
        }
        return attachment
    }
}

// MARK: - DolbyInjectionError

public enum DolbyInjectionError: Error, LocalizedError, Sendable {
    case missingFormatDescription
    case unsupportedSampleBuffer
    case sampleBufferCreationFailed(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .missingFormatDescription:
            return "Original CMSampleBuffer is missing CMVideoFormatDescription."
        case .unsupportedSampleBuffer:
            return "CMSampleBuffer has neither CVPixelBuffer nor CMBlockBuffer."
        case .sampleBufferCreationFailed(let status):
            return "Failed to create CMSampleBuffer with Dolby Vision format description, OSStatus: \(status)."
        }
    }
}
