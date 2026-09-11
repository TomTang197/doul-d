#include <metal_stdlib>
#include "ShaderTypes.h"

using namespace metal;

// MARK: - 顶点着色器输出

struct RasterizerData {
    float4 clipSpacePosition [[position]];
    float2 textureCoordinate;
};

// MARK: - 通用全屏 Quad 顶点着色器

vertex RasterizerData iptVertexShader(
    uint vertexID [[vertex_id]],
    constant Vertex2D *vertices [[buffer(VertexBufferIndexVertices)]]
) {
    RasterizerData out;
    out.clipSpacePosition = float4(vertices[vertexID].position, 0.0, 1.0);
    out.textureCoordinate = vertices[vertexID].texCoords;
    return out;
}

// MARK: - SMPTE ST 2084 (PQ) 逆电光转换函数 (EOTF)
// 将归一化 PQ 非线性信号还原为线性值 [0.0, 1.0] (对应 0 ~ 10,000 nits)

inline float pq_eotf_scalar(float n) {
    constexpr float m1_inv = 16384.0f / 2610.0f;           // 6.277394636
    constexpr float m2_inv = 4096.0f / (2523.0f * 128.0f);  // 0.0126833135
    constexpr float c1 = 3424.0f / 4096.0f;                // 0.8359375
    constexpr float c2 = 2413.0f / 4096.0f * 32.0f;         // 18.8515625
    constexpr float c3 = 2392.0f / 4096.0f * 32.0f;         // 18.6875

    float clamped_n = clamp(n, 0.0f, 1.0f);
    float np = pow(clamped_n, m2_inv);
    float num = max(np - c1, 0.0f);
    float den = max(c2 - c3 * np, 1e-7f);
    return pow(num / den, m1_inv);
}

// MARK: - Step 2: 逆杜比非线性转换函数
// 恢复为线性 LMS 响应 (支持官方 IPTPQ 与广义逆非线性伽马)

inline float3 ipt_to_linear_lms(float3 lms_prime, uint usePQ, float invGamma) {
    if (usePQ != 0) {
        // Dolby Vision Profile 5 (IPTPQ): 对非线性 LMS' 应用 PQ EOTF
        return float3(
            pq_eotf_scalar(lms_prime.r),
            pq_eotf_scalar(lms_prime.g),
            pq_eotf_scalar(lms_prime.b)
        );
    } else {
        // 广义非线性伽马模型 (Ebner & Fairchild IPT，符号保护幂函数)
        return sign(lms_prime) * pow(abs(lms_prime), float3(invGamma));
    }
}

// MARK: - Step 3: LMS 到目标线性 RGB 空间色彩矩阵

// 1. Dolby Vision HPE LMS 到 Rec.2020 线性 RGB 矩阵 (列优先存储)
constant float3x3 kLMS_to_Rec2020 = float3x3(
    float3( 3.06441879f, -0.65612108f,  0.01736321f), // Column 0
    float3(-2.16597676f,  1.78554118f, -0.04725154f), // Column 1
    float3( 0.10155818f, -0.12943749f,  1.03004253f)  // Column 2
);

// 2. Dolby Vision HPE LMS 到 Rec.709 线性 RGB 矩阵 (列优先存储)
constant float3x3 kLMS_to_Rec709 = float3x3(
    float3( 6.17255146f, -1.32406322f, -0.01160117f), // Column 0
    float3(-5.32005315f,  2.56032946f, -0.26498497f), // Column 1
    float3( 0.14733143f, -0.23624408f,  1.27683267f)  // Column 2
);

// 3. Dolby Vision HPE LMS 到 DCI-P3 线性 RGB 矩阵 (列优先存储)
constant float3x3 kLMS_to_DCIP3 = float3x3(
    float3( 4.30136690f, -0.90612974f,  0.03916095f), // Column 0
    float3(-3.41110370f,  2.06279339f, -0.08914965f), // Column 1
    float3( 0.10973253f, -0.15668399f,  1.05014584f)  // Column 2
);

// MARK: - Step 1: IPT 空间到非线性 LMS 逆矩阵 (Dolby / Ebner & Fairchild 规范)
// L' = 1.0 * I + 0.0975689 * P + 0.205226 * T
// M' = 1.0 * I - 0.1138760 * P + 0.133217 * T
// S' = 1.0 * I + 0.0326151 * P - 0.676887 * T
constant float3x3 kIPT_to_LMS_Prime = float3x3(
    float3(1.00000000f,  1.00000000f,  1.00000000f), // Column 0
    float3(0.09756890f, -0.11387600f,  0.03261510f), // Column 1
    float3(0.20522600f,  0.13321700f, -0.67688700f)  // Column 2
);

// MARK: - Dolby Vision Profile 5 IPT -> 线性 RGB 片段着色器
//
// 核心机制说明：
// 普通播放器将 Profile 5 的 IPT 容器误判为标准 YCbCr 时，因 IPT 色度轴与 YCbCr 截然不同，
// 导致人脸与高光偏紫粉红、背景阴影偏翠绿色。
// 本着色器完整实现杜比官方 IPT 数学解算管线：
// 1. 抽取 I, P, T 信号，归一化色度分量
// 2. 逆矩阵还原非线性视锥响应 LMS'
// 3. 逆 ST 2084 PQ EOTF 恢复高动态线性锥细胞能量 LMS
// 4. HPE LMS 空间投影至 BT.2020 / P3 / BT.709 线性 RGB

fragment float4 dolbyIPTToRGBFragmentShader(
    RasterizerData in [[stage_in]],
    texture2d<float, access::sample> lumaTexture [[texture(TextureIndexLuma)]],
    texture2d<float, access::sample> chromaTexture [[texture(TextureIndexChroma)]],
    constant IPTUniforms &uniforms [[buffer(VertexBufferIndexUniforms)]]
) {
    constexpr sampler textureSampler(mag_filter::linear, min_filter::linear, address::clamp_to_edge);

    // 1. 抽取像素纹理
    // 对于 BiPlanar 格式 (例如 P010 / 420YpCbCr10BiPlanar):
    // lumaTexture.r 存储强度分量 I (Intensity, [0, 1])
    // chromaTexture.rg 存储色度分量 P (Protan, 红色-绿色差异) 与 T (Tritan, 黄色-蓝色差异)
    float I = lumaTexture.sample(textureSampler, in.textureCoordinate).r;
    float2 PT = chromaTexture.sample(textureSampler, in.textureCoordinate).rg;

    // 色度归一化 (将 [0, 1] 偏移映射回双极性中心 [-0.5, 0.5])
    float P = PT.x - uniforms.chromaOffset;
    float T = PT.y - uniforms.chromaOffset;

    float3 ipt = float3(I, P, T);

    // Step 1: IPT 空间通过逆矩阵转为非线性 LMS 空间 (L', M', S')
    float3 lms_prime = kIPT_to_LMS_Prime * ipt;

    // Step 2: 逆杜比非线性转换函数 (SMPTE ST 2084 PQ EOTF 或广义幂律) 恢复为线性 LMS
    float3 lms_linear = ipt_to_linear_lms(lms_prime, uniforms.usePQEOTF, uniforms.invGamma);

    // Step 3: LMS 到 Rec.2020 / Rec.709 / DCI-P3 线性 RGB 矩阵变换
    float3 linearRGB;
    switch (uniforms.targetGamut) {
        case 1:
            linearRGB = kLMS_to_Rec709 * lms_linear;
            break;
        case 2:
            linearRGB = kLMS_to_DCIP3 * lms_linear;
            break;
        default:
            linearRGB = kLMS_to_Rec2020 * lms_linear;
            break;
    }

    // 防止浮点溢出导致的负能量伪影
    linearRGB = max(linearRGB, float3(0.0f));

    return float4(linearRGB, 1.0f);
}
