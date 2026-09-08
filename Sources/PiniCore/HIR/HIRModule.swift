import Foundation

/// A lowered function. `returnType` nil = void; slice set allows at most one
/// scalar return type (tuple returns are a later grid).
public struct HIRFunction: Equatable {
    public let name: String
    public let params: [HIRParam]
    public let returnType: HIRType?
    public let body: [HIRStmt]

    public struct HIRParam: Equatable {
        public let name: String
        public let type: HIRType
        public init(name: String, type: HIRType) {
            self.name = name
            self.type = type
        }
    }

    public init(name: String, params: [HIRParam], returnType: HIRType?, body: [HIRStmt]) {
        self.name = name
        self.params = params
        self.returnType = returnType
        self.body = body
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

/// A lowered module: the ordered list of functions plus the nominal type
/// declarations (G3) and enum declarations (G4). The entry function is
/// `main` (required by the slice emitter); methods live inside their
/// `HIRTypeDecl` and are emitted as regular functions by the emitter.
public struct HIRModule: Equatable {
    public let functions: [HIRFunction]
    public let types: [HIRTypeDecl]
    public let enums: [HIREnumDecl]

    public init(functions: [HIRFunction], types: [HIRTypeDecl] = [], enums: [HIREnumDecl] = []) {
        self.functions = functions
        self.types = types
        self.enums = enums
    }

    public func function(named name: String) -> HIRFunction? {
        functions.first { $0.name == name }
    }

    public var mainFunction: HIRFunction? {
        function(named: "main")
    }
}
