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

## Cases

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

## Scope

Value display only — one of the five semantic faces named for layer 3. The other
four (error propagation, slice bounds, the `for` step contract, label semantics)
are deliberately not covered yet; each is its own batch.
