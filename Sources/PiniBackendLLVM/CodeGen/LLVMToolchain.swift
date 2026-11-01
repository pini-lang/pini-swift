import Foundation

/// 探测 LLVM 工具链（clang / lli / opt）路径，macOS / Linux / Windows 自适应。优先级：
/// 环境变量 `PINI_LLVM_BIN` → `llvm-config --bindir` → PATH 里的 `which <tool>` → Homebrew 标准前缀。
/// 末位兜底的理由：`brew install llvm` 是 keg-only，装完不进 PATH，而报错文案正是教用户这么装。
public struct LLVMToolchain {

    public static var clangPath: String? { resolve("clang") }
    public static var lliPath: String? { resolve("lli") }
    public static var optPath: String? { resolve("opt") }

    /// Homebrew 的两个标准前缀（Apple Silicon 与 Intel）。只在前三级全落空时探一次，
    /// 故不会覆盖用户已经配好的环境变量或 PATH。
    private static let homebrewPrefixes = ["/opt/homebrew/opt/llvm/bin", "/usr/local/opt/llvm/bin"]

    private static func resolve(_ tool: String) -> String? {
        // 1. 显式覆盖
        if let bin = ProcessInfo.processInfo.environment["PINI_LLVM_BIN"],
            !bin.isEmpty
        {
            let candidate = (bin as NSString).appendingPathComponent(tool)
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        // 2. llvm-config --bindir
        if let bindir = runCommand("/usr/bin/env", args: ["llvm-config", "--bindir"]),
            !bindir.isEmpty
        {
            let candidate = (bindir as NSString).appendingPathComponent(tool)
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        // 3. PATH which
        if let which = runCommand("/usr/bin/env", args: ["which", tool]),
            !which.isEmpty,
            FileManager.default.isExecutableFile(atPath: which)
        {
            return which
        }
        // 4. Homebrew 前缀。放在 PATH 之后：PATH 是用户的显式选择，前缀只是填空，不该盖过前者。
        for prefix in Self.homebrewPrefixes {
            let candidate = (prefix as NSString).appendingPathComponent(tool)
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    private static func runCommand(_ executable: String, args: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return nil
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
