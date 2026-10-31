import Foundation

/// 测试面的仓根与命令行产物定位。仓根由「向上找到 Package.swift」确定，不按 `#filePath` 数层数 ——
/// 数层数在顶层套件成立、在子目录套件少一层，症状是仓内明明有产物却记一条「未找到」。
enum PiniTestEnvironment {

    static let repositoryRoot: URL = {
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while directory.path != "/" {
            let manifest = directory.appendingPathComponent("Package.swift")
            if FileManager.default.fileExists(atPath: manifest.path) { return directory }
            directory.deleteLastPathComponent()
        }
        return URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    }()

    /// 仓内构建产物，按优先序。只给路径、不验可执行：调用方要自己区分「没有产物」与
    /// 「产物早于某个内建」两种情形。
    static var repositoryCLICandidates: [String] {
        ["/.build/debug/pini", "/.build/out/Products/Debug/pini"]
            .map { repositoryRoot.path + $0 }
    }

    /// 环境变量优先，其次仓内第一份可执行产物；都没有时 nil，由调用方决定怎么响亮跳过。
    static func cliPath() -> String? {
        let fromEnvironment = ProcessInfo.processInfo.environment["PINI_CLI_BIN"] ?? ""
        if !fromEnvironment.isEmpty, FileManager.default.isExecutableFile(atPath: fromEnvironment) {
            return fromEnvironment
        }
        return repositoryCLICandidates.first {
            FileManager.default.isExecutableFile(atPath: $0)
        }
    }
}
