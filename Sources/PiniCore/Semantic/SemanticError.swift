import Foundation

/// 语义分析错误
public enum SemanticError: Error, Equatable {
 case undefinedVariable(name: String, location: SourceLocation)
 case undefinedFunction(name: String, location: SourceLocation)
 case undefinedType(name: String, location: SourceLocation)
 case redeclaredSymbol(name: String, location: SourceLocation)
 /// 跨文件可见性违规：引用了定义在其他文件中、且按 4 级可见性不可见的符号。
 /// `definedIn` 为定义所在源文件，`level` 为该符号的可见性级别。
 case inaccessibleSymbol(name: String, definedIn: String, level: VisibilityLevel, location: SourceLocation)
 /// validated 匹配模式（由 match 通配子块触发）下，出现了非任何已知枚举 case 的模式名
 ///（与同 match 内已解析的合法 case 并存时视为拼写错误）。`caseName` 为未识别的模式。
 case unknownMatchCase(caseName: String, location: SourceLocation)
 /// validated 匹配模式（由 match 通配子块触发）下，所有 case 映射到同一枚举但覆盖不全，
 /// 且无通配子块/default 兜底。`missingCases` 为未覆盖的 case 名列表。
 case nonExhaustiveMatch(missingCases: [String], location: SourceLocation)
 /// H-1①（2026-08-31）：匿名函数体内引用了外层局部变量，但其 `capture` 声明
 /// 尚未在此前语句序上出现（偏弱纯定位：闭包显式声明捕获，先声明后使用）。
 case captureWithoutDeclaration(name: String, location: SourceLocation)
 /// H-1②：capture 的目标不是创建点外层的局部变量
 ///（本匿名函数参数/体内已声明局部/内建或函数名/`self`/创建点不可见名）。
 case invalidCaptureTarget(name: String, reason: String, location: SourceLocation)
 /// H-3/G52 批 1（2026-08-31）：模块依赖环（R2：import 即依赖，依赖图禁环）。
 case moduleDependencyCycle(chain: [String])
 /// G52 批 1：被引入模块的根目录缺失 `pini.toml` 或源文件（R1 物理边界）。
 case moduleRootMissing(path: String)
 /// G52 批 1（D8）：跨模块引入门槛 = 仅 public——非 public 符号经 `别名.符号` 访问被拒。
 case crossModuleAccessDenied(symbol: String, location: SourceLocation)
 /// 批 6 D-4：注入冲突——`_别名` 隐式注入的 public 符号与本文件既有可裸引用名相撞
 /// （本地顶级/局部声明、其他注入、显式别名、内建）。`holder` 描述冲突双方。
 case injectedSymbolConflict(symbol: String, holder: String, location: SourceLocation)
}
