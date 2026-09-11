#ifndef ShaderTypes_h
#define ShaderTypes_h

#ifdef __METAL_VERSION__
#define METAL_FLOAT2 float2
#define METAL_FLOAT3 float3
#define METAL_FLOAT4 float4
#define METAL_FLOAT3X3 float3x3
#define METAL_UINT uint
#else
#import <simd/simd.h>
#define METAL_FLOAT2 simd_float2
#define METAL_FLOAT3 simd_float3
#define METAL_FLOAT4 simd_float4
#define METAL_FLOAT3X3 simd_float3x3
#define METAL_UINT uint32_t
#endif

/// 顶点着色器输入结构
struct Vertex2D {
    METAL_FLOAT2 position;
    METAL_FLOAT2 texCoords;
};

/// 顶点缓冲区索引枚举
enum VertexBufferIndex {
    VertexBufferIndexVertices = 0,
    VertexBufferIndexUniforms = 1
};

/// 纹理缓冲区索引枚举
enum TextureIndex {
    TextureIndexLuma = 0,       // Y / I 分量纹理 (单通道或 P010)
    TextureIndexChroma = 1,     // UV / PT 分量纹理 (双通道交错)
    TextureIndexRGBInput = 2    // RGB 线性输入纹理 (用于后处理或色调映射)
};

/// 1. Dolby IPT -> RGB 色彩转换常量缓冲区
struct IPTUniforms {
    /// 目标色彩空间基准: 0 = BT.2020 宽色域, 1 = BT.709 / sRGB 色域, 2 = DCI-P3
    METAL_UINT targetGamut;

    /// 是否使用 SMPTE ST 2084 PQ 逆转换 (1 = Dolby Vision Profile 5 官方 IPTPQ, 0 = 广义伽马非线性)
    METAL_UINT usePQEOTF;

    /// 广义逆伽马幂次系数 (默认 1.0 / 0.43 ≈ 2.32558f，当 usePQEOTF == 0 时生效)
    float invGamma;

    /// 色度输入偏移 (通常为 0.5f，用于归一化 P/T 轴到 [-0.5, 0.5])
    float chromaOffset;
};

/// 2. LLDV RGB 4:4:4 隧道封装常量缓冲区
struct LLDVTunnelUniforms {
    /// 目标封装位深: 8 (标准 8-bit RGB 4:4:4 伪装隧道) 或 10 (10-bit RGB 隧道)
    METAL_UINT outputBitDepth;

    /// 画面像素宽度与高度 (用于水平奇偶像素对齐计算)
    METAL_UINT frameWidth;
    METAL_UINT frameHeight;

    /// 是否翻转低 4 位在 B 通道内的存储顺序 (0: 默认 Dolby 专利标准高位低位对齐, 1: 替代对齐)
    METAL_UINT bitReorderMode;
};

/// 3. EDR / PQ 色调映射常量缓冲区
struct ToneMappingUniforms {
    /// 母版视频动态范围元数据 (来自 RPU)
    float sourceMinLuminance; // nits (通常 0.005)
    float sourceMaxLuminance; // nits (通常 1000.0 或 4000.0)
    float sourceAvgLuminance; // nits (通常 200.0)

    /// 目标显示器能力 (Apple EDR / 外接显示器)
    float targetMaxLuminance; // nits (例如 1600.0 或当前屏峰值)
    float targetMinLuminance; // nits
    float targetEDRHeadroom;  // 当前 EDR Headroom 倍数 (如 1.0 - 16.0)

    /// SDR 参考白色亮度 (通常 100.0 nits 或 203.0 nits)
    float sdrWhiteLuminance;

    /// 映射输出模式:
    /// 0: 原生 Apple EDR (扩展线性浮点输出，> 1.0 触发 XDR 峰值亮度)
    /// 1: ST 2084 PQ 编码输出 (直接输出标准 PQ 曲线给外屏)
    /// 2: 严格剪裁直通 (Pass-Through，不做色调映射)
    METAL_UINT outputMode;

    /// 拐点分界 (Knee Point, 0.0 - 1.0)
    float kneePoint;
};

#endif /* ShaderTypes_h */
