English | [简体中文](README.zh-CN.md)

# 🎬 Doul D

> **High-fidelity Dolby Vision playback & external display passthrough engine for macOS.**  
> Inspired by Apple TV 4K (`tvOS`) display pipelines, Doul D brings real-time Profile 7 → 8.1 RPU reconstruction, Profile 5 IPT color restoration, LLDV RGB 4:4:4 tunneling, and 16-bit Float Metal EDR rendering to macOS external displays.

[![Platform](https://img.shields.io/badge/Platform-macOS%2014.0%2B-blue?logo=apple)](https://apple.com)
[![Swift](https://img.shields.io/badge/Swift-6.0%20%7C%20SwiftUI%20%2B%20Metal-orange?logo=swift)](https://swift.org)
[![Rendering](https://img.shields.io/badge/GPU-Metal%2016--bit%20EDR-purple)]()
[![License](https://img.shields.io/badge/License-MIT-green)](LICENSE)

---

## 🌟 Key Features

- **Real-Time Blu-ray Profile 7 Reconstruction**: Parses HEVC NALUs and rewrites UHD Blu-ray Dolby Vision Profile 7 (FEL / MEL) RPU metadata on the fly into valid Profile 8.1 streams, eliminating the green/purple color-shift artifacts commonly seen on macOS.
- **Streaming Profile 5 IPT Color Restoration**: Dedicated Metal compute/fragment shaders decode proprietary IPT color space directly into LMS / Rec.2020 with high precision.
- **LLDV (Low Latency Dolby Vision) Tunneling**: Encodes Player-Led Dolby Vision over RGB 4:4:4 tunneling for external Dolby Vision-capable TVs and monitors.
- **Apple EDR Peak Luminance Rendering**: Renders through a 16-bit Float `CAMetalLayer` synchronized with external display EDR headroom for full-range HDR output.
- **EDID Dolby Block Parsing & External Display Coordination**: Parses display EDID Dolby Vision Vendor-Specific Video Data Blocks (VSVDB), probes `CoreDisplay` capabilities, and manages dedicated full-screen external presentation.
- **Drag-and-Drop Local Playback + Lossless MKV Remuxing**: Drag and drop local `MP4`, `MOV`, `TS`, or `MKV` files directly into the player. When `ffmpeg` is installed, MKV files are automatically losslessly remuxed (`-c:v copy`) to preserve HEVC streams and Dolby Vision RPUs with zero video transcoding.

---

## 🛠 Architecture

```text
.
├── Sources/
│   ├── DolbyCore/                    # HEVC NALU parser, RPU metadata extraction & Profile 7 -> 8.1 rewriter
│   │   ├── CMSampleBuffer+Dolby.swift
│   │   ├── DolbyProfile.swift
│   │   ├── NALUParser.swift
│   │   ├── RPUMetadata.swift
│   │   └── RPUProcessor.swift
│   │
│   ├── DolbyMetal/                   # Metal rendering pipeline & custom Dolby Vision shaders
│   │   ├── DVMetalLayerConfig.swift
│   │   ├── DVMetalRenderer.swift
│   │   ├── ShaderTypes.swift
│   │   └── Shaders/
│   │       ├── DolbyIPTToRGB.metal
│   │       ├── DolbyLLDVTunneling.metal
│   │       ├── DolbyToneMapping.metal
│   │       └── ShaderTypes.h
│   │
│   ├── DolbyDisplay/                 # External display EDID Dolby block parser, EDR & CoreDisplay bridge
│   │   ├── CoreDisplayBridge.swift
│   │   ├── DisplayEDRManager.swift
│   │   ├── EDIDParser.swift
│   │   └── ExternalDisplayCoordinator.swift
│   │
│   └── DoulDApp/                     # SwiftUI drag-and-drop player, live telemetry & presentation hub
│       ├── DoulDApp.swift
│       ├── ContentView.swift
│       ├── MetalVideoView.swift
│       └── PlaybackEngine.swift
│
└── Tests/
    ├── DolbyDisplayTests/            # EDID & external display evaluation tests
    └── DoulDTests/                   # DolbyCore RPU & DolbyMetal pipeline tests
```

---

## 🚀 Build & Run

### Prerequisites
- macOS 14.0 (Sonoma) or later
- Xcode 16 / Swift 6.0+ toolchain
- *(Optional, recommended for `.mkv` playback)* `ffmpeg` via Homebrew (`brew install ffmpeg`)

### Run & Test
```bash
# 1. Clone the repository
git clone https://github.com/TomTang197/doul-d.git
cd doul-d

# 2. Run unit tests
swift test

# 3. Build and launch the SwiftUI player
swift run DoulD
```

You can also open `Package.swift` directly in Xcode to build and run the `DoulD` scheme.

---

## 📄 License

This project is open-sourced under the [MIT License](LICENSE). Issues and Pull Requests are welcome!
