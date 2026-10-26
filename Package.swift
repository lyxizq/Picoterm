// swift-tools-version: 6.0
import PackageDescription

// libssh2 走 SPM 二进制包（AkinoKaede/libssh2-spm，MIT：CI 构建的 XCFramework，
// 静态链接 openssl——不依赖 brew，产物天然自包含，不再需要 make-app 收集 dylib）
// SwiftTerm 为 vendored 本地副本（Vendor/SwiftTerm，上游 v1.99.0 MIT）：
// 为终端搜索「高亮全部匹配」做了本地扩展，升级上游需手工同步
let package = Package(
    name: "Picoterm",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "Picoterm", targets: ["Picoterm"])
    ],
    dependencies: [
        .package(path: "Vendor/SwiftTerm"),
        .package(url: "https://github.com/AkinoKaede/libssh2-spm.git", from: "2.0.3-termind-4"),
    ],
    targets: [
        // 纯逻辑核心（无 AppKit 依赖）：SSH 字符集等可单测模块；iconv 需显式链接
        .target(
            name: "PicotermCore",
            path: "Sources/PicotermCore",
            linkerSettings: [.linkedLibrary("iconv")]
        ),
        .executableTarget(
            name: "Picoterm",
            dependencies: [
                .product(name: "SwiftTerm", package: "SwiftTerm"),
                .product(name: "CSSH2", package: "libssh2-spm"),
                "PicotermCore",
            ],
            path: "Sources/Picoterm",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // 自跑单测可执行（CLT 的 swift-testing 宏插件加载不稳定，见记忆）：swift run PicotermCoreTests
        .executableTarget(
            name: "PicotermCoreTests",
            dependencies: ["PicotermCore"],
            path: "Tests/PicotermCoreTests"
        ),
    ]
)
