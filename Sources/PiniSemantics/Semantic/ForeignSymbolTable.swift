import Foundation
import PiniSyntax

/// 模块级外部符号表：跨文件合并、冲突裁决与 C 名合法性的唯一出处。
/// 外部符号声明一次即全包可用；同名同型合并，异型、与本地符号同名、非 C 标识符都在声明处拒 ——
/// 裁决落在声明处，作者不必从调用点的报错反推是哪份声明的问题。
struct ForeignSymbolTable {
    struct Entry {
        let symbol: ForeignSymbol
        /// 首次声明所在文件；冲突消息要指回它，否则作者得自己猜是哪一份。
        let fileName: String
    }

    private(set) var byName: [String: Entry] = [:]

    /// 整包建表。`units` 按文件给声明与导出块：导出面与导入面争同一个 C 名也算冲突，
    /// 故导出名先进集合，再由外部符号逐个比对。
    static func build(
        units: [(fileName: String, declarations: [TopLevelDecl], exports: [ExportDecl])]
    ) throws -> ForeignSymbolTable {
        var declaredFiles: [String: String] = [:]
        var exportedCNames: Set<String> = []
        for unit in units {
            for decl in unit.declarations {
                for info in topLevelSymbolInfos(decl) where info.kind != .foreignSymbol {
                    if declaredFiles[info.name] == nil { declaredFiles[info.name] = unit.fileName }
                }
            }
            for block in unit.exports {
                for entry in block.entries where entry.target == .c {
                    exportedCNames.insert(CName.escape(entry.name))
                }
            }
        }

        var table = ForeignSymbolTable()
        for unit in units {
            for decl in unit.declarations {
                guard case .foreignDecl(let block) = decl else { continue }
                for symbol in block.symbols {
                    try table.insert(
                        symbol, fileName: unit.fileName,
                        declaredFiles: declaredFiles, exportedCNames: exportedCNames)
                }
            }
        }
        return table
    }

    private mutating func insert(
        _ symbol: ForeignSymbol, fileName: String,
        declaredFiles: [String: String], exportedCNames: Set<String>
    ) throws {
        guard Self.isCIdentifier(symbol.name) else {
            throw SemanticError.foreignSymbolNotCIdentifier(name: symbol.name, location: symbol.location)
        }
        // 与本模块既有名字同名：类型、函数、给定块、顶层变量都算。C 名占了这个名，
        // 本地声明就没有可用的拼写，且链接期两侧会指向同一符号。
        if declaredFiles[symbol.name] != nil || exportedCNames.contains(symbol.name) {
            throw SemanticError.redeclaredSymbol(name: symbol.name, location: symbol.location)
        }
        if let existing = byName[symbol.name] {
            guard existing.symbol.annotation.isStructurallyEquivalent(to: symbol.annotation),
                existing.symbol.flags == symbol.flags
            else {
                throw SemanticError.foreignSignatureConflict(
                    name: symbol.name, firstFile: existing.fileName, location: symbol.location)
            }
            return
        }
        byName[symbol.name] = Entry(symbol: symbol, fileName: fileName)
    }

    /// C 标识符的判据只认 ASCII：名字要原样交给 `dlsym`，非 ASCII 名字只会得到
    /// 「库里没有这个符号」，与真正写错名字分不开。
    static func isCIdentifier(_ name: String) -> Bool {
        func isStart(_ byte: UInt8) -> Bool {
            byte == 0x5F || (0x41...0x5A).contains(byte) || (0x61...0x7A).contains(byte)
        }
        func isBody(_ byte: UInt8) -> Bool {
            isStart(byte) || (0x30...0x39).contains(byte)
        }
        let bytes = Array(name.utf8)
        guard let first = bytes.first, isStart(first) else { return false }
        return bytes.dropFirst().allSatisfy(isBody)
    }
}
