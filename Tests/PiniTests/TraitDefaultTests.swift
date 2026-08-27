import XCTest
import PiniCore
import Foundation

final class TraitDefaultTests: XCTestCase {

    private func runProgram(_ source: String) throws -> String {
        let lexer = Lexer(source: source, fileName: "test.pini")
        let tokens = try lexer.tokenize()
        let parser = Parser(tokens: tokens, fileName: "test.pini")
        let module = try parser.parseModule()

        let pipe = Pipe()
        let originalStdout = dup(STDOUT_FILENO)
        setvbuf(stdout, nil, _IONBF, 0)
        dup2(pipe.fileHandleForWriting.fileDescriptor, STDOUT_FILENO)

        do {
            let interpreter = Interpreter()
            try interpreter.run(module: module)
        } catch {
            fflush(stdout)
            dup2(originalStdout, STDOUT_FILENO)
            close(originalStdout)
            throw error
        }

        fflush(stdout)
        pipe.fileHandleForWriting.closeFile()
        dup2(originalStdout, STDOUT_FILENO)
        close(originalStdout)
        let result = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Parser Tests

    // TR-A6.1: Trait with default method body parses
    /// 意图：验证带方法体的 trait 默认方法可解析：trait 名与签名数正确，且签名携带非 nil 方法体
    func testTraitWithDefaultMethodParses() throws {
        let source = """
        <Printable>
            describe() -> (String,)
                return "default"
        """
        let lexer = Lexer(source: source, fileName: "test.pini")
        let tokens = try lexer.tokenize()
        let parser = Parser(tokens: tokens, fileName: "test.pini")
        let module = try parser.parseModule()

        guard case .traitDecl(let td) = module.declarations.first else {
            XCTFail("Expected traitDecl")
            return
        }
        XCTAssertEqual(td.name, "Printable")
        XCTAssertEqual(td.signatures.count, 1)
        XCTAssertNotNil(td.signatures[0].body, "default method should have body")
    }

    /// 意图：验证无方法体的抽象方法可解析：签名存在但 body 为 nil
    func testTraitWithAbstractMethodParses() throws {
        let source = """
        <Serializable>
            serialize(self) -> (String,)
        """
        let lexer = Lexer(source: source, fileName: "test.pini")
        let tokens = try lexer.tokenize()
        let parser = Parser(tokens: tokens, fileName: "test.pini")
        let module = try parser.parseModule()

        guard case .traitDecl(let td) = module.declarations.first else {
            XCTFail("Expected traitDecl")
            return
        }
        XCTAssertEqual(td.name, "Serializable")
        XCTAssertEqual(td.signatures.count, 1)
        XCTAssertNil(td.signatures[0].body, "abstract method should have no body")
    }

    /// 意图：验证结构体的 `实现: Greetable` 声明被提取为 trait（sd.traits 含 "Greetable"），并从字段列表中移除
    func testStructTraitExtraction() throws {
        let source = """
        <Greetable>
            greet(self) -> (String,)
                return "default"

        (Dog)
        名称: String = "Rex"
        实现: Greetable
        """
        let lexer = Lexer(source: source, fileName: "test.pini")
        let tokens = try lexer.tokenize()
        let parser = Parser(tokens: tokens, fileName: "test.pini")
        let module = try parser.parseModule()

        guard case .structDecl(let sd) = module.declarations[1] else {
            XCTFail("Expected structDecl")
            return
        }
        XCTAssertEqual(sd.traits, ["Greetable"])
        XCTAssertFalse(sd.fields.contains(where: { $0.name == "实现" }), "实现 field should be extracted out")
    }

    // MARK: - Interpreter Tests

    // TR-A6.2: Uncovered default method auto-available
    /// 意图：验证结构体未覆盖 trait 默认方法时自动可用：Dog 仅声明 `实现: Greetable`，调用 greet() 输出 "hello from trait"
    func testDefaultMethodAutoAvailable() throws {
        let source = """
        <Greetable>
            greet(self) -> (String,)
                return "hello from trait"

        (Dog)
        名称: String = "Rex"
        实现: Greetable

        main|func() -> ()
            var dog = Dog()
            print(dog.greet())
            return
        """
        let output = try runProgram(source)
        XCTAssertEqual(output, "hello from trait")
    }

    // TR-A6.3: Behavior covers default
    /// 意图：验证结构体显式行为覆盖 trait 默认方法：Cat 覆盖 greet 输出 "meow from cat" 而非默认值
    func testBehaviorCoversDefault() throws {
        let source = """
        <Greetable>
            greet(self) -> (String,)
                return "trait default"

        (Cat)
        名称: String = "Whiskers"
        实现: Greetable

        ((Cat))
        greet|self() -> (String,)
            return "meow from cat"

        main|func() -> ()
            var cat = Cat()
            print(cat.greet())
            return
        """
        let output = try runProgram(source)
        XCTAssertEqual(output, "meow from cat")
    }

    /// 意图：验证 trait 默认方法可省略 self 参数：greet() 无参声明可解析、可调用，输出 "no-self default"
    func testTraitMethodWithoutSelfParam() throws {
        let source = """
        <Greetable>
            greet() -> (String,)
                return "no-self default"

        (Person)
        名称: String = "Alice"
        实现: Greetable

        main|func() -> ()
            var p = Person()
            print(p.greet())
            return
        """
        let output = try runProgram(source)
        XCTAssertEqual(output, "no-self default")
    }

    /// 意图：验证 trait 默认方法支持额外参数：sayHello(self, name: String) 按 name 传值调用输出 "hello, Bob"
    func testTraitMethodWithExtraParams() throws {
        let source = """
        <Greeter>
            sayHello(self, name: String) -> (String,)
                return "hello, " + name

        (Person)
        名称: String = "Alice"
        实现: Greeter

        main|func() -> ()
            var p = Person()
            print(p.sayHello(name: "Bob"))
            return
        """
        let output = try runProgram(source)
        XCTAssertEqual(output, "hello, Bob")
    }

    /// 意图：验证默认方法内可通过 self 访问结构体字段：getName 返回 self.名称 = "Alice"
    func testSelfAccessibleInDefaultMethod() throws {
        let source = """
        <Named>
            getName(self) -> (String,)
                return self.名称

        (Person)
        名称: String = "Alice"
        实现: Named

        main|func() -> ()
            var p = Person()
            print(p.getName())
            return
        """
        let output = try runProgram(source)
        XCTAssertEqual(output, "Alice")
    }

    /// 意图：验证无 trait 实现时结构体自带方法仍正常：Dog 直接定义 greet|self() 输出 "woof"
    func testNoTraitImplementationStillWorks() throws {
        let source = """
        (Dog)
        名称: String = "Rex"

        ((Dog))
        greet|self() -> (String,)
            return "woof"

        main|func() -> ()
            var dog = Dog()
            print(dog.greet())
            return
        """
        let output = try runProgram(source)
        XCTAssertEqual(output, "woof")
    }
}
