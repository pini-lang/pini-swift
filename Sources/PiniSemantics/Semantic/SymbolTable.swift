import Foundation
import PiniSyntax

/// 符号表
/// 管理全局和局部作用域中的符号
public final class SymbolTable {
    public private(set) var current: Scope

    public init(globalScope: Scope = Scope(name: "global")) {
        self.current = globalScope
    }

    public func enterScope(name: String) {
        current = Scope(name: name, parent: current)
    }

    public func exitScope() {
        if let parent = current.parent {
            current = parent
        }
    }

    /// 注入冲突哨兵——分析器按文件设置「本文件注入符号名」；define 命中即回调
    /// （本地顶级/局部声明与注入裸名相撞），由分析器记录为 E3-013。
    public var forbiddenNames: Set<String> = []
    public var onForbiddenDefine: ((String) -> Void)?

    /// 同作用域混淆回调：新名与已有名的形近骨架（UTS 39）相同而 NFC 不同。
    /// 只报告，不阻断——两个名字确实可能都是有意写的。
    public var onConfusableIdentifier: ((String, String, SourceLocation) -> Void)?

    /// 名字到骨架的缓存：一次分析内同一名字只算一遍。
    private var skeletonCache: [String: String] = [:]

    public func define(_ symbol: Symbol) {
        if !forbiddenNames.isEmpty, forbiddenNames.contains(symbol.name) {
            onForbiddenDefine?(symbol.name)
        }
        reportConfusable(symbol)
        current.define(symbol)
    }

    /// 只与当前作用域里的名字比：跨作用域的遮蔽不在这条规则里。
    private func reportConfusable(_ symbol: Symbol) {
        guard let onConfusableIdentifier else { return }
        let target = skeleton(of: symbol.name)
        for existing in current.symbols.keys.sorted() where existing != symbol.name {
            if skeleton(of: existing) == target {
                onConfusableIdentifier(symbol.name, existing, symbol.location)
                return
            }
        }
    }

    private func skeleton(of name: String) -> String {
        if let cached = skeletonCache[name] { return cached }
        let value = ConfusableSkeleton.skeleton(of: name)
        skeletonCache[name] = value
        return value
    }

    public func resolve(_ name: String) -> Symbol? {
        current.resolve(name)
    }

    /// 当前（最内层）作用域内是否已定义该名字。
    /// 用于「同作用域重声明」检测：跨作用域的遮蔽（shadowing）不在此列。
    public func isDefinedInCurrentScope(_ name: String) -> Bool {
        current.symbols[name] != nil
    }

    /// 自当前作用域向上解析，同时返回命中作用域。供 H-1 capture 语义判定：
    /// 命中作用域在匿名函数体作用域边界之外（外层局部）还是之内（体内局部/参数）。
    public func resolveWithScope(_ name: String) -> (symbol: Symbol, scope: Scope)? {
        var scope: Scope? = current
        while let s = scope {
            if let sym = s.symbols[name] { return (sym, s) }
            scope = s.parent
        }
        return nil
    }
}
