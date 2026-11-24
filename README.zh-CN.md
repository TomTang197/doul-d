[English](README.md) | 简体中文

# 🎬 Doul D - macOS 杜比视界外屏透传与高保真播放引擎

> 专为 macOS 设计的高性能杜比视界 (Dolby Vision) 播放与外屏呈现系统，借鉴 Apple TV 4K (tvOS) 处理机制，突破 macOS 外接屏幕的系统色彩限制。

[![Platform](https://img.shields.io/badge/Platform-macOS%2014.0%2B-blue?logo=apple)](https://apple.com)
[![Swift](https://img.shields.io/badge/Swift-6.0%20%7C%20SwiftUI%20%2B%20Metal-orange?logo=swift)](https://swift.org)
[![Rendering](https://img.shields.io/badge/GPU-Metal%2016--bit%20EDR-purple)]()
[![License](https://img.shields.io/badge/License-MIT-green)](LICENSE)

---

## 🌟 核心特性

- **蓝光原盘 Profile 7 实时重构**：解析 HEVC NALU 与 RPU 元数据，将 UHD 蓝光原盘 Profile 7 (FEL / MEL) 实时重写为合法的 Profile 8.1 规范，解决 macOS 播放偏色（发紫发绿）顽疾。
- **流媒体 Profile 5 IPT 色彩矩阵还原**：高精度 Metal 着色器实时解算 IPT → LMS / Rec.2020。
- **LLDV (Low Latency Dolby Vision) 隧道封装**：支持 RGB 4:4:4 伪装隧道封装，兼容外接杜比视界电视握手。
- **Apple EDR 峰值亮度呈现**：利用 16-bit Float `CAMetalLayer` 配合外屏 EDR Headroom 实现满血 HDR 呈现。
- **EDID 杜比块解析与外屏调度**：探测 `CoreDisplay` 显示能力、解析外屏 EDID 杜比视界数据块，管理多屏独立全屏投屏。
- **拖放即播与 MKV 无损流复制**：支持本地 `MP4` / `MOV` / `TS` / `MKV` 文件拖放播放；安装 `ffmpeg` 后，对 MKV 容器自动执行零转码无损流复制（`-c:v copy`）保留完整 HEVC 流与杜比 RPU。

---

## 🛠 模块架构

- `DolbyCore`：HEVC NALU 解析、RPU 元数据提取与 Profile 7 → 8.1 实时重构。
- `DolbyMetal`：Metal 着色器管线、IPT 色彩变换、HDR 色调映射与 LLDV 隧道编码。
- `DolbyDisplay`：外屏 EDID 杜比块解析、EDR Headroom 管理与显示调度器。
- `DoulDApp`：SwiftUI 拖放播放器、动态亮度诊断面板与外屏投屏中枢。

---

## 🚀 构建与运行

### 环境要求
- macOS 14.0 (Sonoma) 或更高版本
- Xcode 16 / Swift 6.0+
- *(可选，用于 `.mkv` 无损解封装)* `brew install ffmpeg`

```bash
git clone https://github.com/TomTang197/doul-d.git
cd doul-d

# 运行单元测试
swift test

# 启动播放器
swift run DoulD
```

---

## 📄 开源许可证

本项目采用 [MIT License](LICENSE) 开源许可证。欢迎提交 Issue 或 Pull Request！
