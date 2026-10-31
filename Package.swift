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
        // 语法层：词法 · 语法 · AST。叶子 target，不依赖包内任何其它 target ——
        // 依赖方向由此处强制：谁能 import 谁由 `dependencies` 决定，写不出越界引用。
        .target(
            name: "PiniSyntax",
            path: "Sources/PiniSyntax"
        ),
        .target(
            name: "PiniCore",
            dependencies: ["PiniSyntax"],
            path: "Sources/PiniCore",
            // T1/T11（2026-08-24）：诊断语言资源（Diagnostics.{zh,en}.toml）随 Bundle.module 分发。
            resources: [.process("Resources")]
        ),
        // 运行时 ABI 叶子：不依赖包内任何 target，只 import 系统框架；
        // 生成代码经 C ABI 调用它，编译器侧只在清单里记符号名。
        .target(
            name: "PiniRuntime",
            path: "Sources/PiniRuntime"
        ),
        .executableTarget(
            name: "PiniCLI",
            dependencies: ["PiniCore"],
            path: "Sources/PiniCLI"
        ),
        .testTarget(
            name: "PiniTests",
            dependencies: ["PiniSyntax", "PiniCore", "PiniRuntime"],
            path: "Tests/PiniTests",
            // 夹具（.pini）集中在各套件目录的 Fixtures/ 下。SwiftPM 把目标目录内的非源文件判为
            // unhandled，而 exclude 只能按路径、不能按扩展名 ⇒ 夹具独占一层才排得掉。
            //  注意  路径相对 `path:`（此处即 Tests/PiniTests），不是相对包根 —— 写错只会发
            // `Invalid Exclude ... File not found` 而告警照旧。
            // 此路不通。 不要改用 `resources:` 指向套件目录：那会让目录里的 .swift 不再被编译，
            // 整个套件被静默丢弃（构建仍退出 0、告警也会消失）。
            exclude: [
                "EntryParityTests/Fixtures",
                "GrammarAcceptanceTests/Fixtures",
                "ListDirBuiltinTests/Fixtures",
                "OwnershipLifetimeTests/Fixtures",
                "ReadFileBuiltinTests/Fixtures",
                "ScalarWildcardMatchTests/Fixtures",
                "SplitPathTests/Fixtures",
            ],
        ),
    ],
    swiftLanguageModes: [SwiftLanguageMode.v6]
)
