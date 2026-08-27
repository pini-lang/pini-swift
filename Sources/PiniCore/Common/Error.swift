public enum PiniError: Error {
 case lexer(details: String, location: SourceLocation)
 case parser(details: String, location: SourceLocation)
 case typeCheck(details: String, location: SourceLocation)
 case semantic(details: String, location: SourceLocation)
 case runtime(details: String, location: SourceLocation)
 case io(details: String)
}
