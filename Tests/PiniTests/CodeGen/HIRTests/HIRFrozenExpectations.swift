import XCTest
@testable import PiniCore

/// The frozen expectations LR-4 `G-5` left behind for `HIRExecutorTests`.
///
/// WHY A SEPARATE FILE
///
/// Both tables are **data**, not logic: they are the reading of a corpus, kept
/// where a reviewer can diff them without reading past a thousand lines of test
/// code. Regenerating an entry is a deliberate edit whose diff says "the engine
/// output for this fixture moved" - which is the sentence worth reviewing.
///
/// WHAT THEY ARE FOR
///
/// The swap put every surviving arm on the same lowered tree, so an arm-to-arm
/// comparison can no longer see a rule the lowerer drops: both arms lose the
/// same thing and agree. These two tables are the observers without that blind
/// spot - one at the value layer, one on the lowered module itself - and neither
/// needs the LLVM toolchain, so both still hold where the LLVM arm would skip.
///
/// WHY THE VALUES CAN BE TRUSTED (measured, not asserted)
///
/// `probeGoldens` was taken from the HIR tree walker, so on its own it would only
/// pin today's behaviour. What makes the values the *reading of the arm being
/// retired* rather than a self-portrait is a direct measurement run in the same
/// batch: the still-present AST walk was driven over the same twelve probe
/// sources, and reported **0 disagreements** with these values. That is the same
/// equality the pre-swap `assertParity` asserted, re-measured against the arm
/// itself instead of inferred from a green run.
///
/// `loweringDigests` needs no such cross-check: it observes the lowered module
/// directly, with no execution channel in the loop. Its nominal inventory is
/// sorted by name because `HIRModule`'s declaration order was measured to differ
/// between two runs over one fixture (see the note on `renderDigest`).

extension HIRExecutorTests {

    /// How many entries `loweringDigests` is expected to hold. Checked against
    /// the table's own count, so a dropped key cannot pass as a smaller corpus.
    static let frozenDigestFixtureCount = 83

    /// The frozen stdout of every hand-written probe in `HIRExecutorTests`, keyed
    /// by the probe label. A missing entry is a failure, not a skip: a probe
    /// added without freezing its output would otherwise shrink coverage silently.
    static let probeGoldens: [String: [String]] = [
        "bare-scrutinee literal match and wildcard": ["two", "yes"],
        "defer inside a match arm": ["5", "100", "200", "after"],
        "defer on break/return": ["before-return", "11", "loop-defer", "after"],
        "fall-off-the-end value": ["42"],
        "for-in families": ["1", "2", "3", "slot", "slot", "slot", "a", "1", "b", "2", "5", "6", "3", "7", "11"],
        "for-in step and break": ["1", "inner-step", "2", "after-break"],
        "named-return labels": ["[商: 3, 余: 2]", "3", "[商: 3, 余: 2]", "[3, 2]", "[商: 3, 余: 2]", "3", "[商: 3, 余: 2]"],
        "slice-sugar": ["[20, 30]", "[20, 30, 40, 50]", "[]", "[40]", "ell", "ll"],
        "try handler terminating with pass": ["caught", "after"],
        "tuple-labels": ["[商: 3, 余: 2]", "3", "3", "[1, 2.5]"],
        "unwind depth": ["outer-step", "outer-step", "done", "1", "end"],
        "while-step": ["0", "1"],
    ]

    /// The frozen lowered shape of every fixture named by the affected classes,
    /// keyed by fixture name: one line per statement nested by block, then the
    /// nominal inventory. The rendering rules live in `renderDigest`; its
    /// `switch`es have no `default:`, so a new statement case cannot be lowered
    /// past it unnamed.
    static let loweringDigests: [String: String] = [
        "testDiffArithmeticI32": """
        func main() -> void
          block n=6
            allocVar
            allocVar
            storeVar
            exprStmt
            exprStmt
            returnStmt
        """,
        "testDiffArithmeticI64": """
        func main() -> void
          block n=6
            allocVar
            allocVar
            allocVar
            exprStmt
            exprStmt
            returnStmt
        """,
        "testDiffArrayGetMatch": """
        func main() -> void
          block n=10
            allocVar
            subscriptStore
            matchStmt
            block n=1
              subscriptStore
            block n=1
              panicStmt
            exprStmt
            exprStmt
            allocVar
            whileStmt
            block n=2
              matchStmt
              block n=1
                ifStmt
                block n=2
                  exprStmt
                  breakStmt
              block n=1
                breakStmt
              storeVar
            exprStmt
            matchStmt
            block n=1
              exprStmt
            block n=1
              panicStmt
            returnStmt
        """,
        "testDiffArrayJoin": """
        func main() -> void
          block n=14
            allocVar
            exprStmt
            exprStmt
            exprStmt
            exprStmt
            allocVar
            exprStmt
            allocVar
            exprStmt
            exprStmt
            exprStmt
            exprStmt
            exprStmt
            returnStmt
        """,
        "testDiffArrayRead": """
        func main() -> void
          block n=14
            allocVar
            exprStmt
            exprStmt
            allocVar
            exprStmt
            exprStmt
            allocVar
            exprStmt
            allocVar
            exprStmt
            allocVar
            exprStmt
            exprStmt
            returnStmt
        """,
        "testDiffArrayWrite": """
        func main() -> void
          block n=15
            allocVar
            subscriptStore
            exprStmt
            subscriptStore
            exprStmt
            allocVar
            subscriptStore
            exprStmt
            exprStmt
            allocVar
            allocVar
            subscriptStore
            exprStmt
            exprStmt
            returnStmt
        """,
        "testDiffBitwiseCompound": """
        func main() -> void
          block n=28
            allocVar
            storeVar
            exprStmt
            storeVar
            exprStmt
            storeVar
            exprStmt
            storeVar
            exprStmt
            storeVar
            exprStmt
            allocVar
            exprStmt
            exprStmt
            exprStmt
            exprStmt
            allocVar
            storeVar
            exprStmt
            storeVar
            exprStmt
            storeVar
            exprStmt
            storeVar
            exprStmt
            storeVar
            exprStmt
            returnStmt
        """,
        "testDiffBoolPrint": """
        func main() -> void
          block n=7
            exprStmt
            exprStmt
            allocVar
            exprStmt
            exprStmt
            exprStmt
            returnStmt
        """,
        "testDiffCJKFunctionName": """
        func main() -> void
          block n=2
            exprStmt
            returnStmt
        func 加倍(x:i32) -> i32
          block n=1
            returnStmt
        """,
        "testDiffCallFunction": """
        func add(x:i32,y:i32) -> i32
          block n=1
            returnStmt
        func half(n:i32) -> i32
          block n=1
            returnStmt
        func main() -> void
          block n=3
            exprStmt
            exprStmt
            returnStmt
        """,
        "testDiffClosures": """
        func main() -> void
          block n=11
            allocVar
            exprStmt
            allocVar
            allocVar
            exprStmt
            storeVar
            exprStmt
            exprStmt
            exprStmt
            exprStmt
            returnStmt
        func 加倍(n:i32) -> i32
          block n=1
            returnStmt
        func 应用(f:function(params: [PiniCore.HIRType.i32], returnType: Optional(PiniCore.HIRType.i32)),x:i32) -> i32
          block n=1
            returnStmt
        """,
        "testDiffCollections": """
        func main() -> void
          block n=21
            allocVar
            exprStmt
            exprStmt
            exprStmt
            allocVar
            exprStmt
            exprStmt
            allocVar
            exprStmt
            exprStmt
            allocVar
            exprStmt
            allocVar
            exprStmt
            allocVar
            exprStmt
            exprStmt
            exprStmt
            exprStmt
            exprStmt
            returnStmt
        """,
        "testDiffComparisonSet": """
        func main() -> void
          block n=9
            allocVar
            allocVar
            exprStmt
            exprStmt
            exprStmt
            exprStmt
            exprStmt
            exprStmt
            returnStmt
        """,
        "testDiffContinueBreakLabel": """
        func main() -> void
          block n=5
            allocVar
            whileStmt
            block n=3
              storeVar
              ifStmt
              block n=1
                continueStmt
              exprStmt
            allocVar
            whileStmt
            block n=3
              allocVar
              whileStmt
              block n=3
                ifStmt
                block n=1
                  breakStmt
                exprStmt
                storeVar
              storeVar
            returnStmt
        """,
        "testDiffCow": """
        func main() -> void
          block n=30
            allocVar
            allocVar
            subscriptStore
            exprStmt
            exprStmt
            allocVar
            allocVar
            subscriptStore
            exprStmt
            exprStmt
            allocVar
            allocVar
            subscriptStore
            exprStmt
            exprStmt
            allocVar
            allocVar
            allocVar
            subscriptStore
            subscriptStore
            exprStmt
            exprStmt
            allocVar
            allocVar
            allocVar
            subscriptStore
            subscriptStore
            exprStmt
            exprStmt
            returnStmt
        """,
        "testDiffDefer": """
        func main() -> void
          block n=9
            allocVar
            allocVar
            whileStmt
            block n=5
              deferStmt
              block n=1
                storeVar
              deferStmt
              block n=1
                storeVar
              deferStmt
              block n=1
                storeVar
              storeVar
              storeVar
            exprStmt
            storeVar
            allocVar
            whileStmt
            block n=4
              deferStmt
              block n=1
                storeVar
              allocVar
              whileStmt
              block n=3
                deferStmt
                block n=1
                  storeVar
                storeVar
                storeVar
              storeVar
            exprStmt
            returnStmt
        """,
        "testDiffDictSet": """
        func main() -> void
          block n=13
            allocVar
            exprStmt
            exprStmt
            allocVar
            subscriptStore
            subscriptStore
            exprStmt
            exprStmt
            allocVar
            exprStmt
            allocVar
            exprStmt
            returnStmt
        """,
        "testDiffEmptyArray": """
        func main() -> void
          block n=3
            allocVar
            exprStmt
            returnStmt
        """,
        "testDiffEnum": """
        func main() -> void
          block n=5
            allocVar
            allocVar
            exprStmt
            exprStmt
            returnStmt
        func 面积(s:enumeration(name: "形状")) -> f64
          block n=1
            matchStmt
            block n=1
              returnStmt
            block n=1
              returnStmt
        enum 形状 cases=圆:1,矩形:2
        """,
        "testDiffEnumNamed": """
        func main() -> void
          block n=5
            exprStmt
            exprStmt
            exprStmt
            exprStmt
            returnStmt
        func 具名取文本(t:enumeration(name: "Token")) -> string
          block n=2
            matchStmt
            block n=1
              returnStmt
            block n=1
              returnStmt
            returnStmt
        func 取位置(t:enumeration(name: "Token")) -> i32
          block n=2
            matchStmt
            block n=1
              returnStmt
            block n=1
              returnStmt
            returnStmt
        func 取文本(t:enumeration(name: "Token")) -> string
          block n=2
            matchStmt
            block n=1
              returnStmt
            block n=1
              returnStmt
            returnStmt
        enum Token cases=identifier:2,plus:0
        """,
        "testDiffEnumTypedField": """
        func main() -> void
          block n=5
            allocVar
            fieldStore
            allocVar
            matchStmt
            block n=1
              exprStmt
            block n=1
              exprStmt
            returnStmt
        type 盒 fields=内色:enumeration(name: "色")
        enum 色 cases=红:0,蓝:0
        """,
        "testDiffFloatCompare": """
        func main() -> void
          block n=12
            allocVar
            allocVar
            exprStmt
            exprStmt
            exprStmt
            exprStmt
            exprStmt
            exprStmt
            exprStmt
            exprStmt
            ifStmt
            block n=1
              exprStmt
            returnStmt
        """,
        "testDiffFloatPrint": """
        func main() -> void
          block n=12
            allocVar
            exprStmt
            exprStmt
            exprStmt
            exprStmt
            exprStmt
            exprStmt
            exprStmt
            exprStmt
            exprStmt
            exprStmt
            returnStmt
        """,
        "testDiffForIn": """
        func main() -> void
          block n=17
            allocVar
            forInStmt
            block n=1
              storeVar
            exprStmt
            allocVar
            allocVar
            forInStmt
            block n=1
              storeVar
            exprStmt
            allocVar
            forInStmt
            block n=1
              storeVar
            exprStmt
            allocVar
            forInStmt
            block n=2
              ifStmt
              block n=1
                breakStmt
              storeVar
            exprStmt
            allocVar
            forInStmt
            block n=1
              storeVar
            exprStmt
            returnStmt
        """,
        "testDiffGenericFunc": """
        func main() -> void
          block n=3
            exprStmt
            exprStmt
            returnStmt
        func 身份_I32(x:i32) -> i32
          block n=1
            returnStmt
        func 身份_String(x:string) -> string
          block n=1
            returnStmt
        """,
        "testDiffGenericStruct": """
        func main() -> void
          block n=7
            allocVar
            fieldStore
            exprStmt
            allocVar
            fieldStore
            exprStmt
            returnStmt
        type 盒_I32 fields=内容:i32
          method _u53D6___u76D2_I32(self:nominal(name: "盒_I32", isObject: false)) -> i32
          block n=1
            returnStmt
        type 盒_String fields=内容:string
          method _u53D6___u76D2_String(self:nominal(name: "盒_String", isObject: false)) -> string
          block n=1
            returnStmt
        """,
        "testDiffHeterogeneousLiteralArm": """
        func main() -> void
          block n=2
            matchStmt
            block n=1
              exprStmt
            block n=1
              exprStmt
            block n=1
              exprStmt
            returnStmt
        """,
        "testDiffHigherOrder": """
        func main() -> void
          block n=5
            exprStmt
            exprStmt
            allocVar
            exprStmt
            returnStmt
        func 加一(n:i32) -> i32
          block n=1
            returnStmt
        func 加倍(n:i32) -> i32
          block n=1
            returnStmt
        func 应用(f:function(params: [PiniCore.HIRType.i32], returnType: Optional(PiniCore.HIRType.i32)),x:i32) -> i32
          block n=1
            returnStmt
        """,
        "testDiffI8StructField": """
        func main() -> void
          block n=6
            allocVar
            fieldStore
            fieldStore
            exprStmt
            exprStmt
            returnStmt
        type 点 fields=x:i8,y:i8
          method _u8DDD_u79BB_u539F_u70B9___u70B9(self:nominal(name: "点", isObject: false)) -> i8
          block n=1
            returnStmt
        """,
        "testDiffIfElifElse": """
        func main() -> void
          block n=3
            allocVar
            ifStmt
            block n=1
              exprStmt
            block n=1
              ifStmt
              block n=1
                exprStmt
              block n=1
                exprStmt
            returnStmt
        """,
        "testDiffIfElse": """
        func main() -> void
          block n=5
            allocVar
            ifStmt
            block n=1
              exprStmt
            block n=1
              exprStmt
            storeVar
            ifStmt
            block n=1
              exprStmt
            block n=1
              exprStmt
            returnStmt
        """,
        "testDiffIoFile": """
        func main() -> void
          block n=4
            allocVar
            exprStmt
            exprStmt
            returnStmt
        """,
        "testDiffIoProgramBase": """
        func main() -> void
          block n=4
            exprStmt
            exprStmt
            exprStmt
            returnStmt
        """,
        "testDiffIsAsciiDigit": """
        func main() -> void
          block n=4
            ifStmt
            block n=1
              exprStmt
            ifStmt
            block n=1
              exprStmt
            exprStmt
            returnStmt
        """,
        "testDiffLambda": """
        func main() -> void
          block n=3
            allocVar
            exprStmt
            returnStmt
        """,
        "testDiffLambdaTyped": """
        func main() -> void
          block n=5
            allocVar
            exprStmt
            exprStmt
            exprStmt
            returnStmt
        func 应用(f:function(params: [PiniCore.HIRType.i32], returnType: Optional(PiniCore.HIRType.i32)),x:i32) -> i32
          block n=1
            returnStmt
        """,
        "testDiffLazyRef": """
        func main() -> void
          block n=6
            allocVar
            exprStmt
            exprStmt
            allocVar
            exprStmt
            returnStmt
        """,
        "testDiffLexical": """
        func main() -> void
          block n=21
            allocVar
            allocVar
            allocVar
            exprStmt
            exprStmt
            exprStmt
            allocVar
            allocVar
            allocVar
            exprStmt
            exprStmt
            exprStmt
            exprStmt
            exprStmt
            allocVar
            allocVar
            exprStmt
            exprStmt
            exprStmt
            exprStmt
            returnStmt
        """,
        "testDiffMultiTypes": """
        func describe(name:string,count:i32) -> string
          block n=1
            returnStmt
        func flag(b:boolean) -> boolean
          block n=1
            returnStmt
        func main() -> void
          block n=3
            exprStmt
            exprStmt
            returnStmt
        """,
        "testDiffMultidimArray": """
        func main() -> void
          block n=8
            allocVar
            matchStmt
            block n=1
              matchStmt
              block n=1
                exprStmt
              block n=1
                panicStmt
            block n=1
              panicStmt
            exprStmt
            allocVar
            subscriptStore
            subscriptStore
            exprStmt
            returnStmt
        """,
        "testDiffNestedIfInWhile": """
        func main() -> void
          block n=3
            allocVar
            whileStmt
            block n=2
              ifStmt
              block n=1
                exprStmt
              block n=1
                exprStmt
              storeVar
            returnStmt
        """,
        "testDiffNoTrailingReturn": """
        func main() -> void
          block n=2
            allocVar
            exprStmt
        """,
        "testDiffObjectReference": """
        func main() -> void
          block n=6
            allocVar
            exprStmt
            exprStmt
            exprStmt
            exprStmt
            returnStmt
        type 计数对象 object fields=数值:i32
          method _u589E_u52A0___u8BA1_u6570_u5BF9_u8C61(self:nominal(name: "计数对象", isObject: true)) -> void
          block n=2
            fieldStore
            returnStmt
          method _u83B7_u53D6_u503C___u8BA1_u6570_u5BF9_u8C61(self:nominal(name: "计数对象", isObject: true)) -> i32
          block n=1
            returnStmt
        """,
        "testDiffOptionalDirect": """
        func main() -> void
          block n=17
            allocVar
            matchStmt
            block n=1
              exprStmt
            block n=1
              exprStmt
            allocVar
            matchStmt
            block n=1
              exprStmt
            block n=1
              exprStmt
            allocVar
            matchStmt
            block n=1
              exprStmt
            allocVar
            matchStmt
            block n=1
              exprStmt
            allocVar
            matchStmt
            block n=1
              exprStmt
            allocVar
            matchStmt
            block n=1
              exprStmt
            allocVar
            matchStmt
            block n=1
              exprStmt
            allocVar
            matchStmt
            block n=1
              exprStmt
            returnStmt
        """,
        "testDiffParamNoAnnotationReturn": """
        func add(x:i32,y:i32) -> i32
          block n=1
            returnStmt
        func main() -> void
          block n=3
            exprStmt
            exprStmt
            returnStmt
        """,
        "testDiffParamNoAnnotationVoid": """
        func add(x:i32,y:i32) -> void
          block n=2
            exprStmt
            returnStmt
        func main() -> void
          block n=2
            exprStmt
            returnStmt
        """,
        "testDiffPassingAssert": """
        func main() -> void
          block n=6
            exprStmt
            exprStmt
            exprStmt
            exprStmt
            exprStmt
            returnStmt
        """,
        "testDiffPointerLoad": """
        func main() -> void
          block n=4
            allocVar
            allocVar
            exprStmt
            returnStmt
        """,
        "testDiffPointerStore": """
        func main() -> void
          block n=6
            allocVar
            allocVar
            exprStmt
            exprStmt
            exprStmt
            returnStmt
        """,
        "testDiffPrintMultiArgs": """
        func main() -> void
          block n=4
            exprStmt
            exprStmt
            exprStmt
            returnStmt
        """,
        "testDiffReadFileTruncates": """
        func main() -> void
          block n=7
            allocVar
            allocVar
            allocVar
            whileStmt
            block n=2
              storeVar
              storeVar
            exprStmt
            exprStmt
            returnStmt
        """,
        "testDiffReadLineKeepsTerminator": """
        func main() -> void
          block n=2
            exprStmt
            returnStmt
        """,
        "testDiffRecursion": """
        func fib(n:i32) -> i32
          block n=2
            ifStmt
            block n=1
              returnStmt
            returnStmt
        func main() -> void
          block n=2
            exprStmt
            returnStmt
        """,
        "testDiffSlice": """
        func main() -> void
          block n=21
            allocVar
            exprStmt
            exprStmt
            exprStmt
            exprStmt
            exprStmt
            exprStmt
            exprStmt
            exprStmt
            exprStmt
            exprStmt
            exprStmt
            exprStmt
            allocVar
            exprStmt
            exprStmt
            exprStmt
            exprStmt
            exprStmt
            exprStmt
            returnStmt
        """,
        "testDiffStdlib": """
        func main() -> void
          block n=16
            allocVar
            exprStmt
            exprStmt
            exprStmt
            exprStmt
            exprStmt
            allocVar
            exprStmt
            exprStmt
            exprStmt
            exprStmt
            exprStmt
            exprStmt
            exprStmt
            exprStmt
            returnStmt
        """,
        "testDiffStep": """
        func main() -> void
          block n=6
            allocVar
            whileStmt
            block n=2
              exprStmt
              storeVar
            block n=1
              exprStmt
            allocVar
            whileStmt
            block n=3
              exprStmt
              storeVar
              ifStmt
              block n=1
                breakStmt
            block n=1
              exprStmt
            forInStmt
            block n=1
              exprStmt
            block n=1
              exprStmt
            returnStmt
        """,
        "testDiffStringCase": """
        func main() -> void
          block n=9
            allocVar
            exprStmt
            exprStmt
            exprStmt
            exprStmt
            exprStmt
            exprStmt
            exprStmt
            returnStmt
        """,
        "testDiffStringContains": """
        func main() -> void
          block n=10
            allocVar
            exprStmt
            exprStmt
            exprStmt
            exprStmt
            exprStmt
            exprStmt
            exprStmt
            exprStmt
            returnStmt
        """,
        "testDiffStringEquality": """
        func main() -> void
          block n=6
            allocVar
            allocVar
            allocVar
            exprStmt
            exprStmt
            returnStmt
        """,
        "testDiffStringPrint": """
        func main() -> void
          block n=4
            exprStmt
            allocVar
            exprStmt
            returnStmt
        """,
        "testDiffStringSplit": """
        func main() -> void
          block n=29
            allocVar
            allocVar
            exprStmt
            exprStmt
            allocVar
            exprStmt
            exprStmt
            allocVar
            exprStmt
            exprStmt
            allocVar
            exprStmt
            exprStmt
            allocVar
            exprStmt
            exprStmt
            allocVar
            exprStmt
            exprStmt
            allocVar
            exprStmt
            exprStmt
            allocVar
            exprStmt
            exprStmt
            allocVar
            exprStmt
            exprStmt
            returnStmt
        """,
        "testDiffStringSubstring": """
        func main() -> void
          block n=8
            allocVar
            exprStmt
            exprStmt
            exprStmt
            exprStmt
            exprStmt
            exprStmt
            returnStmt
        """,
        "testDiffStructComposition": """
        func main() -> void
          block n=8
            allocVar
            exprStmt
            exprStmt
            exprStmt
            exprStmt
            exprStmt
            exprStmt
            returnStmt
        type 倒计数 fields=计数器:nominal(name: "计数器", isObject: false),步长:i32,数值:i32,标签:string
          method _u51CF_u5C11___u5012_u8BA1_u6570(self:nominal(name: "倒计数", isObject: false)) -> void
          block n=2
            fieldStore
            returnStmt
          method _u589E_u52A0___u5012_u8BA1_u6570(self:nominal(name: "倒计数", isObject: false)) -> void
          block n=2
            fieldStore
            returnStmt
          method _u63CF_u8FF0___u5012_u8BA1_u6570(self:nominal(name: "倒计数", isObject: false)) -> void
          block n=2
            exprStmt
            returnStmt
        type 计数器 fields=数值:i32,标签:string
          method _u589E_u52A0___u8BA1_u6570_u5668(self:nominal(name: "计数器", isObject: false)) -> void
          block n=2
            fieldStore
            returnStmt
          method _u63CF_u8FF0___u8BA1_u6570_u5668(self:nominal(name: "计数器", isObject: false)) -> void
          block n=2
            exprStmt
            returnStmt
        """,
        "testDiffStructI8Fields": """
        func main() -> void
          block n=5
            allocVar
            exprStmt
            exprStmt
            exprStmt
            returnStmt
        type 计数器 fields=名称:string,周期:i8,步长:i32
          method _u83B7_u53D6_u5468_u671F___u8BA1_u6570_u5668(self:nominal(name: "计数器", isObject: false)) -> i8
          block n=1
            returnStmt
        """,
        "testDiffStructValue": """
        func main() -> void
          block n=7
            allocVar
            fieldStore
            fieldStore
            exprStmt
            exprStmt
            exprStmt
            returnStmt
        type 点 fields=x:f64,y:f64
          method _u8DDD_u79BB_u539F_u70B9___u70B9(self:nominal(name: "点", isObject: false)) -> f64
          block n=1
            returnStmt
        """,
        "testDiffTrait": """
        func main() -> void
          block n=3
            allocVar
            exprStmt
            returnStmt
        type 狗 fields=名字:string
          method _u63CF_u8FF0___u72D7(self:nominal(name: "狗", isObject: false)) -> string
          block n=1
            returnStmt
        """,
        "testDiffTraitDefaultMethod": """
        func describe__Circle(self:nominal(name: "Circle", isObject: false)) -> i32
          block n=1
            returnStmt
        func main() -> void
          block n=3
            allocVar
            exprStmt
            returnStmt
        type Circle fields=
        """,
        "testDiffTryElse": """
        func main() -> void
          block n=3
            tryStmt
            block n=2
              exprStmt
              returnStmt
            exprStmt
            returnStmt
        func 失败(标志:boolean) -> result(ok: PiniCore.HIRType.string)
          block n=2
            ifStmt
            block n=1
              returnStmt
            returnStmt
        """,
        "testDiffTryElseOk": """
        func main() -> void
          block n=5
            allocVar
            tryStmt
            block n=1
              returnStmt
            exprStmt
            exprStmt
            returnStmt
        func 成功() -> result(ok: PiniCore.HIRType.i32)
          block n=1
            returnStmt
        """,
        "testDiffTryElseSugar": """
        func main() -> void
          block n=4
            allocVar
            tryStmt
            block n=1
              returnStmt
            exprStmt
            returnStmt
        func 成功() -> result(ok: PiniCore.HIRType.i32)
          block n=1
            returnStmt
        """,
        "testDiffTupleConstruct": """
        func main() -> void
          block n=5
            allocVar
            allocVar
            allocVar
            exprStmt
            returnStmt
        """,
        "testDiffTupleConstructClang": """
        func main() -> void
          block n=5
            allocVar
            allocVar
            allocVar
            exprStmt
            returnStmt
        """,
        "testDiffTupleDestructure": """
        func main() -> void
          block n=6
            allocVar
            allocVar
            allocVar
            exprStmt
            exprStmt
            returnStmt
        func 除余(a:i32,b:i32) -> tuple(labels: [nil, nil], fieldTypes: [PiniCore.HIRType.i32, PiniCore.HIRType.i32])
          block n=1
            returnStmt
        """,
        "testDiffTupleIndexAccess": """
        func main() -> void
          block n=4
            allocVar
            exprStmt
            exprStmt
            returnStmt
        """,
        "testDiffTupleLabels": """
        func main() -> void
          block n=9
            allocVar
            exprStmt
            exprStmt
            exprStmt
            allocVar
            exprStmt
            allocVar
            exprStmt
            returnStmt
        func 位置(a:i32,b:i32) -> tuple(labels: [nil, nil], fieldTypes: [PiniCore.HIRType.i32, PiniCore.HIRType.i32])
          block n=1
            returnStmt
        func 除余(a:i32,b:i32) -> tuple(labels: [Optional("商"), Optional("余")], fieldTypes: [PiniCore.HIRType.i32, PiniCore.HIRType.i32])
          block n=1
            returnStmt
        """,
        "testDiffTupleLen": """
        func main() -> void
          block n=3
            allocVar
            exprStmt
            returnStmt
        """,
        "testDiffTupleReturn": """
        func main() -> void
          block n=3
            allocVar
            exprStmt
            returnStmt
        func 除余(a:i32,b:i32) -> tuple(labels: [nil, nil], fieldTypes: [PiniCore.HIRType.i32, PiniCore.HIRType.i32])
          block n=1
            returnStmt
        """,
        "testDiffUnary": """
        func main() -> void
          block n=6
            allocVar
            exprStmt
            storeVar
            exprStmt
            exprStmt
            returnStmt
        """,
        "testDiffValidatedMatch": """
        func main() -> void
          block n=3
            allocVar
            matchStmt
            block n=1
              exprStmt
            block n=1
              exprStmt
            block n=1
              exprStmt
            block n=1
              exprStmt
            returnStmt
        enum 方向 cases=东:0,南:0,西:0,北:0
        """,
        "testDiffValueFormat": """
        func main() -> void
          block n=8
            exprStmt
            exprStmt
            exprStmt
            exprStmt
            allocVar
            exprStmt
            exprStmt
            returnStmt
        """,
        "testDiffVoidFunction": """
        func greet() -> void
          block n=2
            exprStmt
            returnStmt
        func main() -> void
          block n=3
            exprStmt
            exprStmt
            returnStmt
        """,
        "testDiffWhileSum": """
        func main() -> void
          block n=5
            allocVar
            allocVar
            whileStmt
            block n=2
              storeVar
              storeVar
            exprStmt
            returnStmt
        """,
        "testDiffWriteFileCode": """
        func main() -> void
          block n=4
            allocVar
            exprStmt
            exprStmt
            returnStmt
        """,
    ]
}
