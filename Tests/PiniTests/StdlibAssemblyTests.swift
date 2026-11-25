import PiniSyntax
import Testing

/// 标准库装配：让位主张按整包收集，写在非首个单元里的同名项同样摘掉标准库那份。
/// 只按首个单元收集时，两份同名扩展方法都会发射，LLVM 通道报重定义。
struct StdlibAssemblyTests {

    @Test func 跨文件同名成员摘掉标准库那份() throws {
        let caller = try FrontEnd.parse(
            source: "前缀|func() -> (Bool,):\n    return \"hello\".startsWith(\"he\")\n",
            fileName: "/pkg/src/api.pini")
        let overrider = try FrontEnd.parse(
            source: "((String))\ntrim|self() -> (String,):\n    return \"override\"\n",
            fileName: "/pkg/src/extra.pini")
        let package = Package(
            name: "case",
            fileUnits: [
                FileUnit(fileName: "/pkg/src/api.pini", module: caller),
                FileUnit(fileName: "/pkg/src/extra.pini", module: overrider),
            ],
            rootPath: "/pkg")

        let assembled = package.assemblingStdlib()
        let members = stringMembers(in: assembled.fileUnits[0].module)
        #expect(members.contains("startsWith"))
        #expect(members.filter { $0 == "trim" }.isEmpty)
    }

    /// 同文件里声明仍按原口径让位：跨文件与同文件两条路都得摘干净。
    @Test func 同文件同名成员摘掉标准库那份() throws {
        let module = try FrontEnd.parse(
            source: "((String))\ntrim|self() -> (String,):\n    return \"override\"\n",
            fileName: "/pkg/src/api.pini")
        let assembled = FrontEnd.assemble(module: module)
        let members = stringMembers(in: assembled)
        #expect(members.contains("startsWith"))
        #expect(members.filter { $0 == "trim" }.count == 1)
    }

    private func stringMembers(in module: Module) -> [String] {
        var names: [String] = []
        for decl in module.declarations {
            guard case .extensionDecl(let decl) = decl, decl.targetType == "String" else { continue }
            for method in decl.methods {
                names.append(method.name)
            }
        }
        return names
    }
}
