import Foundation

/// ADR-020 D2 试点：语言内标准库（Pini 源内嵌于宿主，启动期解析）。
///
/// 结构：按扩展块组织——`((String))` 内的语言内默认实现会在运行时成员派发中
/// **优先于宿主原生实现**被选中（callFunctionValue 的 body-first 通道）。
/// 本源码是固化的仓内资产：启动期解析失败 = 资产被破坏，fail-fast。
///
/// 下沉规则（ADR-020 D2）：每个方法从宿主原生转为语言内实现，须同时满足
/// ① 全量测试对拍 0 失败；② bench 无不可接受回退。试点 = String.contains。
///
/// 缩进说明：Swift 多行字符串闭定界符与 `static let` 齐平（1 空格），剥离后
/// Pini 源为 0/4/8/12 空格层级。
enum StdlibPini {
 static let source = """
 ((String))
 ; contains -- language-level default impl (ADR-020 D2 pilot).
 ; Semantics mirror the host native impl: empty needle -> true;
 ; grapheme-cluster substring match via len + subscript.
 contains|self(needle: String,) -> (Bool,)
     if len(needle) == 0:
         return true
     var i = 0
     var n = len(self)
     var m = len(needle)
     while i + m <= n:
         var j = 0
         var ok = true
         while j < m:
             if self[i + j]! != needle[j]!:
                 ok = false
                 break
             j = j + 1
         if ok:
             return true
         i = i + 1
     return false
 """
}
