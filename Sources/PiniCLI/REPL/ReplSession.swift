import Foundation
import PiniCore
import PiniHost

// REPL：交互循环 + 续行检测 + 特殊命令。求值（声明累积、表达式包装、跑哪个引擎）在
// `PiniCore` 的 `ReplEvaluator`——本类只保留交互那一半，故不绑引擎、可被测试 target 覆盖。
// 本类职责：续行检测、`:quit`/`:help`/`:clear`、错误恢复。
final class ReplSession {

    /// 求值核：承担「输入 → 跑一段程序」。
    private let evaluator: ReplEvaluator

    init(evaluator: ReplEvaluator = ReplEvaluator()) {
        self.evaluator = evaluator
    }

    /// 续行提示符。
    private static let promptMain = ">> "
    private static let promptCont = "... "

    // MARK: - 入口

    func run() {
        print("Pini REPL (P7-1). 输入表达式或声明；:help 查看帮助，:quit 退出。")
        var linesBuffer: [String] = []

        while true {
            let prompt = linesBuffer.isEmpty ? Self.promptMain : Self.promptCont
            print(prompt, terminator: "")
            // fflush(nil) 冲刷全部流：Glibc 的 stdout 是可变全局量，直接引用按共享可变状态判错。
            fflush(nil)

            guard let line = readLine() else { print(); break }  // ctrl+d → exit

            // 空行：若已有累积缓冲 → 提交；否则忽略
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                if linesBuffer.isEmpty { continue }
                // 空行结束多行输入
                try? evaluate(linesBuffer)
                linesBuffer.removeAll()
                continue
            }

            // 特殊命令（仅在缓冲为空时生效）
            if linesBuffer.isEmpty {
                if trimmed.hasPrefix(":") {
                    if handleSpecialCommand(trimmed) { return }  // :quit
                    continue
                }
                // 整行注释忽略
                if trimmed.hasPrefix(";") { continue }
            }

            linesBuffer.append(line)

            // 续行检测
            if needsContinuation(accumulated: linesBuffer) { continue }

            // 提交
            do {
                try evaluate(linesBuffer)
            } catch {
                print("错误: \(error.localizedDescription)")
            }
            linesBuffer.removeAll()
        }
    }

    // MARK: - 求值

    private func evaluate(_ lines: [String]) throws {
        try evaluator.evaluate(lines)
    }

    // MARK: - 续行检测

    // 判断当前累积行是否需要继续读取：括号未闭合 `() [] {} <>`、INDENT 块（`:` 结尾的非注释行
    // 之后还有缩进或空行）、反斜杠续行。Pini 没有 compile('single') 模式，故用缩进检测近似：
    // 以 `:` 结尾的语句后只要下一行有缩进就继续累积，直到遇到无缩进的非空行。
    private func needsContinuation(accumulated lines: [String]) -> Bool {
        guard let last = lines.last else { return false }
        let trimmed = last.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            // 空行：如果已有 INDENT 块且 next would be more → could go either way
            // 保守策略：空行不改变续行状态，回退到 INDENT 块检测
        }

        // 反斜杠续行
        if trimmed.hasSuffix("\\") { return true }

        // 括号平衡检测
        var parens = 0
        for line in lines {
            for ch in line {
                switch ch {
                case "(", "[", "{", "<": parens += 1
                case ")", "]", "}", ">": parens -= 1
                default: break
                }
            }
        }
        if parens != 0 { return true }

        // INDENT 块检测：找到最后一个 `:` 结尾的非注释行
        var colonLineIdx: Int? = nil
        for (i, line) in lines.enumerated().reversed() {
            let code = stripComment(line.trimmingCharacters(in: .whitespaces))
            if code.hasSuffix(":") && !code.isEmpty {
                colonLineIdx = i
                break
            }
        }

        guard let colonIdx = colonLineIdx else { return false }

        // `:` 之后的行必须缩进才算续行
        // DEBUG
        var allIndented = true
        for i in (colonIdx + 1)..<lines.count {
            let line = lines[i]
            if line.trimmingCharacters(in: .whitespaces).isEmpty { continue }
            if line.first?.isWhitespace == true { continue }
            allIndented = false
            break
        }
        if !allIndented { return false }
        // DEBUG
        return true
    }

    /// 剥离行尾 `;` 注释。
    private func stripComment(_ line: String) -> String {
        // 简单规则：找第一个不在字符串内的 `;`
        var inString = false
        var stringChar: Character? = nil
        for (i, ch) in line.enumerated() {
            if inString {
                if ch == stringChar { inString = false; stringChar = nil }
            } else if ch == "\"" || ch == "'" {
                inString = true; stringChar = ch
            } else if ch == ";" {
                return String(line.prefix(i))
            }
        }
        return line
    }

    // MARK: - 特殊命令

    /// 返回 true 表示退出 REPL。
    private func handleSpecialCommand(_ input: String) -> Bool {
        let cmd = input.dropFirst().lowercased()  // 去掉 `:`
        switch cmd {
        case "q", "quit", "exit":
            print("Goodbye.")
            return true
        case "h", "help":
            print(
                """
                Pini REPL 特殊命令：
                :quit, :q 退出 REPL
                :help, :h 打印此帮助
                :clear 清除累积的声明（重置会话）

                支持多行输入——括号未闭合或 `:` 结尾时自动续行。
                空行（或 ctrl+d）结束多行输入并提交。

                声明类型（func/struct/object/enum/trait）会累积到会话中。
                """)
        case "clear":
            evaluator.reset()
            print("会话已重置：累积的声明已清除。")
        default:
            print("未知命令：\(input)。输入 :help 查看帮助。")
        }
        return false
    }
}
