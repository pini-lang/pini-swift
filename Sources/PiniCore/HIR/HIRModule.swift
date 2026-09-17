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

    public struct HIRParam: Equatable {
        public let name: String
        public let type: HIRType
        public init(name: String, type: HIRType) {
            self.name = name
            self.type = type
        }
    }

    public init(name: String, params: [HIRParam], returnType: HIRType?, body: HIRBlock,
                isAsync: Bool = false) {
        self.name = name
        self.params = params
        self.returnType = returnType
        self.body = body
        self.isAsync = isAsync
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

/// One foreign function binding (G14, ADR-015 FFI): a signature-only entry
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

    public init(functions: [HIRFunction], types: [HIRTypeDecl] = [], enums: [HIREnumDecl] = [],
                foreigns: [HIRForeignBlock] = []) {
        self.functions = functions
        self.types = types
        self.enums = enums
        self.foreigns = foreigns
    }

    public func function(named name: String) -> HIRFunction? {
        functions.first { $0.name == name }
    }

    public var mainFunction: HIRFunction? {
        function(named: "main")
    }
}
