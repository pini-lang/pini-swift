import Foundation

/// A lowered function. `returnType` nil = void; slice set allows at most one
/// scalar return type (tuple returns are a later grid).
public struct HIRFunction: Equatable {
    public let name: String
    public let params: [HIRParam]
    public let returnType: HIRType?
    public let body: HIRBlock
    /// `=>` dispatch (G-3c-1): the body runs on a worker thread and the caller
    /// receives a pending `Future` instead of the body's own value.
    ///
    /// The flag has to live here rather than be re-derived from `returnType`:
    /// an async body's return type is the same `Result<T>` a synchronous
    /// function returning a Result carries, so the type alone cannot tell the
    /// two call protocols apart. A call site that guessed would either block on
    /// a plain Result or hand back a Future where a Result was promised.
    public let isAsync: Bool
    /// `|test` (G41): the function block is a language-level test case, not a
    /// callee of the program. `pini test` collects exactly these and runs each
    /// one, and nothing else calls them.
    ///
    /// Carried because the collection rule lived only on the AST side: the
    /// interpreter read `FuncDecl.modifiers`, which has no HIR counterpart, so
    /// the fact had to travel or the HIR engine could not tell a test from an
    /// ordinary function. The name is not a substitute — a program may freely
    /// name a function `测试` and mean it as production code.
    public let isTest: Bool
    /// The file this function was declared in (`FuncDecl.location.fileName`).
    ///
    /// Carried because `lower(package:)` merges every file's declarations into
    /// one virtual module, and the merge is exactly what erases the answer to
    /// "which file was this from". `pini test <path>` narrows by file, so the
    /// merged module has to keep it or the narrowing cannot be honoured.
    public let sourceFile: String
    /// ADR-001（`P2b`）：本函数的**物化依赖** —— 函数体里出现的默认实例取用所指向的给定块类型。
    ///
    /// 由函数体降载时逐点收集（`FunctionContext.givenReferenceNames`），在构造 `HIRFunction`
    /// 时取出。留痕的用途是后置的环检测（见 `HIRModule.givenReferences`）；本批一条诊断都不产。
    public let givenReferenceNames: Set<String>

    public struct HIRParam: Equatable {
        public let name: String
        public let type: HIRType
        /// ADR-001（取用参数 `using`，P1）：AST 面 `Parameter.isUsing` 的随行者。
        ///
        /// 与 `isAsync` / `isTest` / `sourceFile` 同族 —— **AST 面上有的事实，HIR 面必须随行**，
        /// 否则降载是首个丢失它的地方，而后端再也问不出「这个参数是谁提供的」。
        /// 本批只做**携带**：物化与强制规则属后续批次，故它今天没有消费点。
        public let isUsing: Bool
        public init(name: String, type: HIRType, isUsing: Bool = false) {
            self.name = name
            self.type = type
            self.isUsing = isUsing
        }
    }

    public init(
        name: String, params: [HIRParam], returnType: HIRType?, body: HIRBlock,
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
public struct HIREnumCase: Equatable {
    public let name: String
    public let tag: Int
    /// Associated-parameter names (`nil` = positional declaration); parallel
    /// to payloadTypes. Labeled constructor arguments resolve through these.
    public let paramNames: [String?]
    public let payloadTypes: [HIRType]

    public init(name: String, tag: Int, paramNames: [String?], payloadTypes: [HIRType]) {
        self.name = name
        self.tag = tag
        self.paramNames = paramNames
        self.payloadTypes = payloadTypes
    }
}

/// A lowered enum declaration (G4): tagged union layout — the emitter emits
/// `%enum.Name = type { i32, <max-arity case payload types> }`.
public struct HIREnumDecl: Equatable {
    public let name: String
    public let cases: [HIREnumCase]

    public init(name: String, cases: [HIREnumCase]) {
        self.name = name
        self.cases = cases
    }

    /// The payload types of the max-arity case (the union's slot layout).
    public var slotTypes: [HIRType] {
        cases.max { $0.payloadTypes.count < $1.payloadTypes.count }?.payloadTypes ?? []
    }
}

/// One foreign function binding (G14, FFI 子系统): a signature-only entry
/// from a `[库|foreign]` block. The emitter forwards its declare; the call
/// site is a plain `.call` resolved through the signature table.
public struct HIRForeignFunction: Equatable {
    public let name: String
    public let paramTypes: [HIRType]
    public let returnType: HIRType?

    public init(name: String, paramTypes: [HIRType], returnType: HIRType?) {
        self.name = name
        self.paramTypes = paramTypes
        self.returnType = returnType
    }
}

/// A lowered foreign block (G14): the group name (`[libc|foreign]` 的 `libc`)
/// plus its signature-only bindings. Note: symbol resolution happens on the
/// interpreter/ffi side (shim whitelist first, then dlsym); the HIR layer
/// only carries the declare surface.
public struct HIRForeignBlock: Equatable {
    public let name: String
    public let funcs: [HIRForeignFunction]

    public init(name: String, funcs: [HIRForeignFunction]) {
        self.name = name
        self.funcs = funcs
    }
}

/// A lowered module: the ordered list of functions plus the nominal type
/// declarations (G3) and enum declarations (G4). The entry function is
/// `main` (required by the slice emitter); methods live inside their
/// `HIRTypeDecl` and are emitted as regular functions by the emitter.
public struct HIRModule: Equatable {
    public let functions: [HIRFunction]
    public let types: [HIRTypeDecl]
    public let enums: [HIREnumDecl]
    /// Foreign blocks (G14): declare-only surface, no bodies.
    public let foreigns: [HIRForeignBlock]

    /// ADR-001（`P2b` 交付，用户第 5 条裁定的「余量」第 1 条）：**谁引用了哪个给定块**。
    ///
    /// 键 = 引用方（函数名 / 给定块名 / `类型.方法`），值 = 它引用的给定块类型名（升序去重）。
    /// 引用面 = 函数体里出现的默认实例取用点 + 给定块字段初值里的引用 —— 正是**物化依赖**
    /// 的两条边，环只会从这两条边里长出来。
    ///
    /// WHY 现在就要有：环检测本体是后置的（用户裁定「降为警告级服务」），但**留痕**当期就要做对。
    /// 有了这张表，后置的检测是**加一条遍历**；没有它，就得回头重扫一遍降载结果。
    /// ⚠️ 这是**可观测面**而非诊断：当期一条诊断都不产（ADR §7 第 4 项）。
    public let givenReferences: [String: [String]]

    public init(
        functions: [HIRFunction], types: [HIRTypeDecl] = [], enums: [HIREnumDecl] = [],
        foreigns: [HIRForeignBlock] = [], givenReferences: [String: [String]] = [:]
    ) {
        self.functions = functions
        self.types = types
        self.enums = enums
        self.foreigns = foreigns
        self.givenReferences = givenReferences
    }

    public func function(named name: String) -> HIRFunction? {
        functions.first { $0.name == name }
    }

    public var mainFunction: HIRFunction? {
        function(named: "main")
    }
}
