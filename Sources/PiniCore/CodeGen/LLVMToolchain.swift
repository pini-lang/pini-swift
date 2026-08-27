import Foundation

/// 探测 LLVM 工具链（clang / lli / opt）路径。
///
/// 优先级：
/// 1. 环境变量 `PINI_LLVM_BIN`（指向含工具的目录）
/// 2. `llvm-config --bindir`
/// 3. PATH 中的 `which <tool>`
///
/// 这样 P6 后端不再依赖任何硬编码路径，可在 macOS / Linux / Windows 上自适应。
public struct LLVMToolchain {

 public static var clangPath: String? { resolve("clang") }
 public static var lliPath: String? { resolve("lli") }
 public static var optPath: String? { resolve("opt") }

 private static func resolve(_ tool: String) -> String? {
 // 1. 显式覆盖
 if let bin = ProcessInfo.processInfo.environment["PINI_LLVM_BIN"],
 !bin.isEmpty {
 let candidate = (bin as NSString).appendingPathComponent(tool)
 if FileManager.default.isExecutableFile(atPath: candidate) {
 return candidate
 }
 }
 // 2. llvm-config --bindir
 if let bindir = runCommand("/usr/bin/env", args: ["llvm-config", "--bindir"]),
 !bindir.isEmpty {
 let candidate = (bindir as NSString).appendingPathComponent(tool)
 if FileManager.default.isExecutableFile(atPath: candidate) {
 return candidate
 }
 }
 // 3. PATH which
 if let which = runCommand("/usr/bin/env", args: ["which", tool]),
 !which.isEmpty,
 FileManager.default.isExecutableFile(atPath: which) {
 return which
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
