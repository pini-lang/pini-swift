public enum LexerError: Error, Equatable {
 case invalidCharacter(String, SourceLocation)
 case unterminatedString(SourceLocation)
 case indentationError(SourceLocation)
}
