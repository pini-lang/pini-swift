import Foundation

public enum ParserError: Error, Equatable {
    case unexpectedToken(expected: String, actual: String, location: SourceLocation)
    case expectedToken(token: String, location: SourceLocation)
    case missingIndent(location: SourceLocation)
    case missingDedent(location: SourceLocation)
    case invalidDeclaration(reason: String, location: SourceLocation)
    case invalidExpression(reason: String, location: SourceLocation)
    case invalidStatement(reason: String, location: SourceLocation)
    case invalidType(reason: String, location: SourceLocation)
    case missingBlockBody(location: SourceLocation)
    case missingBlockEnd(location: SourceLocation)
    case invalidModifier(reason: String, location: SourceLocation)
    case missingParameterName(location: SourceLocation)
    case missingReturnType(location: SourceLocation)
    case missingFieldName(location: SourceLocation)
    case missingCaseName(location: SourceLocation)
    case missingMethodName(location: SourceLocation)
    case missingTraitName(location: SourceLocation)
    case missingStructName(location: SourceLocation)
    case missingObjectName(location: SourceLocation)
    case missingEnumName(location: SourceLocation)
    case missingGenericParam(location: SourceLocation)
    case missingLabel(location: SourceLocation)
    case unexpectedEOF(location: SourceLocation)
    case methodDefaultAssumptionTerminated(location: SourceLocation)
    /// ADR-001 `P3`（参数位收窄）：`using` 形参出现在**没有 Pini 调用方**的位置
    /// （`main` / `|test` / `|foreign` / trait 抽象签名）⇒ 编译器无处插入默认实例。
    case usingParameterNotAllowed(reason: String, location: SourceLocation)
}
