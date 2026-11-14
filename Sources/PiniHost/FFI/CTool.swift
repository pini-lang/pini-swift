import Foundation

/// C 工具链定位。`Process` 只认绝对路径、不查 PATH，故这里自己找；
/// 两个消费方（宏求值、头文件翻译）共用一处，各找各的迟早分叉。
enum CTool {
    /// 预处理器 / 编译器：`PINI_CC` 优先，其次 PATH 里的 `cc`、`clang`，末位落回 `/usr/bin/cc`。
    /// 只有 `cc` 一处兜底会把只装了 clang 的镜像挡在门外，而 clang 本身就是 C 预处理器。
    static func compilerPath() -> String {
        let environment = ProcessInfo.processInfo.environment
        if let override = environment["PINI_CC"], !override.isEmpty,
            FileManager.default.isExecutableFile(atPath: override)
        {
            return override
        }
        return firstExecutable(named: ["cc", "clang"]) ?? "/usr/bin/cc"
    }

    /// clang：AST JSON 只有 clang 会输出，`cc` 可能是 gcc，故单独找。
    /// `PINI_CLANG` 与 `PINI_CC` 都认，后者用于只装了自家 clang 的镜像。
    static func clangPath() -> String? {
        let environment = ProcessInfo.processInfo.environment
        for key in ["PINI_CLANG", "PINI_CC"] {
            if let value = environment[key], !value.isEmpty,
                FileManager.default.isExecutableFile(atPath: value)
            {
                return value
            }
        }
        return firstExecutable(named: ["clang"])
    }

    /// 按 PATH 顺序找第一个可执行文件。
    private static func firstExecutable(named tools: [String]) -> String? {
        let directories = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":").map(String.init)
        for tool in tools {
            for directory in directories {
                let candidate = (directory as NSString).appendingPathComponent(tool)
                if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
            }
        }
        return nil
    }

    /// 跑一条命令并取回标准输出；非零退出码把命令行与 stderr 一并报上去。
    static func run(
        _ executable: String, _ arguments: [String], stdin: String? = nil
    ) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        if let stdin = stdin {
            let input = Pipe()
            process.standardInput = input
            try process.run()
            input.fileHandleForWriting.write(Data(stdin.utf8))
            try? input.fileHandleForWriting.close()
        } else {
            try process.run()
        }
        let outData = out.fileHandleForReading.readAllData()
        let errData = err.fileHandleForReading.readAllData()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw CToolError.failed(
                command: ([executable] + arguments).joined(separator: " "),
                output: String(decoding: errData, as: UTF8.self))
        }
        return String(decoding: outData, as: UTF8.self)
    }
}

enum CToolError: Error, CustomStringConvertible {
    case failed(command: String, output: String)
    case missing(String)

    var description: String {
        switch self {
        case .failed(let command, let output):
            return "C 工具执行失败：`\(command)`\n\(output)"
        case .missing(let tool):
            return "找不到 \(tool)：它不在 PATH 里，也没有经 PINI_CC / PINI_CLANG 指定"
        }
    }
}
