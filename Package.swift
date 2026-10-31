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
        // 语义层：诊断 · 内建声明 · 符号表 · 类型检查 · 包清单与源码装载。往上是 IR 与执行，
        // 往下只有语法层；它不认识任何后端。
        .target(
            name: "PiniSemantics",
            dependencies: ["PiniSyntax"],
            path: "Sources/PiniSemantics",
            // T1/T11（2026-08-24）：诊断与语言配置资源（Diagnostics.{zh,en}.toml · LangConfig.toml）
            // 随 Bundle.module 分发，故资源跟随消费它们的这一层，不留在伞 target。
            resources: [.process("Resources")]
        ),
        // 中间表示层：节点 · 布局 · 资源归属分类 · 降载。只认识语义层，不认识发射器。
        .target(
            name: "PiniIR",
            dependencies: ["PiniSemantics"],
            path: "Sources/PiniIR"
        ),
        // 发射层：LLVM 文本生成。只认识 IR 与接缝，不认识其它通道。
        .target(
            name: "PiniBackendLLVM",
            dependencies: ["PiniBackendKit"],
            path: "Sources/PiniBackendLLVM"
        ),
        // 后端接缝：协议 · 能力声明 · 装配表的形状。不认识任何具体通道 —— 认识谁，加一条通道就得改它。
        .target(
            name: "PiniBackendKit",
            dependencies: ["PiniIR"],
            path: "Sources/PiniBackendKit"
        ),
        // 试点通道：embedded_min 字节码，26 条指令。
        .target(
            name: "PiniBackendEmbedded",
            dependencies: ["PiniBackendKit"],
            path: "Sources/PiniBackendEmbedded"
        ),
        // 装配点：全部通道在此登记。放最上层，故通道之间互不认识。
        .target(
            name: "PiniBackends",
            dependencies: ["PiniBackendKit", "PiniBackendLLVM", "PiniBackendEmbedded"],
            path: "Sources/PiniBackends"
        ),
        // 宿主层：解释执行 · 调试协议 · 语言服务 · REPL · 包工具链。它消费编译产物而不生产，
        // 故不在编译管道上，管道也不认识它。
        .target(
            name: "PiniHost",
            dependencies: ["PiniSemantics", "PiniIR"],
            path: "Sources/PiniHost"
        ),
        // 伞 target：只做重导出，不含实现。包外仍 import PiniCore 一处即拿到全部层；
        // 包内各层之间必须显式声明依赖 —— 这就是分层在编译期的形态。
        .target(
            name: "PiniCore",
            dependencies: [
                "PiniSemantics", "PiniIR", "PiniBackendKit", "PiniBackendLLVM",
                "PiniBackendEmbedded", "PiniBackends", "PiniHost",
            ],
            path: "Sources/PiniCore"
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
            // 测试逐层 @testable 引入：伞只重导出 public，看不见 package 与 internal，
            // 而分类表 · 清理栈 · 能力矩阵这些判据恰恰钉在内部约定上。
            dependencies: [
                "PiniSyntax", "PiniSemantics", "PiniIR", "PiniBackendKit", "PiniBackendLLVM",
                "PiniBackendEmbedded", "PiniBackends", "PiniHost", "PiniCore", "PiniRuntime",
            ],
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
