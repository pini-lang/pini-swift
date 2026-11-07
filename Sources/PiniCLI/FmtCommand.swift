import Foundation
import PiniHost
import PiniSyntax

/// `pini fmt` 与 `pini expand` 两个出口共用 `Printer`，差别只在跑不跑 pass、传不传注释表。
/// fmt 只到语法：折叠与展开都改写程序，打印跑过 pass 的树就不再是同一份程序的另一种排版。
/// 两个出口都不跳过解析失败——静默跳过会把真错误变成通过。
func runFmtCommand(_ rest: [String]) {
    var write = false
    var check = false
    var paths: [String] = []
    for arg in rest {
        switch arg {
        case "-w", "--write": write = true
        case "--check": check = true
        case "-h", "--help":
            printFmtUsage()
            return
        default:
            guard !arg.hasPrefix("-") else {
                printError("Error: 不认识的选项 \(arg)")
                printFmtUsage(toStderr: true)
                exit(1)
            }
            paths.append(arg)
        }
    }
    guard !paths.isEmpty else {
        printError("Error: fmt 需要至少一个路径")
        printFmtUsage(toStderr: true)
        exit(1)
    }
    guard !(write && check) else {
        printError("Error: --check 与 -w 不能同时给")
        exit(1)
    }
    guard write || check || paths.count == 1 else {
        printError("Error: 多个路径要配 -w 或 --check，否则多份输出在 stdout 上分不清边界")
        exit(1)
    }

    var files: [String] = []
    for path in paths {
        guard let found = collectPiniFiles(path) else { exit(1) }
        guard !found.isEmpty else {
            printError("Error: \(path) 下没有 .pini 文件")
            exit(1)
        }
        files.append(contentsOf: found)
    }

    var dirty: [String] = []
    var failed = false
    for file in files {
        guard let source = readSourceFile(file) else {
            failed = true
            continue
        }
        guard let text = formattedText(source: source, path: file) else {
            failed = true
            continue
        }
        if check {
            if text != source { dirty.append(file) }
        } else if write {
            // 只写有变化的文件：未变的文件连 mtime 都不碰。
            if text != source, !writeSourceFile(text, to: file) { failed = true }
        } else {
            FileHandle.standardOutput.write(Data(text.utf8))
        }
    }

    if check {
        for file in dirty { print(file) }
        if !dirty.isEmpty { exit(1) }
    }
    if failed { exit(1) }
}

/// `pini expand`：打印跑完 pass 清单的树，注释表传空。产物可直接当源文件喂给 `pini run`。
/// 常量折叠也在这条清单里，故字面量运算会以结果形式出现。
func runExpandCommand(_ rest: [String]) {
    if rest.contains("-h") || rest.contains("--help") {
        printExpandUsage()
        return
    }
    guard rest.count == 1, !rest[0].hasPrefix("-") else {
        printError("Error: expand 要且只要一个 .pini 路径")
        printExpandUsage(toStderr: true)
        exit(1)
    }
    let path = rest[0]
    let source: String
    do {
        source = try readFile(path)
    } catch {
        printError("Error: \(error.localizedDescription)")
        exit(1)
    }
    let module = parseOrReport(source: source, fileName: path, withStdlib: false)
    FileHandle.standardOutput.write(Data(Printer.print(module: module).utf8))
}

/// 解析到语法为止再打印。返回 nil 表示已把诊断写到 stderr，调用方只需记一次失败。
private func formattedText(source: String, path: String) -> String? {
    let scan = FrontEnd.syntaxOnly(source: source, fileName: path)
    switch scan.outcome {
    case .parsed(let module):
        return Printer.print(module: module, comments: scan.comments, hints: scan.hints)
    case .lexFailed(let error):
        printError(formatCLIError(error: error, source: source))
        return nil
    case .parseFailed(_, let errors):
        for error in errors {
            printError(ErrorFormatter.formatParserError(error, source: source))
        }
        return nil
    case .expandFailed(let errors):
        // syntaxOnly 不跑 pass；走到这里是前端接线错了，按诊断报出而不是静默继续。
        for error in errors {
            printError(ErrorFormatter.formatDiagnostic(error, source: source))
        }
        return nil
    }
}

/// 文件原样返回；目录递归取 `.pini`，跳过隐藏项与 `.build`。返回 nil 表示路径不存在。
private func collectPiniFiles(_ path: String) -> [String]? {
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else {
        printError("Error: 找不到路径 \(path)")
        return nil
    }
    guard isDirectory.boolValue else { return [path] }
    guard let walker = FileManager.default.enumerator(atPath: path) else { return [] }
    var files: [String] = []
    for case let entry as String in walker {
        guard entry.hasSuffix(".pini") else { continue }
        let hidden = entry.split(separator: "/").contains { $0.hasPrefix(".") || $0 == ".build" }
        guard !hidden else { continue }
        files.append((path as NSString).appendingPathComponent(entry))
    }
    return files.sorted()
}

private func readSourceFile(_ path: String) -> String? {
    do {
        return try String(contentsOf: URL(fileURLWithPath: path), encoding: .utf8)
    } catch {
        printError("Error: 读不了 \(path)：\(error.localizedDescription)")
        return nil
    }
}

/// 原子写回并恢复原权限位。只对已变化的文件调用，未变的文件不碰 mtime。
private func writeSourceFile(_ text: String, to path: String) -> Bool {
    let permissions = try? FileManager.default.attributesOfItem(atPath: path)[.posixPermissions]
    do {
        try Data(text.utf8).write(to: URL(fileURLWithPath: path), options: .atomic)
        if let permissions {
            try FileManager.default.setAttributes(
                [.posixPermissions: permissions], ofItemAtPath: path)
        }
        return true
    } catch {
        printError("Error: 写不了 \(path)：\(error.localizedDescription)")
        return false
    }
}

private func printFmtUsage(toStderr: Bool = false) {
    let lines = [
        "用法: pini fmt [--check | -w] <路径>...",
        "  <路径> 是 .pini 文件或目录；目录递归取 .pini，跳过隐藏项与 .build",
        "  默认打印到 stdout；-w 原地写回；--check 只列需要格式化的文件，有则退出 1",
    ]
    for line in lines {
        if toStderr { printError(line) } else { print(line) }
    }
}

private func printExpandUsage(toStderr: Bool = false) {
    let lines = [
        "用法: pini expand <file.pini>",
        "  打印跑完常量折叠与 unroll 展开的源码；注释不进产物，可直接喂给 pini run",
    ]
    for line in lines {
        if toStderr { printError(line) } else { print(line) }
    }
}
