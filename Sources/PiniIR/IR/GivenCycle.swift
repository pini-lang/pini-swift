import Foundation

/// 给定块物化环：只看边表，不碰编译器状态。
/// 边表 = `IRModule.givenReferences` ∪ `IRModule.callReferences`：前者连「谁取用了哪个给定块」，
/// 后者连「谁调用了哪个函数」。普通函数由此也能入环，路径里会同时出现函数名。
public enum GivenCycleDetector {

    /// 边表里所有**含给定块**的环。不含给定块的环是普通递归，不报 —— 那是运行时栈的事，不是物化的事。
    /// 每条路径首尾同名（如 `["甲块", "取数", "甲块"]`），起点一律旋转到环里最小的给定块。
    public static func cycles(in edges: [String: [String]], givenBlocks: Set<String>) -> [[String]] {
        var marks: [String: Mark] = [:]
        var stack: [String] = []
        var depth: [String: Int] = [:]
        var found: Set<[String]> = []

        func visit(_ node: String) {
            marks[node] = .onStack
            depth[node] = stack.count
            stack.append(node)
            for next in (edges[node] ?? []).sorted() {
                if let mark = marks[next] {
                    // 回边：栈上从 next 到栈顶是一条链，补上 next 即闭合。
                    if mark == .onStack {
                        let cycle = Array(stack[depth[next]!...]) + [next]
                        if cycle.dropLast().contains(where: givenBlocks.contains) {
                            found.insert(rotatedToSmallestGiven(cycle, givenBlocks: givenBlocks))
                        }
                    }
                } else {
                    visit(next)
                }
            }
            stack.removeLast()
            depth[node] = nil
            marks[node] = .done
        }

        for node in edges.keys.sorted() where marks[node] == nil {
            visit(node)
        }
        return found.sorted { $0.lexicographicallyPrecedes($1) }
    }

    /// 栈上的节点标「在栈里」，收敛了的标「已完成」—— 无标记即未访问。深度等于最长依赖链，递归撑得住。
    private enum Mark: Equatable {
        case onStack
        case done
    }

    /// 环旋转到**最小的给定块**开头。定位与展示共用这一种旋转：告警按起点回 AST 取声明位置，
    /// 旋转到函数名开头会让那条查找落空，也读不出「是哪个块要物化自己」。
    private static func rotatedToSmallestGiven(_ path: [String], givenBlocks: Set<String>) -> [String] {
        guard path.count > 2 else { return path }
        let body = path.dropLast()
        guard
            let pivot = body.indices
                .filter({ givenBlocks.contains(body[$0]) })
                .min(by: { body[$0] < body[$1] })
        else { return path }
        let rotated = Array(body[pivot...]) + Array(body[..<pivot])
        return rotated + [rotated[0]]
    }
}
