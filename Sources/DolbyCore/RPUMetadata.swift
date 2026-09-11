import Foundation

/// 杜比视界 RPU (Reference Processing Unit) 动态元数据模型
/// 包含 SMPTE ST 2086 / ST 2094-10 标准中的各级动态亮度与色度调整参数
public struct RPUMetadata: Sendable, Equatable {
    /// 母版监视器最小亮度 (单位: nits / cd/m²)
    public var minLuminance: Float
    /// 母版监视器最大亮度 (单位: nits / cd/m²，例如 1000.0, 4000.0, 10000.0)
    public var maxLuminance: Float
    /// 场景平均亮度 (单位: nits / cd/m²，Mid-Tone Anchor)
    public var avgLuminance: Float

    /// 杜比视界 Profile 标识 (例如 Profile 5, Profile 7, Profile 8.1 等)
    public var profile: DolbyProfile

    /// 拐点 (Knee Point / S-Curve 映射分界点，范围 0.0 - 1.0)
    public var kneePoint: Float

    public init(
        minLuminance: Float = 0.005,
        maxLuminance: Float = 1000.0,
        avgLuminance: Float = 200.0,
        profile: DolbyProfile = .profile5,
        kneePoint: Float = 0.5
    ) {
        self.minLuminance = minLuminance
        self.maxLuminance = maxLuminance
        self.avgLuminance = avgLuminance
        self.profile = profile
        self.kneePoint = kneePoint
    }

    /// 默认母版参数 (1000 nits 监视器标准)
    public static let default1000Nits = RPUMetadata(
        minLuminance: 0.005,
        maxLuminance: 1000.0,
        avgLuminance: 200.0,
        profile: .profile5,
        kneePoint: 0.5
    )

    /// 4000 nits 高亮度母版参数
    public static let default4000Nits = RPUMetadata(
        minLuminance: 0.005,
        maxLuminance: 4000.0,
        avgLuminance: 400.0,
        profile: .profile81,
        kneePoint: 0.6
    )
}
