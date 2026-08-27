import Foundation

/// 补全提供器：根据光标位置返回当前作用域的符号候选项。
public struct CompletionProvider {

 /// 返回当前位置的补全列表
 public func complete(
 in scope: Scope?,
 includingKeywords: Bool = true
 ) -> CompletionList {
 var items: [CompletionItem] = []

 // 1. 当前作用域符号
 if let scope = scope {
 for sym in scope.allSymbolsRecursive() {
 items.append(mapSymbol(sym))
 }
 }

 // 2. 语言关键字
 if includingKeywords {
 items.append(contentsOf: keywords)
 }

 // 3. 内置类型
 items.append(contentsOf: builtinTypes)

 return CompletionList(isIncomplete: false, items: items)
 }

 /// 符号映射到 LSP CompletionItem
 private func mapSymbol(_ sym: Symbol) -> CompletionItem {
 let kind = mapKind(sym.kind)
 let detail = detailFor(sym)
 return CompletionItem(
 label: sym.name,
 kind: kind,
 detail: detail
 )
 }

 private func mapKind(_ k: SymbolKind) -> CompletionItemKind {
 switch k {
 case .function: return .function
 case .variable: return .variable
 case .struct: return .struct
 case .object: return .class
 case .enum: return .enum
 case .enumCase: return .enumMember
 case .trait: return .interface
 case .parameter: return .variable
 }
 }

 private func detailFor(_ sym: Symbol) -> String? {
 switch sym.kind {
 case .function: return "fn"
 case .variable(let mutable): return mutable ? "var" : "val"
 case .struct: return "struct"
 case .object: return "object"
 case .enum: return "enum"
 case .enumCase: return "case"
 case .trait: return "trait"
 case .parameter: return "param"
 }
 }
}

// MARK: - Static Data

private let keywords: [CompletionItem] = [
 CompletionItem(label: "let", kind: .keyword, detail: "不可变变量"),
 CompletionItem(label: "var", kind: .keyword, detail: "可变变量"),
 CompletionItem(label: "if", kind: .keyword, detail: "条件分支"),
 CompletionItem(label: "elif", kind: .keyword, detail: "否则如果"),
 CompletionItem(label: "else", kind: .keyword, detail: "否则"),
 CompletionItem(label: "match", kind: .keyword, detail: "模式匹配"),
 CompletionItem(label: "case", kind: .keyword, detail: "匹配分支"),
 CompletionItem(label: "while", kind: .keyword, detail: "循环"),
 CompletionItem(label: "step", kind: .keyword, detail: "while 步进块（每轮后执行）"),
 CompletionItem(label: "nil", kind: .keyword, detail: "Optional.none 等效常量"),
 CompletionItem(label: "return", kind: .keyword, detail: "返回"),
 CompletionItem(label: "break", kind: .keyword, detail: "跳出"),
 CompletionItem(label: "continue", kind: .keyword, detail: "继续"),
 CompletionItem(label: "try", kind: .keyword, detail: "尝试"),
 CompletionItem(label: "except", kind: .keyword, detail: "异常处理"),
 CompletionItem(label: "lambda", kind: .keyword, detail: "匿名函数"),
 CompletionItem(label: "import", kind: .keyword, detail: "导入"),
 CompletionItem(label: "export", kind: .keyword, detail: "导出"),
]

private let builtinTypes: [CompletionItem] = [
 CompletionItem(label: "I8", kind: .struct, detail: "有符号8位整数"),
 CompletionItem(label: "I16", kind: .struct, detail: "有符号16位整数"),
 CompletionItem(label: "I32", kind: .struct, detail: "有符号32位整数"),
 CompletionItem(label: "I64", kind: .struct, detail: "有符号64位整数"),
 CompletionItem(label: "U8", kind: .struct, detail: "无符号8位整数"),
 CompletionItem(label: "U16", kind: .struct, detail: "无符号16位整数"),
 CompletionItem(label: "U32", kind: .struct, detail: "无符号32位整数"),
 CompletionItem(label: "U64", kind: .struct, detail: "无符号64位整数"),
 CompletionItem(label: "F32", kind: .struct, detail: "32位浮点"),
 CompletionItem(label: "F64", kind: .struct, detail: "64位浮点"),
 CompletionItem(label: "String", kind: .struct, detail: "字符串"),
 CompletionItem(label: "Bool", kind: .struct, detail: "布尔值"),
 CompletionItem(label: "Array", kind: .struct, detail: "数组"),
 CompletionItem(label: "Optional", kind: .struct, detail: "可选类型"),
 CompletionItem(label: "WeakRef", kind: .struct, detail: "弱引用"),
]
