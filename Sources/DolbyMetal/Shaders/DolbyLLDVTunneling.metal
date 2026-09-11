#include <metal_stdlib>
#include "ShaderTypes.h"

using namespace metal;

// MARK: - 顶点输出结构

struct TunnelRasterizerData {
    float4 clipSpacePosition [[position]];
    float2 textureCoordinate;
};

// MARK: - LLDV 隧道封装顶点着色器

vertex TunnelRasterizerData dolbyLLDVTunnelVertexShader(
    uint vertexID [[vertex_id]],
    constant Vertex2D *vertices [[buffer(VertexBufferIndexVertices)]]
) {
    TunnelRasterizerData out;
    out.clipSpacePosition = float4(vertices[vertexID].position, 0.0, 1.0);
    out.textureCoordinate = vertices[vertexID].texCoords;
    return out;
}

// MARK: - Dolby Vision LLDV / Standard RGB 4:4:4 伪装隧道封装片段着色器
//
// 核心原理 (借鉴 Apple TV tvOS 与 Dolby US Patent 9,906,765 B2 规范)：
// 杜比视界高精度色彩通常以 12-bit YCbCr 4:2:2 存储或计算。
// 受限于部分 HDMI 2.0 / 1.4 传输带宽或 macOS 外部显示器色彩协商限制，
// 将每组水平相邻的 2 个像素 (共 48-bit 信息: 12-bit Y0 + 12-bit Y1 + 12-bit Cb + 12-bit Cr)
// 巧妙位重排至标准 8-bit RGB 4:4:4 容器 (2 个像素 × 24-bit = 48-bit)：
//
// [偶数像素 x = 2k]:
//   - G 通道 = Y0[11:4]   (8-bit 亮度高位)
//   - R 通道 = Cb[11:4]   (8-bit 蓝色色度高位)
//   - B 通道 = (Cb[3:0] << 4) | Y0[3:0] (低 4 位交织打包)
//
// [奇数像素 x = 2k+1]:
//   - G 通道 = Y1[11:4]   (8-bit 亮度高位)
//   - R 通道 = Cr[11:4]   (8-bit 红色色度高位)
//   - B 通道 = (Cr[3:0] << 4) | Y1[3:0] (低 4 位交织打包)
//
// 接收端显示器 (如 LG OLED, Sony Bravia, TCL 等支持杜比视界的电视)
// 在收到 HDMI AVI InfoFrame / 杜比 VSVDB 握手信号后，自动解包并完美还原 12-bit YCbCr 信号，
// 强制点亮杜比视界 (Dolby Vision) 专属画质模式！

fragment float4 dolbyLLDVTunnelFragmentShader(
    TunnelRasterizerData in [[stage_in]],
    texture2d<float, access::read> lumaTexture [[texture(TextureIndexLuma)]],
    texture2d<float, access::read> chromaTexture [[texture(TextureIndexChroma)]],
    constant LLDVTunnelUniforms &uniforms [[buffer(VertexBufferIndexUniforms)]]
) {
    // 采用离散无插值整型像素坐标读取，避免任何浮点线性插值破坏位打包精度
    uint2 pixelCoord = uint2(in.clipSpacePosition.xy);
    uint pixelX = pixelCoord.x;
    uint pixelY = pixelCoord.y;

    // 边界安全防护
    if (pixelX >= uniforms.frameWidth || pixelY >= uniforms.frameHeight) {
        return float4(0.0f, 0.0f, 0.0f, 1.0f);
    }

    bool isEven = ((pixelX & 1u) == 0u);

    // 1. 读取当前像素的 12-bit 归一化亮度 Y (P010 / 10-bit / 16-bit 线性映射至 12-bit 整数 [0, 4095])
    float y_sample = lumaTexture.read(pixelCoord).r;
    uint y_12bit = clamp(uint(round(y_sample * 4095.0f)), 0u, 4095u);

    // 2. 读取当前 4:2:2 像素对的色度 Cb 与 Cr (4:2:2 水平下采样 2:1)
    uint chromaX = pixelX >> 1u;
    float2 uv_sample = chromaTexture.read(uint2(chromaX, pixelY)).rg;
    uint cb_12bit = clamp(uint(round(uv_sample.r * 4095.0f)), 0u, 4095u);
    uint cr_12bit = clamp(uint(round(uv_sample.g * 4095.0f)), 0u, 4095u);

    if (uniforms.outputBitDepth == 8u) {
        // MARK: - 标准 8-bit RGB 4:4:4 隧道打包
        uint outR = 0u;
        uint outG = 0u;
        uint outB = 0u;

        // 提取 12-bit 样本的 High-8 (bits 11..4) 与 Low-4 (bits 3..0)
        uint y_hi8  = (y_12bit  >> 4u) & 0xFFu;
        uint y_lo4  =  y_12bit         & 0x0Fu;

        if (isEven) {
            // 偶数像素 (携带 Y0 与 Cb)
            uint cb_hi8 = (cb_12bit >> 4u) & 0xFFu;
            uint cb_lo4 =  cb_12bit        & 0x0Fu;

            outG = y_hi8;
            outR = cb_hi8;

            if (uniforms.bitReorderMode == 0u) {
                // 默认 Dolby 专利对齐: B[7:4] = Cb[3:0], B[3:0] = Y0[3:0]
                outB = (cb_lo4 << 4u) | y_lo4;
            } else {
                // 备选对齐: B[7:4] = Y0[3:0], B[3:0] = Cb[3:0]
                outB = (y_lo4 << 4u) | cb_lo4;
            }
        } else {
            // 奇数像素 (携带 Y1 与 Cr)
            uint cr_hi8 = (cr_12bit >> 4u) & 0xFFu;
            uint cr_lo4 =  cr_12bit        & 0x0Fu;

            outG = y_hi8;
            outR = cr_hi8;

            if (uniforms.bitReorderMode == 0u) {
                // 默认 Dolby 专利对齐: B[7:4] = Cr[3:0], B[3:0] = Y1[3:0]
                outB = (cr_lo4 << 4u) | y_lo4;
            } else {
                // 备选对齐: B[7:4] = Y1[3:0], B[3:0] = Cr[3:0]
                outB = (y_lo4 << 4u) | cr_lo4;
            }
        }

        // 输出为 [0.0, 1.0] 的 8-bit 无损归一化颜色值，由渲染管线写入 RGBA8 目标缓冲区
        return float4(
            float(outR) / 255.0f,
            float(outG) / 255.0f,
            float(outB) / 255.0f,
            1.0f
        );

    } else {
        // MARK: - 10-bit RGB 4:4:4 隧道封装模式
        // 用于支持 10-bit 直接通道传输的外接设备
        uint outR10 = 0u;
        uint outG10 = 0u;
        uint outB10 = 0u;

        uint y_hi10 = (y_12bit >> 2u) & 0x3FFu;
        uint y_lo2  =  y_12bit        & 0x03u;

        if (isEven) {
            uint cb_hi10 = (cb_12bit >> 2u) & 0x3FFu;
            uint cb_lo2  =  cb_12bit        & 0x03u;

            outG10 = y_hi10;
            outR10 = cb_hi10;
            outB10 = (cb_lo2 << 8u) | (y_lo2 << 6u);
        } else {
            uint cr_hi10 = (cr_12bit >> 2u) & 0x3FFu;
            uint cr_lo2  =  cr_12bit        & 0x03u;

            outG10 = y_hi10;
            outR10 = cr_hi10;
            outB10 = (cr_lo2 << 8u) | (y_lo2 << 6u);
        }

        return float4(
            float(outR10) / 1023.0f,
            float(outG10) / 1023.0f,
            float(outB10) / 1023.0f,
            1.0f
        );
    }
}
