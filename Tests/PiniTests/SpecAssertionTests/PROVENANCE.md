# Provenance of the `.expected` files

Every expectation in this directory was **written by hand from the language
specification**, not captured from a running implementation. That distinction is
the reason this corpus exists: layer 1 and layer 2 of the judgement stack both
compare implementations against each other, so they cannot see a mistake that
all implementations share. This directory is the only place where behaviour is
checked against the spec itself.

If an `.expected` here is ever produced by copying a channel's output, layer 3
silently degrades into layer 1 — it would then only ever confirm that the
implementation agrees with itself. `tools/hir-spec-assert.py --generate` is
therefore gated behind `--force`, refuses to write when the channels disagree,
and stamps anything it writes as `GENERATED` at the bottom of this file.

## Cases — value display face

| case | printed expression | expected stdout | spec anchor | provenance |
|---|---|---|---|---|
| `f64Fixed1e15` | `1e15` | `1000000000000000.0` | §2.8 rule 2 (in range → fixed) | hand-written |
| `f64Exp1e16` | `1e16` | `1e+16` | §2.8 rule 2 (out of range → exponent) | hand-written |
| `f64Fixed1em4` | `0.0001` | `0.0001` | §2.8 rule 2 (in range → fixed) | hand-written |
| `f64Exp1em5` | `0.00001` | `1e-05` | §2.8 rule 2 (out of range → exponent) | hand-written |
| `f64FixedTrailingPoint` | `1000000.0` | `1000000.0` | §2.8 rule 3 | hand-written |
| `f64IntegerValued` | `2.0` | `2.0` | §2.8 rule 3 (integer-valued float) | hand-written |
| `f64Exp1e21` | `1e21` | `1e+21` | §2.8 rule 4 (two-digit exponent) | hand-written |
| `f64Half` | `0.5` | `0.5` | §2.8 rule 2 (derived) | hand-written |
| `boolTrue` | `true` | `true` | §2.8 (Bool) | hand-written |
| `boolFalse` | `false` | `false` | §2.8 (Bool) | hand-written |
| `i32Plain` | `42` | `42` | §2.8 (I32 decimal literal form) | hand-written |
| `f64OneTenth` | `0.1` | `0.1` | §2.8 rule 1 (shortest round-trip) | hand-written |

The four boundary values under rule 2 and the two under rule 3/4 are quoted
verbatim from `docs/spec/pini-spec-v0.md` §2.8 — no value in this table was
derived by observing an implementation.

## Cases — label semantics face

Added 2026-09-17. Each expectation is derived from a clause of the
specification; where the derivation needs a step, the step is stated in the
provenance column so a reader can disagree with the reasoning rather than with
the value.

| case | construct | expected stdout | spec anchor | provenance |
|---|---|---|---|---|
| `labelWhileBreak` | `outer\|while` nested over an unlabeled `while`, `break outer` | `0\n1\nend\n` | reference「标签」节完整例；§2.4.1「`break 标签` 按标签名定向」 | hand-written |
| `labelWhileContinue` | `inner\|while` + `continue inner`, `m` advances before the test so each outer pass adds 1+3+4 | `24\n` | reference「标签」节完整例；§6.6「`continue 标签` 按名定向」 | hand-written |
| `breakUnlabeled` | `break` with no label | `0\n1\ndone\n` | EBNF `break-stmt ::= 'break' [IDENT]`（标签可选）；§6.6「不携带值」 | hand-written |
| `continueUnlabeled` | `continue` with no label | `1\n2\n4\n5\n` | EBNF `continue-stmt ::= 'continue' [IDENT]`；§6.6 | hand-written |
| `labelForBreak` | `outer\|for` + `break outer` | `3\n` | §2.4.1「标签经 `标签\|for` 定向」；EBNF `for-stmt ::= [IDENT '\|'] 'for' …` | hand-written |
| `labelForContinue` | `continue outer` out of a nested `for` into the outer `for` | `320\n` | §6.6「仅循环标签有效」（for 是循环 ⇒ 合法）；§2.4.1「按标签名定向」 | hand-written — **red on `llvm-hir`**, now ticketed; see below |
| `labelNestedCrossTwo` | three levels; `break b` leaves two of them, skipping the body's `M` marker | `xxNxxN\n` | §2.4.1「按标签名定向」；reference 例（跳出指定层） | hand-written |
| `labelIfNoBreak` | `tag\|if` with no `break` — the label is legal on `if` but unused | `then\nafter\n` | EBNF `if-stmt ::= [IDENT '\|'] 'if' …`；§2.4.1「标签落在 if/while/for 上」 | hand-written |
| `labelNotBitwiseOr` | `run\|while` at statement position | `3\n` | §A.4 rule 3.13（`IDENT '\|'` 后是 `while` ⇒ 带标签语句，不是按位或） | hand-written |
| `labelForWithStep` | `outer\|for` **with** a `step:` block, plus a second `other\|for` using `break other` | `9\n3\n` | EBNF `for-stmt … ['step' control-block]`；reference「while / step」节「`step` 块在每个循环末尾执行」 | hand-written — step 是**每轮**末尾（由 EBNF 里 `step` 紧跟循环块的位置与「每个循环末尾」推出）；两个循环**分开**写，以免依赖「`break` 跳过 step」这条**无规范条款**的细则（见面外发现 3） |
| `labelInnerShadowing` | two nested loops both labeled `same`; `break same` | `0\n0\n` | ADR-039 D2（内层同名标签遮蔽/最近匹配）；规范 §3 G61 | hand-written — 依据是本批**新登记**的规则，此前无条款（对照：若外层胜出则只有一次 `0`） |
| `labelNamespaceSeparate` | `var outer = 5` and a loop labeled `outer`; the body prints `outer` | `5\n5\n` | ADR-039 D3（标签与变量独立命名空间）；规范 §3 G61 | hand-written — 同上，依据是本批新登记的规则 |
| `labelBreakToIfTarget` | `outer\|if` + `break outer` out of the `if` block | `before\nafter\n` | ADR-039 D1（`break 标签` 可定向任意带标签结构，含 `if` 块）；EBNF 对 `break` 不设循环限制、对 `continue` 明设 | hand-written — went in **red on two channels** as the red spec for the ADR-039 implementation, and closed there; see below |

## What is asserted

- stdout, byte for byte.
- exit code (the carrier assumes success, so `rc == 0`).

stderr is deliberately **not** asserted. A batch of known diagnostic-channel
asymmetries lives there; folding them in on day one would bury a new instrument
under defects that are already ticketed elsewhere. Revisit once that ticket is
closed.

## Discriminating power (measured, not assumed)

A corpus that is green proves nothing on its own — it proves something only if a
deliberate break turns it red. Both sides of the F64 display path (the
interpreter's `stringifyValue` and the runtime's `bk_double_to_string`) were
mutated to the historical `%.6f` form and the corpus re-run:

- 27 of 36 assertions went red — precisely the 9 float cases, while the 3
  boolean/integer cases stayed green. The capture is family-scoped, not global.
- All three channels printed the same wrong text (`0.000100`), so the
  layer-1 comparison, which only checks the channels against each other, stayed
  green throughout. It could not see the defect at all.

That is the whole case for this directory: it catches a shared
misreading of the spec, which is the one thing the other two layers cannot do.

Baseline and readings for the label-semantics face (same instrument):

| reading | result |
|---|---|
| before the face was added | **36 assertions over 12 cases, 36 ok, 0 failed** |
| face added, implementation not yet done | **75 assertions over 25 cases, 72 ok, 3 failed** |
| ADR-039 implemented (this batch's implementation segment) | **75 assertions over 25 cases, 74 ok, 1 failed** |
| same, with the `interp-ast` channel removed | **50 assertions over 25 cases, 49 ok, 1 failed** |

The face went in red **on purpose**: the defect gets recorded in a
machine-readable form rather than in prose, and the implementation then has a
target that cannot be talked around. The single remaining failure is
`labelForContinue`, which was discovered by this face and is **not** part of
ADR-039 — see below.

The fourth row is the flip-readiness reading. `interp-ast` is the frozen
reference and is scheduled for deletion at the P4 flip, so a face that only holds
while that channel is present is not a face the flip can rely on. Every case in
this face except the ticketed red stands on the two HIR channels alone.

## Red cases and their owners

The face went in with two reds. One has since been implemented; the other is
still red and now has a ticket.

| case | channel(s) | measured | owner |
|---|---|---|---|
| `labelForContinue` | `llvm-hir` (`DIFF`) | `interp-ast` and `interp-hir` both print `320` (the expected value); `llvm-hir` exits 0 with **no stdout and no stderr** | Filed as its own ticket at the ADR-039 implementation segment. Not part of ADR-039 — the first run of this face caught it. Evidence below |
| ~~`labelBreakToIfTarget`~~ | — | **now green on all three channels** (`75 assertions over 25 cases: 74 ok, 1 failed` after the implementation segment) | ADR-039 D1 — done. It was the red spec for that implementation through the whole lowering/executor/IR work; see "The first red, and how it closed" below |

### The first red, and how it closed

`labelBreakToIfTarget` was red on `interp-hir` (`rc=1`, `E5-006` /
`break outside loop`) and on `llvm-hir` (no stdout, rc 0) while `interp-ast`
printed the expected `before` / `after`. Both HIR backends inherited the cause
from `HIRLowerer`, which discarded the `label` that `Statement.ifStatement`
already carried.

The fix widened the lowering-side frame stack from loops to **interruptible
frames** (a labeled `if` is one; it is not a `continue` target), added `label` to
`HIRStmt.ifStmt`, made `HIRExecutor` catch a matching `break` at the `if`, and
gave `IREmitter` an `if.end.N` exit for such frames. Depth is counted in frames
unwound from the innermost one, target included, so an **unlabeled** signal
stays transparent to a labeled `if` on its way out — the one new invariant this
change introduces, and the reason the probes below exist. All three hold on all
three channels, judged against `interp-ast` as the frozen reference:

| probe | shape | expected | measured |
|---|---|---|---|
| unlabeled `break` through a labeled `if` | `while` › `inner\|if` › `break` | `0,1,done` | all three agree |
| unlabeled `continue` through a labeled `if` | `while` › `inner\|if` › `continue` | `1,2,4,5,done` | all three agree |
| `break <label>` out of an **`elif`** body | `outer\|if` / `elif` | `b,after` | all three agree |
| `break <label>` out of an **`else`** body | `outer\|if` / `else` | `b,after` | all three agree |
| nested labeled `if`s, `break` the outer | `outer\|if` › `inner\|if` | `o,i,after` | all three agree |
| doubly nested labeled `if`s, unlabeled `break` | `while` › `A\|if` › `B\|if` › `break` | `1,done` | all three agree |
| `continue <label>` to an outer `for` from a labeled `if` | `outer\|for` › `tag\|if` › `continue outer` | `10` | both interpreters `10`; **`llvm-hir` empty** |

That last row is a second instance of the `labelForContinue` defect, reachable
through a labeled `if` rather than through a nested loop. It is recorded here
because it shows the defect is not confined to the shape that first exposed it.

`labelForContinue` is the interesting one, because the symptom is silent. The
minimal form is two nested `for` loops whose outer one is labeled, with a
`continue <label>` inside the inner:

```
outer|for (v,) in [1, 2, 3]:
    for (w,) in [10, 20]:
        if v == 2:
            continue outer
        s = s + 1
```

Both interpreters print `4`. The LLVM arm prints nothing and reports success.
Isolation (each one run on all three channels):

| form | `interp-ast` / `interp-hir` | `llvm-hir` |
|---|---|---|
| `continue` to an outer **`while`**, no step (depth 2) | agree | agrees |
| `continue` to an outer **`while`** from an inner **`for`**, no step (depth 2) | agree | agrees |
| `break` to an outer **`for`** (depth 2) | agree | agrees |
| **`continue` to an outer `for`** (depth 2) | `320` / `4` | **empty** |
| **`continue` to an outer `while` that has a `step:` block** (depth 2) | `20` | **`0`** |
| **`continue` to an outer `for` that has a `step:` block** (depth 2) | `300` | **empty** |

The last two rows were measured after the first four, and they correct the
initial reading of the defect's scope. It is **not** specific to `for`: it is
specific to any target frame whose **entry** and **"next iteration"** labels
differ. For a `while` without a step those two are the same block, which is the
only reason the defect stayed invisible in the most common shape.

The emitted IR shows why: a depth-1 `continue` inside a `for` branches to that
loop's increment label, while a depth-2 `continue` branches to `for.cond.N` —
the bounds check — **skipping `for.inc.N`**, the index increment. `IREmitter`
uses the frame's `header` for depth > 1. `header` is the loop's *entry*; the
step entry (or the increment) is `continueTarget`. The two coincide only for a
loop with neither a step nor an increment, so the `while`-without-step rows above
agree by accident of layout, not because that path is right.

Running that IR straight through `lli` (with the runtime library dlopened)
terminates with **signal 4**, stdout and stderr both empty. `run-llvm` discards
`lli`'s exit status — a defect that is already ticketed on its own — so the
crash reaches this corpus as "rc 0, no output", and reaches it at all only
because an absolute expectation exists to compare against.

## Out-of-face findings (measured, deliberately not asserted here)

Recorded so the next reader does not have to re-derive them, and so nobody
"fixes" the corpus by adjusting an expectation.

1. **Rule 3.13's fallback branch is unreachable today.** The rule says that in
   statement position, `IDENT '|'` followed by something other than
   `if`/`while`/`for` falls back to a bitwise-or expression. That fallback
   cannot succeed: `|` has no binary form in the parser's operator chain, while
   `&`, `^`, `<<`, `>>` all do. Positive control on the same shape:
   `print(a & b)` → `2`, `print(a ^ b)` → `5`, `print(a << b)` → `48`, and
   `print(a | b)` → `Error: Parse Error [E2-001] … expected ), got |`. The
   grammar declares `bitwise-expr ::= term { ('&' | '|' | '^' | '<<' | '>>') term };`
   in §A, and §2.4.1's construct row for bitwise operators lists `& ^ ~ << >>` —
   without `|`. So the spec disagrees with itself: **six surfaces, 4 saying `|`
   has a binary form** (the `bitwise-expr` production, §A.1.2's "multiple roles"
   note, §A.3's precedence note, and rule 3.13 itself) **against 2 saying it does
   not** (§A.1.2's opText projection table with its reasoned note, and §2.4.1).
   Two of those six sit in §A.1.2, about 280 lines apart, contradicting each
   other. The "does not" side is not an oversight: the opText table is declared
   the authority the differential gate follows, and its note gives a reason
   (`|` also serves as a modifier/label/union delimiter). So the rule that
   depends on the missing form cannot be exercised, and closing this is mostly a
   matter of propagating a decision the spec already made. A rejection-shaped
   case cannot be expressed here (see 2), so this is left unasserted; the
   2026-09-10 ticket that owns it now records the full six-surface count.

2. **The carrier cannot express a case whose correct outcome is a rejection.**
   `check` counts `rc != 0` as a failure for every case, which is right for a
   corpus of programs that are supposed to run, but it means "this program must
   be rejected" has no representation. That is why the retired `scope` block
   label (G44 — the keyword is a reserved error) is **not** in this face: it is
   covered positively by the label forms above, and a negative case would have
   to change the instrument. Worth deciding before the error-propagation face
   is attempted, since that face is largely about rejections.

3. **Two `step` rules live outside the spec.** The only clause is "`step` 块在
   每个循环末尾执行。" (reference, the while/step section). That `break` leaves
   without running the step block, and that `continue` still runs it, appear in
   the `examples/step.pini` header and in a differential fixture's comment —
   not in the reference. `labelForWithStep` is therefore written so that neither
   rule has to be assumed; the pair is recorded here as a documentation gap.

## Scope

Value display and label semantics — two of the five semantic faces named for
layer 3. The remaining three (error propagation, slice bounds, the `for` step
contract) are deliberately not covered yet; each is its own batch. Error
propagation additionally depends on the open question in finding 2 above.

The label-semantics face was added ahead of its implementation on purpose. Two
of its thirteen cases are expected to be red right now, and they are named with
their owners above; a reader who finds this directory red should read that
section before changing anything.
