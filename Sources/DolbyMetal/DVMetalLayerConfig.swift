import Foundation
import QuartzCore
import Metal
import Cocoa
import os.log

private let logger = Logger(subsystem: "com.dould.DolbyMetal", category: "DVMetalLayerConfig")

// MARK: - 目标色彩空间枚举

/// 杜比视界 Metal 图层色彩空间选项
public enum DVColorSpaceType: String, Sendable, CaseIterable {
    /// ITU-R BT.2100 PQ 规范色彩空间 (广泛用于杜比视界与 HDR10 播放)
    case itur2100_PQ = "ITU-R BT.2100 PQ"
    /// 扩展线性 Rec.2020 色彩空间 (Apple EDR 峰值浮点驱动)
    case extendedLinearITUR_2020 = "Extended Linear BT.2020"
    /// 扩展线性 Display P3 色彩空间 (MacBook Pro Liquid Retina XDR 原生色域)
    case extendedLinearDisplayP3 = "Extended Linear Display P3"
    /// 标准 sRGB 色彩空间 (用于 LLDV RGB 8-bit 伪装隧道直通，防止系统介入色彩修正)
    case standardSRGB = "Standard sRGB (Tunneling Passthrough)"

    /// 转换为系统底层 CGColorSpace
    public var cgColorSpace: CGColorSpace? {
        switch self {
        case .itur2100_PQ:
            return CGColorSpace(name: CGColorSpace.itur_2100_PQ)
        case .extendedLinearITUR_2020:
            return CGColorSpace(name: CGColorSpace.extendedLinearITUR_2020)
        case .extendedLinearDisplayP3:
            return CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)
        case .standardSRGB:
            return CGColorSpace(name: CGColorSpace.sRGB)
        }
    }
}

// MARK: - DVMetalLayerConfig

/// CAMetalLayer 高动态范围 (EDR) 与 LLDV 隧道特性专业配置器
public final class DVMetalLayerConfig: Sendable {

    public init() {}

    // MARK: - 1. 配置 Apple EDR 高动态范围特性

    /// 为 CAMetalLayer 配置 Apple EDR 满血动态范围呈现
    /// - Parameters:
    ///   - layer: 目标 CAMetalLayer
    ///   - colorSpace: 目标色彩空间 (默认 itur_2100_PQ)
    ///   - device: 绑定的 Metal 设备
    public static func configureForEDR(
        layer: CAMetalLayer,
        colorSpace: DVColorSpaceType = .itur2100_PQ,
        device: MTLDevice? = nil
    ) {
        if let dev = device ?? layer.device ?? MTLCreateSystemDefaultDevice() {
            layer.device = dev
        }

        // 1. 激活 macOS Extended Dynamic Range (EDR) 支持
        // 当设置为 true 时，macOS WindowServer 允许绘制超越 SDR 1.0 的超亮物理高光
        layer.wantsExtendedDynamicRangeContent = true

        // 2. 设置 16-bit 浮点像素格式，彻底杜绝色彩阶断 (Banding) 与精度损耗
        layer.pixelFormat = .rgba16Float

        // 3. 配置高动态色彩空间
        if let cs = colorSpace.cgColorSpace {
            layer.colorspace = cs
        } else {
            layer.colorspace = CGColorSpace(name: CGColorSpace.itur_2100_PQ)
        }

        // 4. 优化显示属性
        layer.framebufferOnly = true
        layer.allowsNextDrawableTimeout = false
        layer.isOpaque = true

        logger.info("CAMetalLayer successfully configured for EDR: pixelFormat=.rgba16Float, wantsEDR=true, colorSpace=\(colorSpace.rawValue)")
    }

    // MARK: - 2. 配置 LLDV 隧道透传特性

    /// 为 CAMetalLayer 配置 8-bit RGB 4:4:4 伪装隧道直通模式
    /// - Parameters:
    ///   - layer: 目标 CAMetalLayer
    ///   - device: 绑定的 Metal 设备
    public static func configureForLLDVTunnel(
        layer: CAMetalLayer,
        device: MTLDevice? = nil
    ) {
        if let dev = device ?? layer.device ?? MTLCreateSystemDefaultDevice() {
            layer.device = dev
        }

        // 隧道模式下关闭系统级 EDR 色调重映射，确保 8-bit 位封装不被操作系统破坏
        layer.wantsExtendedDynamicRangeContent = false

        // 采用标准 8-bit BGRA 或 RGBA 格式模拟 HDMI 传输帧
        layer.pixelFormat = .bgra8Unorm

        // 绑定标准 sRGB 色彩空间，告知 WindowServer 无需介入色彩空间转换
        layer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)

        layer.framebufferOnly = true
        layer.allowsNextDrawableTimeout = false
        layer.isOpaque = true

        logger.info("CAMetalLayer successfully configured for LLDV Tunneling: pixelFormat=.bgra8Unorm, sRGB passthrough")
    }

    // MARK: - 3. 动态更新 Drawable 大小与视口

    /// 根据宿主 View 尺寸与屏幕物理 backingScaleFactor 动态同步 drawableSize
    /// 保证杜比视界画面像素 1:1 绝对点对点映射，避免画面缩放导致的位重排错位
    /// - Parameters:
    ///   - layer: 目标 CAMetalLayer
    ///   - bounds: 视图逻辑边界尺寸
    ///   - backingScaleFactor: 屏幕 Retina 缩放倍率 (通常 2.0)
    public static func updateDrawableSize(
        for layer: CAMetalLayer,
        bounds: CGRect,
        backingScaleFactor: CGFloat
    ) {
        guard bounds.width > 0 && bounds.height > 0 else { return }

        let scale = max(1.0, backingScaleFactor)
        let pixelWidth = Int(round(bounds.width * scale))
        let pixelHeight = Int(round(bounds.height * scale))

        let targetSize = CGSize(width: pixelWidth, height: pixelHeight)

        if layer.drawableSize != targetSize {
            layer.drawableSize = targetSize
            logger.debug("Updated CAMetalLayer drawableSize to \(pixelWidth)x\(pixelHeight) (scale: \(scale))")
        }
    }

    // MARK: - 4. 动态色彩空间更新

    /// 动态切换 CAMetalLayer 色彩空间
    public static func updateColorSpace(
        for layer: CAMetalLayer,
        to newColorSpace: DVColorSpaceType
    ) {
        if let cs = newColorSpace.cgColorSpace {
            layer.colorspace = cs
            logger.info("CAMetalLayer colorspace dynamically changed to \(newColorSpace.rawValue)")
        }
    }

    // MARK: - 5. 屏幕 EDR Headroom 探测辅助

    /// 查询指定屏幕当前活跃的 EDR 峰值能力倍数
    /// - Parameter screen: 目标 NSScreen (若为 nil 则取当前主屏幕)
    /// - Returns: (当前可用 Headroom 倍数, 理论最大潜在 Headroom 倍数)
    public static func queryScreenEDRHeadroom(
        for screen: NSScreen? = NSScreen.main
    ) -> (current: Float, maxPotential: Float) {
        guard let s = screen else {
            return (1.0, 1.0)
        }

        let current = Float(s.maximumExtendedDynamicRangeColorComponentValue)
        let maxPot = Float(s.maximumPotentialExtendedDynamicRangeColorComponentValue)

        return (max(1.0, current), max(1.0, maxPot))
    }
}
