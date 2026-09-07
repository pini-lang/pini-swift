import XCTest
@testable import PiniCore

/// LLVM 门控单点（约束 5 / LR-1 折中）：
/// 环境已配置（`PINI_LLVM_BIN` 非空或 `llvm-config` 可达）但工具/动态库缺失或失配
/// → 显式失败并报原因；环境未配置 → 保留跳过，但跳过说明单行明示缘由与开启方式。
/// 旧形态 `try XCTSkipUnless(lliAvailable, "lli not available")` 在已配置环境下
/// 会静默跳过（两次假「门关」教训的根因），一律改走本门控。
enum LLVMGate {

    /// LLVM 环境是否已显式配置。
    static var environmentConfigured: Bool {
        if let bin = ProcessInfo.processInfo.environment["PINI_LLVM_BIN"], !bin.isEmpty {
            return true
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["which", "llvm-config"]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do { try process.run() } catch { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    static func requireLLI() throws { try require("lli", LLVMToolchain.lliPath) }
    static func requireClang() throws { try require("clang", LLVMToolchain.clangPath) }

    @discardableResult
    static func requireRuntimeDylib(_ dylib: String?) throws -> String {
        guard let dylib = dylib else {
            throw gateFailureOrSkip(
                tool: "PiniRuntime dylib",
                hint: "build the runtime dynamic library or set PINI_RUNTIME_LIB"
            )
        }
        return dylib
    }

    private static func require(_ tool: String, _ path: String?) throws {
        guard path != nil else {
            throw gateFailureOrSkip(
                tool: tool,
                hint: "set PINI_LLVM_BIN to the LLVM tool directory or install LLVM"
            )
        }
    }

    private static func gateFailureOrSkip(tool: String, hint: String) -> Error {
        if environmentConfigured {
            return NSError(
                domain: "LLVMGate", code: 1,
                userInfo: [NSLocalizedDescriptionKey:
                    "LLVM environment configured (PINI_LLVM_BIN/llvm-config) but \(tool) unavailable — hard failure per gate policy (LR-1); \(hint)"]
            )
        }
        return XCTSkip("skipped: \(tool) unavailable and LLVM environment unconfigured; \(hint)")
    }
}
