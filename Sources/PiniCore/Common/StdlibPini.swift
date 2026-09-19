import Foundation

/// 内建双层结构 试点：语言内标准库（Pini 源内嵌于宿主，启动期解析）。
///
/// 结构：按扩展块组织——`((String))` 内的语言内默认实现会在运行时成员派发中
/// **优先于宿主原生实现**被选中（callFunctionValue 的 body-first 通道）。
/// 本源码是固化的仓内资产：启动期解析失败 = 资产被破坏，fail-fast。
///
/// 下沉规则（内建双层结构）：每个方法从宿主原生转为语言内实现，须同时满足
/// ① 全量测试对拍 0 失败；② bench 无不可接受回退。试点 = String.contains。
///
/// 缩进说明：Swift 多行字符串闭定界符与 `static let` 齐平（1 空格），剥离后
/// Pini 源为 0/4/8/12 空格层级。
enum StdlibPini {
    static let source = """
        ((String))
        ; contains -- language-level default impl (内建双层结构 pilot).
        ; Semantics mirror the host native impl: empty needle -> true;
        ; grapheme-cluster substring match via len + subscript.
        contains|self(needle: String,) -> (Bool,):
            if len(needle) == 0:
                return true
            var i = 0
            var n = len(self)
            var m = len(needle)
            while i + m <= n:
                var j = 0
                var ok = true
                while j < m:
                    if self[i + j] != needle[j]:
                        ok = false
                        break
                    j = j + 1
                if ok:
                    return true
                i = i + 1
            return false

        ; substring -- negative tail-count, clamp to [0, len], hi < lo -> "".
        substring|self(start: I32, end: I32,) -> (String,):
            var n = len(self)
            var lo = start
            var hi = end
            if lo < 0:
                lo = n + lo
            if hi < 0:
                hi = n + hi
            if lo < 0:
                lo = 0
            if lo > n:
                lo = n
            if hi < 0:
                hi = 0
            if hi > n:
                hi = n
            if hi < lo:
                return ""
            var out = ""
            var k = lo
            while k < hi:
                out = out + self[k]
                k = k + 1
            return out

        ; split -- Contract §2.39 (A4): empty tokens are skipped, so "a,,b" yields two
        ; parts rather than three. This is a contract-level ruling about what all
        ; backends must agree on, not a preference of one of them; before it the
        ; accumulator went in unconditionally and every empty segment survived. Doubled,
        ; leading and trailing separators therefore all contribute no element, and an
        ; empty receiver yields zero parts.
        ; An empty separator yields one element per grapheme (字符模型 = Grapheme Cluster; the native
        ; impl splits UTF-16). Two neighbouring behaviours are deliberately NOT settled
        ; here: the LLVM arm carries no guard for the empty separator, and it reads the
        ; separator as a character *set* rather than a substring, so a multi-character
        ; separator parts company with this rule on inputs such as "a:b" split by "::".
        ; Both divergences are registered against their own grid and are not touched by
        ; this one.
        split|self(sep: String,) -> (Array,):
            var parts = []
            var cur = ""
            var n = len(self)
            var m = len(sep)
            if m == 0:
                var i = 0
                while i < n:
                    parts = parts.append(self[i])
                    i = i + 1
                return parts
            var i = 0
            while i < n:
                var j = 0
                var hit = true
                while j < m:
                    if i + j >= n:
                        hit = false
                        break
                    if self[i + j] != sep[j]:
                        hit = false
                        break
                    j = j + 1
                if hit:
                    if len(cur) > 0:
                        parts = parts.append(cur)
                    cur = ""
                    i = i + m
                else:
                    cur = cur + self[i]
                    i = i + 1
            if len(cur) > 0:
                parts = parts.append(cur)
            return parts

        ; slice -- sliceBound semantics: none open bounds default to [0, len);
        ; int bounds may be negative (tail count); clamp; hi < lo -> "".
        ; (null-as-open is accepted by the native path only; the desugar never
        ; produces it.)
        slice|self(a: Any, b: Any,) -> (String,):
            var n = len(self)
            var lo = 0
            var hi = n
            match a:
                case none:
                    lo = 0
                case _:
                    if a < 0:
                        lo = n + a
                    else:
                        lo = a
            match b:
                case none:
                    hi = n
                case _:
                    if b < 0:
                        hi = n + b
                    else:
                        hi = b
            if lo < 0:
                lo = 0
            if lo > n:
                lo = n
            if hi < 0:
                hi = 0
            if hi > n:
                hi = n
            if hi < lo:
                return ""
            var out = ""
            var k = lo
            while k < hi:
                out = out + self[k]
                k = k + 1
            return out

        ((Array))
        ; slice -- same bound semantics as String.slice; elements via
        ; subscript unwrap; empty array for hi < lo.
        slice|self(a: Any, b: Any,) -> (Array,):
            var n = len(self)
            var lo = 0
            var hi = n
            match a:
                case none:
                    lo = 0
                case _:
                    if a < 0:
                        lo = n + a
                    else:
                        lo = a
            match b:
                case none:
                    hi = n
                case _:
                    if b < 0:
                        hi = n + b
                    else:
                        hi = b
            if lo < 0:
                lo = 0
            if lo > n:
                lo = n
            if hi < 0:
                hi = 0
            if hi > n:
                hi = n
            if hi < lo:
                return []
            var out = []
            var k = lo
            while k < hi:
                out = out.append(self[k])
                k = k + 1
            return out
        """
}
