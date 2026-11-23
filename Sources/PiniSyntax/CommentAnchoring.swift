/// 注释锚回：把词法旁路表里的注释插回打印器产出的行序。
/// 决策只看「注释位置」与「节点位置」的先后，不读原文本的空白，故二次打印落在同一不动点。
enum CommentAnchoring {

    /// 待落位的注释行：文本、输出列与原文行号。列在插入时才决定，缩进据此生成。
    /// 行号只用来判段落：相邻注释在原文隔了空行，输出也隔一行，否则整段注释会连成一块。
    private struct Slot {
        let text: String
        let column: Int
        let line: Int
    }

    /// 三条规则按形态查表：块内挂下一处锚点之前，块尾挂前一处之后，行尾挂同源行末（隔一空格）。
    /// 注释列 = 从前一处锚点向后找第一处「列号不深于注释」的锚点所在列；块首、空块、连续注释因此无需分支。
    /// 判断只看位置先后；空行只按旁路里的行号还原，故二次打印落在同一不动点。
    static func apply(
        lines: [Printer.SourceWriter.Line], comments: CommentTable, hints: PrintHints
    ) -> [Printer.SourceWriter.Line] {
        guard !comments.isEmpty, !lines.isEmpty else { return lines }
        let anchors = lines.indices.filter { lines[$0].anchor != nil }
        guard !anchors.isEmpty else { return lines }

        var before: [Int: [Slot]] = [:]
        var after: [Int: [Slot]] = [:]
        var appended: [Int: String] = [:]
        var tail: [Slot] = []

        for comment in comments.sorted(by: { ($0.line, $0.column) < ($1.line, $1.column) }) {
            if !comment.ownLine,
                let slot = anchors.last(where: { lines[$0].anchor?.line == comment.line })
            {
                appended[slot, default: ""] += " " + comment.text
                continue
            }
            let next = anchors.firstIndex { lines[$0].anchor!.line > comment.line }
            let prev = anchors.lastIndex { lines[$0].anchor!.line <= comment.line }
            let column = column(of: comment, upTo: prev, anchors: anchors, lines: lines)

            if let prev, next.map({ column > lines[anchors[$0]].column }) ?? true {
                after[anchors[prev], default: []].append(
                    Slot(text: comment.text, column: column, line: comment.line))
            } else if let next {
                before[anchors[next], default: []].append(
                    Slot(text: comment.text, column: lines[anchors[next]].column, line: comment.line))
            } else {
                tail.append(Slot(text: comment.text, column: 0, line: comment.line))
            }
        }

        // 块首行 = 输出列比上一非空行更深的那一行。它上方的空行属于块首，按块内规则丢弃。
        var blockStarts = Set<Int>()
        var previousColumn = 0
        for (index, line) in lines.enumerated() where line.text != "" {
            if line.column > previousColumn { blockStarts.insert(index) }
            previousColumn = line.column
        }

        var out: [Printer.SourceWriter.Line] = []
        out.reserveCapacity(lines.count + comments.count)
        for (index, line) in lines.enumerated() {
            emit(
                before[index] ?? [], hints: hints, dropLeading: blockStarts.contains(index),
                into: &out)
            var current = line
            if let extra = appended[index] { current.text += extra }
            out.append(current)
            emit(after[index] ?? [], hints: hints, into: &out)
        }
        emit(tail, hints: hints, into: &out)
        return out
    }

    /// 落一组注释。段落边界要留：原文相隔空行的两段之间、以及整段上方的空行都补一行，
    /// 否则两段会连成一块，注释门禁的块长判据随即变红。
    private static func emit(
        _ slots: [Slot], hints: PrintHints, dropLeading: Bool = false,
        into out: inout [Printer.SourceWriter.Line]
    ) {
        var previous: Int?
        for (index, slot) in slots.enumerated() {
            let pastGap = previous.map { slot.line - $0 > 1 } ?? false
            let sourceGap = !(index == 0 && dropLeading) && hints.blanks(at: slot.line) > 0
            if (pastGap || sourceGap), out.last?.text != "" {
                out.append(.init(text: "", column: 0, anchor: nil))
            }
            out.append(.init(text: indent(slot.column) + slot.text, column: slot.column, anchor: nil))
            previous = slot.line
        }
    }

    /// 注释落在哪一列：从 `limit` 处向前找第一处列号不深于注释的锚点，取它的输出列。
    /// 找不到（注释比所有锚点都靠左）或尚未出现锚点时，退到最近一处锚点的列。
    private static func column(
        of comment: CommentEntry, upTo limit: Int?, anchors: [Int], lines: [Printer.SourceWriter.Line]
    ) -> Int {
        guard let limit else { return 0 }
        for slot in stride(from: limit, through: 0, by: -1) {
            let anchor = lines[anchors[slot]].anchor!
            if anchor.column <= comment.column { return lines[anchors[slot]].column }
        }
        return lines[anchors[limit]].column
    }

    static func indent(_ column: Int) -> String {
        String(repeating: " ", count: column)
    }
}
