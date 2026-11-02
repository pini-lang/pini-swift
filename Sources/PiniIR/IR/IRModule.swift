import Foundation

/// A lowered function. `returnType` nil = void; slice set allows at most one
/// scalar return type (tuple returns are a later grid).
public struct IRFunction: Equatable {
    public let name: String
    public let params: [IRParam]
    public let returnType: IRType?
    public let body: IRBlock
    /// `=>` dispatch: the body runs on a worker thread and the caller receives a pending `Future`, not the body's value.
    /// The flag stays on the callee instead of being re-derived from `returnType`: a call node carries the body protocol
    /// rather than the signature, and an unannotated parameter has no type at all — so a type cannot answer it.
    public let isAsync: Bool
    /// `|test`: the block is a language-level test case, not a callee. `pini test` collects exactly these and nothing else
    /// calls them. The fact must travel in the IR because the collection rule lives on `FuncDecl.modifiers`, which has no
    /// IR counterpart; the name is no substitute — a program may name a function `测试` and mean it as production code.
    public let isTest: Bool
    /// The file this function was declared in. Carried because `lower(package:)` merges every file's declarations into one
    /// virtual module, and the merge erases which file each one came from; `pini test <path>` narrows by file, so the
    /// merged module has to keep it or the narrowing cannot be honoured.
    public let sourceFile: String
    /// 本函数的物化依赖：函数体里出现的默认实例取用所指向的给定块类型，降载时逐点收集
    /// （`FunctionContext.givenReferenceNames`）后在构造时取出。留痕是给后置的环检测用的
    /// （`IRModule.givenReferences`），本期不产任何诊断。
    public let givenReferenceNames: Set<String>
    /// 本函数体直接调用的函数名（IR 名），降载时逐点收集，含方法调用。环检测靠它穿透普通函数：
    /// 没有「函数 → 函数」这条边，字段初值经中间函数绕回来的环就走不通。
    public let calledFunctionNames: Set<String>
    /// 源码里的写法（`类型.方法`），只在它与 `name` 不同时给出 —— 方法在 IR 里是 mangle 过的
    /// `方法__类型`（`点` → `_u70B9`）。空串表示与 `name` 同名，顶层函数即如此。
    public let displayName: String

    public struct IRParam: Equatable {
        public let name: String
        public let type: IRType
        /// AST 面 `Parameter.isUsing` 的随行者：与 `isAsync` / `isTest` / `sourceFile` 同族——AST 上有的字段 IR 必须随行，
        /// 否则降载是首个丢失它的地方，后端再也问不出「这个参数是谁提供的」。
        /// 目前只做携带：物化与强制规则属后续，故它今天没有消费点。
        public let isUsing: Bool
        public init(name: String, type: IRType, isUsing: Bool = false) {
            self.name = name
            self.type = type
            self.isUsing = isUsing
        }
    }

    public init(
        name: String, params: [IRParam], returnType: IRType?, body: IRBlock,
        isAsync: Bool = false, isTest: Bool = false, sourceFile: String = "",
        givenReferenceNames: Set<String> = [], calledFunctionNames: Set<String> = [],
        displayName: String = ""
    ) {
        self.name = name
        self.params = params
        self.returnType = returnType
        self.body = body
        self.isAsync = isAsync
        self.isTest = isTest
        self.givenReferenceNames = givenReferenceNames
        self.calledFunctionNames = calledFunctionNames
        self.displayName = displayName
        self.sourceFile = sourceFile
    }
}

/// One enum case (G4): declaration-order tag + typed associated values.
public struct IREnumCase: Equatable {
    public let name: String
    public let tag: Int
    /// Associated-parameter names (`nil` = positional declaration); parallel
    /// to payloadTypes. Labeled constructor arguments resolve through these.
    public let paramNames: [String?]
    public let payloadTypes: [IRType]

    public init(name: String, tag: Int, paramNames: [String?], payloadTypes: [IRType]) {
        self.name = name
        self.tag = tag
        self.paramNames = paramNames
        self.payloadTypes = payloadTypes
    }
}

/// A lowered enum declaration (G4): tagged union layout — the emitter emits
/// `%enum.Name = type { i32, <max-arity case payload types> }`.
public struct IREnumDecl: Equatable {
    public let name: String
    public let cases: [IREnumCase]

    public init(name: String, cases: [IREnumCase]) {
        self.name = name
        self.cases = cases
    }

    /// The payload types of the max-arity case (the union's slot layout).
    public var slotTypes: [IRType] {
        cases.max { $0.payloadTypes.count < $1.payloadTypes.count }?.payloadTypes ?? []
    }
}

/// One foreign function binding (G14, FFI 子系统): a signature-only entry
/// from a `[库|foreign]` block. The emitter forwards its declare; the call
/// site is a plain `.call` resolved through the signature table.
public struct IRForeignFunction: Equatable {
    public let name: String
    public let paramTypes: [IRType]
    public let returnType: IRType?

    public init(name: String, paramTypes: [IRType], returnType: IRType?) {
        self.name = name
        self.paramTypes = paramTypes
        self.returnType = returnType
    }
}

/// 一个外部数据符号：名字即符号名，`type` 是该存储的静态类型。
/// `readonly` 只是一条写侧禁令，进 IR 是为了让发射层区分可写与只读，链接期无判据。
public struct IRForeignData: Equatable {
    public let name: String
    public let type: IRType
    public let isReadonly: Bool

    public init(name: String, type: IRType, isReadonly: Bool) {
        self.name = name
        self.type = type
        self.isReadonly = isReadonly
    }
}

/// 宏常量的构建期值。它没有存储：读它就是读这个字面量，取址无从谈起。
public enum IRForeignConstantValue: Equatable {
    case integer(Int)
    case float(Double)
}

/// 一条宏常量：名字、声明类型、构建期求出的值。
public struct IRForeignConstant: Equatable {
    public let name: String
    public let type: IRType
    public let value: IRForeignConstantValue

    public init(name: String, type: IRType, value: IRForeignConstantValue) {
        self.name = name
        self.type = type
        self.value = value
    }
}

/// A lowered foreign block: the group name (the label left of `|` in `[libc|foreign]`) plus its signature-only
/// bindings. Symbol resolution happens on the interpreter/ffi side (shim whitelist first, then dlsym); the IR layer
/// only carries the declare surface.
public struct IRForeignBlock: Equatable {
    public let name: String
    public let funcs: [IRForeignFunction]
    /// 数据符号：`名: 类型` 条目，读、取址、写都落到这一张表上。
    public let data: [IRForeignData]
    /// 宏常量：`名|macro: 类型` 条目，值在构建期由 C 预处理器给出。
    public let constants: [IRForeignConstant]

    public init(
        name: String, funcs: [IRForeignFunction], data: [IRForeignData] = [],
        constants: [IRForeignConstant] = []
    ) {
        self.name = name
        self.funcs = funcs
        self.data = data
        self.constants = constants
    }
}

/// A lowered module: the ordered functions plus the nominal type and enum declarations. The entry function is `main`
/// (required by the slice emitter); methods live inside their `IRTypeDecl` and are emitted as regular functions.
public struct IRModule: Equatable {
    public let functions: [IRFunction]
    public let types: [IRTypeDecl]
    public let enums: [IREnumDecl]
    /// Foreign blocks (G14): declare-only surface, no bodies.
    public let foreigns: [IRForeignBlock]

    /// 布局事实：名义头、字段与载荷各在第几槽。后端只读不算 —— 契约第 5 节「布局归位」。
    public let layout: IRLayout

    /// 谁引用了哪个给定块：键是引用方（函数名 / 给定块名），值是它引用的给定块类型名（升序去重）。
    /// 引用面 = 函数体里的默认实例取用点 + 给定块字段初值里的引用；只覆盖**直接取用**，且方法体不在表内
    /// （方法不进 `functions`）。这是可观测面而非诊断：环检测读它，留痕当期就要做对。
    public let givenReferences: [String: [String]]

    /// 谁调用了哪个顶层函数：键是调用方（函数名 / 给定块名），值是它直接调用的函数名（升序去重）。
    /// 与 `givenReferences` 分表是刻意的：那张表的值面恒为给定块，环检测据此判定「哪些节点是给定块」，
    /// 混进函数名会让这条判据失效。
    public let callReferences: [String: [String]]

    public init(
        functions: [IRFunction], types: [IRTypeDecl] = [], enums: [IREnumDecl] = [],
        foreigns: [IRForeignBlock] = [], layout: IRLayout = .standard,
        givenReferences: [String: [String]] = [:], callReferences: [String: [String]] = [:]
    ) {
        self.functions = functions
        self.types = types
        self.enums = enums
        self.foreigns = foreigns
        self.layout = layout
        self.givenReferences = givenReferences
        self.callReferences = callReferences
    }

    public func function(named name: String) -> IRFunction? {
        functions.first { $0.name == name }
    }

    /// IR 名 → 源码写法，只收两者不同的那些。诊断层拿它把 mangle 过的名字还原成 `类型.方法`；
    /// 分不清的（顶层函数）没有条目，按名直出即可。
    public var displayNames: [String: String] {
        var labels: [String: String] = [:]
        for function in functions where !function.displayName.isEmpty {
            labels[function.name] = function.displayName
        }
        for decl in types {
            for method in decl.methods where !method.displayName.isEmpty {
                labels[method.name] = method.displayName
            }
        }
        return labels
    }

    public var mainFunction: IRFunction? {
        function(named: "main")
    }
}
