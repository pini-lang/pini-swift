import Foundation

/// Loads a Pini fixture that sits next to the test file:
///   <TestFileName>/<name>.pini
///
/// `filePath` must be passed explicitly as `#filePath` from the CALL SITE --
/// a default value would evaluate at this definition, pointing at this file.
///
/// The inlined-source form is being retired: Pini sources embedded in Swift
/// multiline strings are shaped by Swift's indentation and escaping rules
/// rather than by Pini's, which is a recurring source of false failures
func loadPiniFixture(_ name: String, filePath: String) throws -> String {
 let url = URL(fileURLWithPath: filePath)
 let dir = url.deletingLastPathComponent()
 let base = url.deletingPathExtension().lastPathComponent
 // `name` may already carry the .pini suffix
 let file = name.hasSuffix(".pini") ? name : name + ".pini"
 return try String(contentsOf: dir.appendingPathComponent(base).appendingPathComponent(file),
                   encoding: .utf8)
}
