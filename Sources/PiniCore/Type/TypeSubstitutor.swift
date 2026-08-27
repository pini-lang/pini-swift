import Foundation

public final class TypeSubstitutor {
 public let bindings: [String: TypeAnnotation]

 public init(bindings: [String: TypeAnnotation]) {
 self.bindings = bindings
 }

 public func substitute(type: TypeAnnotation) -> TypeAnnotation {
 switch type {
 case .simple(let name, let loc):
 if let concrete = bindings[name] {
 return concrete
 }
 return type

 case .tuple(let labels, let elements, let loc):
 let substituted = elements.map { substitute(type: $0) }
 return .tuple(labels: labels, elements: substituted, location: loc)

 case .generic(let name, let params, let loc):
 let substitutedParams = params.map { substitute(type: $0) }
 return .generic(name: name, params: substitutedParams, location: loc)

 case .function(let params, let returns, let captured, let loc):
 let subParams = params.map { substitute(type: $0) }
 let subReturns = returns.map { substitute(type: $0) }
 let subCaptured = captured.map { substitute(type: $0) }
 return .function(params: subParams, returns: subReturns, captured: subCaptured, location: loc)

 case .pointer(let element, let loc):
 return .pointer(element: substitute(type: element), location: loc)
 }
 }
}
