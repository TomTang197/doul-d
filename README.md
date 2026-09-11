# Doul D - macOS 杜比视界外屏透传与高保真播放引擎

Doul D 是一个专为 macOS 设计的高性能杜比视界 (Dolby Vision) 播放与外屏呈现系统。借鉴 Apple TV 4K (tvOS) 的处理机制，突破 macOS 外接屏幕的系统色彩限制。

## 核心特性
- **蓝光原盘 Profile 7 实时重构**：将 UHD 蓝光原盘 Profile 7 (FEL/MEL) 实时重写为合法的 Profile 8.1 规范，解决偏色（发紫发绿）顽疾。
- **流媒体 Profile 5 IPT 色彩矩阵还原**：高精度着色器解算 IPT to LMS/Rec.2020。
- **LLDV (Low Latency Dolby Vision) 隧道封装**：支持 RGB 4:4:4 伪装隧道封装，兼容外接电视杜比握手。
- **Apple EDR 峰值亮度呈现**：利用 CAMetalLayer 16-bit Float 配合外屏 EDR Headroom 实现满血 HDR 呈现。
- **tvOS 机制借鉴与 CoreDisplay 探测**：探测系统私有显示能力，管理多屏独立全屏投屏。

## 模块架构
- `DolbyCore`: NALU 解析、RPU 提取与 Profile 7 -> 8.1 重构。
- `DolbyMetal`: Metal 着色器管线、IPT 色彩变换与 LLDV 隧道编码器。
- `DolbyDisplay`: 外屏 EDID 杜比块解析与显示调度器。
- `DoulDApp`: SwiftUI 播放器与投屏中枢。
