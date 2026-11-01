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
        givenReferenceNames: Set<String> = []
    ) {
        self.name = name
        self.params = params
        self.returnType = returnType
        self.body = body
        self.isAsync = isAsync
        self.isTest = isTest
        self.givenReferenceNames = givenReferenceNames
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

/// A lowered foreign block: the group name (the label left of `|` in `[libc|foreign]`) plus its signature-only
/// bindings. Symbol resolution happens on the interpreter/ffi side (shim whitelist first, then dlsym); the IR layer
/// only carries the declare surface.
public struct IRForeignBlock: Equatable {
    public let name: String
    public let funcs: [IRForeignFunction]

    public init(name: String, funcs: [IRForeignFunction]) {
        self.name = name
        self.funcs = funcs
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

    public init(
        functions: [IRFunction], types: [IRTypeDecl] = [], enums: [IREnumDecl] = [],
        foreigns: [IRForeignBlock] = [], layout: IRLayout = .standard,
        givenReferences: [String: [String]] = [:]
    ) {
        self.functions = functions
        self.types = types
        self.enums = enums
        self.foreigns = foreigns
        self.layout = layout
        self.givenReferences = givenReferences
    }

    public func function(named name: String) -> IRFunction? {
        functions.first { $0.name == name }
    }

    public var mainFunction: IRFunction? {
        function(named: "main")
    }
}
