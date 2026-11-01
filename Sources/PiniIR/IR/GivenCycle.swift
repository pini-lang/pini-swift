import Foundation

/// 给定块物化环：只看边表，不碰编译器状态。
/// 边表即 `IRModule.givenReferences` —— 键是引用方，值是它直接取用的给定块。函数没有入边，进不了环。
public enum GivenCycleDetector {

    /// 边表里所有的环。每条路径首尾同名（如 `["甲块", "乙块", "甲块"]`），结果按字典序排列。
    /// 同一环从不同起点到达只报一次：环一律旋转到最小名字开头，便于比对与展示。
    public static func cycles(in edges: [String: [String]]) -> [[String]] {
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
                        found.insert(rotatedToSmallest(Array(stack[depth[next]!...]) + [next]))
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

    /// 栈上的节点标「在栈里」，收敛了的标「已完成」—— 无标记即未访问。深度等于最长取用链，递归撑得住。
    private enum Mark: Equatable {
        case onStack
        case done
    }

    /// 环旋转到最小名字开头；自环只有两个元素，原样返回。
    private static func rotatedToSmallest(_ path: [String]) -> [String] {
        guard path.count > 2 else { return path }
        let body = path.dropLast()
        guard let pivot = body.indices.min(by: { body[$0] < body[$1] }) else { return path }
        let rotated = Array(body[pivot...]) + Array(body[..<pivot])
        return rotated + [rotated[0]]
    }
}
