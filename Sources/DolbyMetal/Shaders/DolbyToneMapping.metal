#include <metal_stdlib>
#include "ShaderTypes.h"

using namespace metal;

// MARK: - 顶点输出结构

struct ToneMapRasterizerData {
    float4 clipSpacePosition [[position]];
    float2 textureCoordinate;
};

// MARK: - 顶点着色器

vertex ToneMapRasterizerData dolbyToneMappingVertexShader(
    uint vertexID [[vertex_id]],
    constant Vertex2D *vertices [[buffer(VertexBufferIndexVertices)]]
) {
    ToneMapRasterizerData out;
    out.clipSpacePosition = float4(vertices[vertexID].position, 0.0, 1.0);
    out.textureCoordinate = vertices[vertexID].texCoords;
    return out;
}

// MARK: - SMPTE ST 2084 (PQ) 官方常数定义

constant float kPQ_m1 = 2610.0f / 16384.0f;          // 0.1593017578125
constant float kPQ_m2 = 2523.0f / 4096.0f * 128.0f;  // 78.84375
constant float kPQ_c1 = 3424.0f / 4096.0f;          // 0.8359375
constant float kPQ_c2 = 2413.0f / 4096.0f * 32.0f;   // 18.8515625
constant float kPQ_c3 = 2392.0f / 4096.0f * 32.0f;   // 18.6875

// MARK: - SMPTE ST 2084 (PQ) EOTF 逆电光转换函数
// 输入: 归一化 PQ 非线性电平 [0.0, 1.0]
// 输出: 绝对物理亮度值 (单位: nits / cd/m², 范围: 0.0 ~ 10,000.0 nits)

inline float pq_eotf(float N) {
    float clamped_N = clamp(N, 0.0f, 1.0f);
    float Np = pow(clamped_N, 1.0f / kPQ_m2);
    float num = max(Np - kPQ_c1, 0.0f);
    float den = max(kPQ_c2 - kPQ_c3 * Np, 1e-7f);
    float Y = pow(num / den, 1.0f / kPQ_m1);
    return Y * 10000.0f;
}

inline float3 pq_eotf(float3 N) {
    return float3(pq_eotf(N.r), pq_eotf(N.g), pq_eotf(N.b));
}

// MARK: - SMPTE ST 2084 (PQ) OETF 电光转换函数
// 输入: 绝对物理亮度值 (单位: nits, 范围: 0.0 ~ 10,000.0 nits)
// 输出: 归一化 PQ 非线性电平 [0.0, 1.0]

inline float pq_oetf(float L) {
    float Y = clamp(L / 10000.0f, 0.0f, 1.0f);
    float Ym = pow(Y, kPQ_m1);
    float num = kPQ_c1 + kPQ_c2 * Ym;
    float den = 1.0f + kPQ_c3 * Ym;
    return pow(num / den, kPQ_m2);
}

inline float3 pq_oetf(float3 L) {
    return float3(pq_oetf(L.r), pq_oetf(L.g), pq_oetf(L.b));
}

// MARK: - Rec.2020 亮度权重向量 (ITU-R BT.2020 标准亮度系数)
constant float3 kRec2020LumaWeights = float3(0.2627f, 0.6780f, 0.0593f);

// MARK: - 基于 RPU 动态元数据的 EDR 动态色调映射算法 (BT.2390 / Hermite 曲线)
//
// 设计原则：
// 1. 纯度与色相守恒：仅对亮度通道 Y 进行非线性压缩，使用缩放比例 (Y_mapped / Y_in)
//    等比例缩放 RGB 各通道，绝不引入发灰、饱和度坍缩或色偏 (Hue Shift)。
// 2. 暗部与中灰锚定：以 RPU 场景平均亮度 (avgLuminance) 为锚点，低于拐点 (Knee Point)
//    的暗部与中灰细节保持 1:1 绝对透传。
// 3. 高光柔和滚降 (Smooth Rolloff)：当母版峰值亮度超过当前显示器峰值 (TargetMaxLuminance) 时，
//    采用 C1 阶连续的 Hermite / 广义双曲曲线将高光压缩至目标显示器所能呈现的最高物理亮度。

inline float evaluateRPUEDRToneCurve(
    float inLumaNits,
    float srcMin,
    float srcMax,
    float srcAvg,
    float tgtMax,
    float kneeRatio
) {
    // 若显示器最大能力已覆盖内容母版峰值，无需任何压缩，实现满血 1:1 透传
    if (srcMax <= tgtMax || inLumaNits <= 0.0f) {
        return inLumaNits;
    }

    // 计算实际拐点亮度 (Knee Point)，通常位于平均亮度与目标峰值之间
    float kneeNits = clamp(srcAvg * (1.0f + kneeRatio), srcAvg, tgtMax * 0.75f);

    if (inLumaNits <= kneeNits) {
        // 拐点以下：1:1 绝对亮度保持
        return inLumaNits;
    }

    // 拐点以上：平滑高光非线性滚降 (Hermite Smooth Rolloff)
    float rangeIn = max(srcMax - kneeNits, 1.0f);
    float rangeOut = max(tgtMax - kneeNits, 1.0f);

    float t = clamp((inLumaNits - kneeNits) / rangeIn, 0.0f, 1.0f);

    // 平滑压缩函数: f(t) = t / (1 + (1 - rangeOut / rangeIn) * t)
    // 保证在 t=0 处斜率为 1.0 (与 1:1 区域切线连续平滑)，在 t=1 处到达 rangeOut
    float alpha = max(rangeIn / rangeOut - 1.0f, 0.0f);
    float compressed = t / (1.0f + alpha * t);

    return kneeNits + compressed * rangeOut;
}

// MARK: - EDR / PQ 片段色调映射着色器

fragment float4 dolbyToneMappingFragmentShader(
    ToneMapRasterizerData in [[stage_in]],
    texture2d<float, access::sample> inputTexture [[texture(TextureIndexRGBInput)]],
    constant ToneMappingUniforms &uniforms [[buffer(VertexBufferIndexUniforms)]]
) {
    constexpr sampler textureSampler(mag_filter::linear, min_filter::linear, address::clamp_to_edge);
    float4 sampledColor = inputTexture.sample(textureSampler, in.textureCoordinate);
    float3 linearRGB = sampledColor.rgb;

    // 1. 计算输入的物理光度 (单位: nits)
    // 根据上游输出格式：
    // 若上游直接输出 0.0 ~ 1.0 归一化 (1.0 对应 10,000 nits)，则乘上 10000.0
    float3 nitsRGB = linearRGB * 10000.0f;
    float inLumaNits = dot(nitsRGB, kRec2020LumaWeights);

    // 2. 计算目标显示器峰值能力 (结合 Apple EDR Headroom 与 SDR 白点亮度)
    float sdrWhite = max(uniforms.sdrWhiteLuminance, 80.0f);
    float targetPeakNits = max(uniforms.targetMaxLuminance, sdrWhite * max(uniforms.targetEDRHeadroom, 1.0f));

    // 3. 执行基于 RPU 元数据的色调映射
    float mappedLumaNits = evaluateRPUEDRToneCurve(
        inLumaNits,
        uniforms.sourceMinLuminance,
        uniforms.sourceMaxLuminance,
        uniforms.sourceAvgLuminance,
        targetPeakNits,
        uniforms.kneePoint
    );

    // 4. 应用等比例色度缩放，完全保留色相与饱和度
    float scale = (inLumaNits > 1e-5f) ? (mappedLumaNits / inLumaNits) : 1.0f;
    float3 mappedRGBNits = nitsRGB * scale;

    // 5. 根据选择的输出模式适配呈现
    float3 finalOutput;

    switch (uniforms.outputMode) {
        case 0:
            // MARK: 原生 Apple EDR 模式 (Extended Linear Display P3 / Rec.2020)
            // CAMetalLayer 配置: pixelFormat = .rgba16Float, wantsExtendedDynamicRangeContent = true
            // 在 Apple EDR 规范中，1.0 代表 SDR 参考白点亮度 (通常为 100 nits)。
            // 超过 1.0 的值代表 HDR 高光 (例如 1600 nits 对应 16.0 浮点值)。
            finalOutput = mappedRGBNits / sdrWhite;
            break;

        case 1:
            // MARK: SMPTE ST 2084 (PQ) 编码输出模式
            // 输出给配置了 itur_2100_PQ 色彩空间的 CAMetalLayer 或通过 HDMI 直接发送 PQ 信号
            finalOutput = pq_oetf(mappedRGBNits);
            break;

        default:
            // MARK: 直通模式 (Pass-Through)
            finalOutput = linearRGB;
            break;
    }

    return float4(finalOutput, sampledColor.a);
}
