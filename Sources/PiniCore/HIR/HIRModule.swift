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

/// A lowered module: the ordered list of functions plus the nominal type
/// declarations (G3). The entry function is `main` (required by the slice
/// emitter); methods live inside their `HIRTypeDecl` and are emitted as
/// regular functions by the emitter.
public struct HIRModule: Equatable {
    public let functions: [HIRFunction]
    public let types: [HIRTypeDecl]

    public init(functions: [HIRFunction], types: [HIRTypeDecl] = []) {
        self.functions = functions
        self.types = types
    }

    public func function(named name: String) -> HIRFunction? {
        functions.first { $0.name == name }
    }

    public var mainFunction: HIRFunction? {
        function(named: "main")
    }
}
