import Foundation

/// Phase 2a（ADR-015 FFI， foreign-decl）：外部 C 函数声明块 `[名称|foreign]`。
///
/// 块内只允许函数签名（无函数体），声明外部 C 函数；块内函数自动视为 `|unsafe`。
/// 不接收内联 ABI 参数，继承模块级 `pini.toml` 设定的 FFI ABI（默认 `"C"`）。
public struct ForeignDecl: Equatable, ASTNode {
 /// 块名（`[libc|foreign]` 的 `libc`）——当前仅作组织名，不参与符号解析。
 public let name: String
 /// 外部函数签名列表（`body == nil`，modifiers 含 `unsafe`）。
 public let funcs: [FuncDecl]
 public let location: SourceLocation

 public init(name: String, funcs: [FuncDecl], location: SourceLocation) {
 self.name = name
 self.funcs = funcs
 self.location = location
 }
}
