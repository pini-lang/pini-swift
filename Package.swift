// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "Pini",
    // No platform restriction — supports macOS / Linux / Windows (Swift 5.9+)
    products: [
        .executable(name: "pini", targets: ["PiniCLI"]),
        .library(name: "PiniCore", targets: ["PiniCore"]),
        // ADR-008 阶段1：集合/COW 运行时 shim（Swift 实现，经 @_cdecl 暴露 C ABI）。
        // 动态库产物 libPiniRuntime.{dylib,so} 由 CLI 在 run-llvm / compile 时经
        // `lli --dlopen` / `clang -lPiniRuntime` 加载；CLI 自身不 import 它。
        .library(name: "PiniRuntime", type: .dynamic, targets: ["PiniRuntime"]),
    ],
    targets: [
        .target(
            name: "PiniCore",
            path: "Sources/PiniCore",
            // T1/T11（2026-08-24）：诊断语言资源（Diagnostics.{zh,en}.toml）随 Bundle.module 分发。
            resources: [.process("Resources")],
            // G41（test 块，R5）：tools-version 升 6.2 以启用 SwiftTesting 宿主；现有代码保持 Swift 5 语言模式，避免 Swift 6 严格并发检查引发非预期回归。
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .target(
            name: "PiniRuntime",
            path: "Sources/PiniRuntime",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "PiniCLI",
            dependencies: ["PiniCore"],
            path: "Sources/PiniCLI",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "PiniTests",
            dependencies: ["PiniCore", "PiniRuntime"],
            path: "Tests/PiniTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // #46-E G41（test 块，R5）：SwiftTesting 宿主测试（需 tools-version 6.2+，S0 已升级）。
        // 与既有 XCTest target 共存；默认 Swift 6 语言模式（SwiftTesting 宏在其上最稳）。
        .testTarget(
            name: "PiniSwiftTests",
            dependencies: ["PiniCore", "PiniRuntime"],
            path: "Tests/PiniSwiftTests"
        ),
    ]
)
