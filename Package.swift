// swift-tools-version:6.4
import PackageDescription

let package = Package(
    name: "Pini",
    products: [
        .executable(name: "pini", targets: ["PiniCLI"]),
        .library(name: "PiniCore", targets: ["PiniCore"]),
        // 并发后端抽象 阶段1：集合/COW 运行时 shim（Swift 实现，经 @_cdecl 暴露 C ABI）。
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
            // 夹具（.pini）集中在各套件目录的 Fixtures/ 下。SwiftPM 把目标目录内的非源文件判为
            // unhandled，而 exclude 只能按路径、不能按扩展名 ⇒ 夹具独占一层才排得掉。
            // ⚠️ 路径相对 `path:`（此处即 Tests/PiniTests），不是相对包根 —— 写错只会发
            // `Invalid Exclude ... File not found` 而告警照旧。
            // ⛔ 不要改用 `resources:` 指向套件目录：那会让目录里的 .swift 不再被编译，
            // 整个套件被静默丢弃（构建仍退出 0、告警也会消失）。
            exclude: ["GrammarAcceptanceTests/Fixtures", "ListDirBuiltinTests/Fixtures"],
        ),
    ],
    swiftLanguageModes: [SwiftLanguageMode.v6]
)
