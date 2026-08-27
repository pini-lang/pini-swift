import Foundation

// MARK: - 基础类型

/// 断点：文件名 + 行号（1-based）。
public struct Breakpoint: Hashable {
 public let fileName: String
 public let line: Int
 public init(fileName: String, line: Int) {
 self.fileName = fileName
 self.line = line
 }
}

/// 解释器在每条语句执行前咨询调试器后应采取的动作。
public enum DebugAction {
 case run // 继续运行
 case quit // 终止调试会话
}

/// 调试会话终止信号：解释器抛出以中止程序运行。
public enum DebuggerError: Error {
 case quit
}

/// 停止原因：供驱动/适配器区分展示（入口停 / 命中断点 / 单步）。
public enum StopReason {
 case entry
 case breakpoint
 case step
}

/// 停止时调试器向驱动暴露的运行时上下文。
public struct StopEvent {
 public let location: SourceLocation
 public let depth: Int
 public let callStack: [String]
 public let variables: [(name: String, value: String)]

 public init(location: SourceLocation, depth: Int, callStack: [String],
 variables: [(name: String, value: String)]) {
 self.location = location
 self.depth = depth
 self.callStack = callStack
 self.variables = variables
 }
}

/// 调试驱动：在每次停止时提供下一条命令。
/// CLI 实现从 stdin 读取；测试实现用脚本返回。
public protocol DebugDriver {
 /// 返回下一条调试命令。
 mutating func nextCommand(_ event: StopEvent) -> DebugCommand
}

/// 用户在停止点可下达的调试命令。
public enum DebugCommand: Equatable {
 case `continue`
 case stepOver
 case stepIn
 case quit
 case addBreakpoint(fileName: String, line: Int)
 case listBreakpoints
 case printVariable(String)
 case backtrace
}

/// 解释器在挂起时传给调试钩子的上下文。
public struct DebugContext {
 public let location: SourceLocation
 public let depth: Int
 public let callStack: [String]
 public let variables: [(name: String, value: String)]
 public init(location: SourceLocation, depth: Int, callStack: [String],
 variables: [(name: String, value: String)]) {
 self.location = location
 self.depth = depth
 self.callStack = callStack
 self.variables = variables
 }
}

// MARK: - 调试器核心

/// 源码级调试器：管理断点与单步状态，在停止时驱动交互。
///
/// 设计：与 I/O 解耦。断点/单步判定为纯逻辑（可单测）；
/// 交互展示通过 `output` 闭包输出，默认打到 stdout，测试可替换为静默。
public final class Debugger {
 public var breakpoints = Set<Breakpoint>()
 public var sourceMap: SourceMap?

 /// 入口即停：调试会话开始时在首条语句处自动停下，便于先设断点再 `continue`。
 /// 标准调试器行为（类似 gdb 的 stop-at-entry）。CLI 默认开启；单测默认关闭。
 public var stopAtEntry: Bool = false

 /// 输出通道（默认 stdout）。测试可替换为静默以避免噪声。
 public var output: (String) -> Void = { line in print(line) }

 /// 停止回调：每次在断点/单步/入口处停下时触发（供 DAP 适配器发送 stopped 事件）。
 /// 与 `output` 解耦，驱动交互（CLI/test）仍走 `driver.nextCommand`。
 public var onStop: ((StopEvent, StopReason) -> Void)? = nil

 private enum StepMode {
 case over(depth: Int)
 case into
 }
 private var stepMode: StepMode? = nil
 private var driver: DebugDriver

 public init(driver: DebugDriver) {
 self.driver = driver
 }

 /// 断点匹配：运行时 `SourceLocation.fileName` 为全路径，而用户/CLI 输入常为基名
 /// （如 `helper.pini`）。采用「全路径相等 OR 基名相等」容差，二者任一命中即算。
 private func breakpointMatches(_ bp: Breakpoint, _ loc: SourceLocation) -> Bool {
 guard bp.line == loc.line else { return false }
 if bp.fileName == loc.fileName { return true }
 return (loc.fileName as NSString).lastPathComponent == bp.fileName
 }

 /// 解释器每执行一条语句前调用。命中断点/单步条件时进入交互循环，
 /// 返回 `.quit` 表示应终止程序。
 public func consult(_ ctx: DebugContext) throws -> DebugAction {
 let isBreak = breakpoints.contains { breakpointMatches($0, ctx.location) }
 let isStep: Bool = {
 guard let m = stepMode else { return false }
 switch m {
 case .into: return true
 case .over(let d): return ctx.depth <= d
 }
 }()
 let forceStop = stopAtEntry
 if forceStop { stopAtEntry = false }
 guard isBreak || isStep || forceStop else { return .run }

 let event = StopEvent(location: ctx.location, depth: ctx.depth,
 callStack: ctx.callStack, variables: ctx.variables)
 let reason: StopReason = forceStop ? .entry : (isBreak ? .breakpoint : .step)
 onStop?(event, reason)
 printStopBanner(event)

 while true {
 let cmd = driver.nextCommand(event)
 switch cmd {
 case .continue:
 stepMode = nil
 return .run
 case .stepOver:
 stepMode = .over(depth: ctx.depth)
 return .run
 case .stepIn:
 stepMode = .into
 return .run
 case .quit:
 stepMode = nil
 return .quit
 case .addBreakpoint(let f, let l):
 breakpoints.insert(Breakpoint(fileName: f, line: l))
 continue
 case .listBreakpoints:
 printBreakpoints()
 continue
 case .printVariable(let name):
 printVariable(name, event: event)
 continue
 case .backtrace:
 printBacktrace(event: event)
 continue
 }
 }
 }

 // MARK: - 展示

 public func printStopBanner(_ event: StopEvent) {
 if let src = sourceMap?.line(event.location.fileName, event.location.line) {
 output("Stopped at \(event.location.fileName):\(event.location.line)")
 output(" \(event.location.line): \(src)")
 } else {
 output("Stopped at \(event.location.fileName):\(event.location.line)")
 }
 }

 private func printBreakpoints() {
 if breakpoints.isEmpty {
 output(" (no breakpoints)")
 return
 }
 let sorted = breakpoints.sorted {
 $0.fileName < $1.fileName || ($0.fileName == $1.fileName && $0.line < $1.line)
 }
 for b in sorted {
 output(" break at \(b.fileName):\(b.line)")
 }
 }

 private func printVariable(_ name: String, event: StopEvent) {
 if let v = event.variables.first(where: { $0.name == name }) {
 output(" \(name) = \(v.value)")
 } else {
 output(" (no variable named '\(name)')")
 }
 }

 private func printBacktrace(event: StopEvent) {
 for (i, frame) in event.callStack.enumerated() {
 output(" #\(i) \(frame)")
 }
 }
}
