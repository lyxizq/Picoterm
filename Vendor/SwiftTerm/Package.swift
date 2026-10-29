// swift-tools-version: 6.0
import PackageDescription

// Picoterm vendored SwiftTerm（上游 migueldeicaza/SwiftTerm v1.99.0，MIT，LICENSE 同目录）。
// 为「终端搜索高亮全部匹配」本地扩展而 vendored；只保留 macOS 需要的单 target，
// 上游的构建插件（git 版本号生成）、WASM/嵌入式 traits、文档与 CLI 不随行，
// 版本常量由 Sources/SwiftTerm/SwiftTermBuildInfoVendored.swift 提供。
let package = Package(
    name: "SwiftTerm",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "SwiftTerm", targets: ["SwiftTerm"])
    ],
    targets: [
        .target(
            name: "SwiftTerm",
            path: "Sources/SwiftTerm",
            exclude: [
                "Documentation.docc",
                "Mac/README.md",
                "Apple/Metal/Shaders.metal",
            ]
        )
    ]
)
