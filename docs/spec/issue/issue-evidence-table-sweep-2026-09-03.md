# Issue: Evidence-table cleanup sweep — automated, dual-trigger (2026-09-03)

- Status: **§1.3 ①proposal + ②impact assessment complete; D-1 – D-5 decided by user 2026-09-03; implementation not started**
- Proposed by: AI; **D-1 – D-5 adjudicated by user** (D-1 "条数统计以 Python 字典载体为准"; D-2 "60 分钟留待刷新，72 小时标成待删"; D-3 "槽位是给 AI 代理或人工看的，基本遵守 0 到 999"; D-4 "先删除标记为待删除的条目，再判定现有条目"; D-5 "Python 脚本只是用来清理的，100 是它的另一个触发器")
- Related: `docs/spec/pini-spec-v0.md` §1.4 (Evidence Freshness), `docs/spec/evidence-table.toml`, `docs/spec/pini-landing-plan-v048.md` (E-008 dangling: lines 46 and 87, both are *instructions* to retire E-008 — they are not evidence citations)

---

## 1. Motivation

**No one can be required to clean the table by hand.** §1.4 obliges every governance pass to re-verify the evidence it touches and to retire what no longer holds, but nothing enforces that obligation: an AI agent begins each session with no memory of the table and no reminder to sweep it, and a human has no trigger either. The obligation is real and the executor is absent. Cleanup therefore has to be **a script**, executed by something other than the party that created the mess.

The measurement below is the proof that the obligation is going unmet, not the motivation itself:

| Fact (measured 2026-09-03 00:44 +08:00) | Value |
|---|---|
| Entries | **101** (dict-carried count, see D-1) |
| Entries with `status = FRESH` | **101** |
| Entries actually inside the 60-minute window | **3** |
| **Status field distortion rate** | **98 / 101** |
| Oldest `validated_at` | 2026-08-25 00:15 |

The `status` field does not attest freshness; it records what someone asserted at write time. A reader trusting it is trusting a 9-day-old claim that was never re-checked. Same drift class as the 819-vs-15 count failure: a number in a document nobody re-measures.

**Goal**: make freshness *derived* (computed from `validated_at` against wall clock) rather than *declared*, and give the overdue tail a terminal state instead of leaving it silently at `FRESH`.

---

## 2. Evidence (measured 2026-09-03 00:44 +08:00)

Measurement: `tomllib.load()` on `docs/spec/evidence-table.toml`, `len(doc["evidence"])`, age bucketed against wall clock.

| Age bucket | Count | Disposition under D-2 |
|---|---|---|
| ≤ 60 min | 3 | `FRESH` |
| > 60 min and ≤ 72 h | 32 | `STALE` (awaiting refresh) |
| > 72 h | **65** | `PENDING_DELETE` candidate |
| (> 30 d, sub-bucket) | 0 | — |

Citation surface — **whole-repo scan**, regex `\bE-?\d{3}\b`, `docs/spec/evidence-table.toml` itself excluded. An earlier `docs/**/*.md`-only scan reported 13 IDs / 18 occurrences and was **wrong by 2×**; the miss is `examples/selfhost/.pini/baseline`, which cites E-067 and E-081:

| Fact | Value |
|---|---|
| Distinct E-IDs cited outside the table | **15** |
| Total citation occurrences | **39** |
| Cited IDs present in table | 13 |
| **Cited but absent from table (dangling)** | **E-008** (2 real occurrences; 10 more are this issue's own discussion of it — see the scan exemption in D-3) |
| Top-cited | E-047 ×6, E-101 ×3, E-035 ×3, E-087 ×3 |
| Non-`docs/` citation sites | `examples/selfhost/.pini/baseline` (E-067, E-081) — **outside `docs/`, invisible to any `docs/`-scoped scan** |

**Delete surface under D-2**: of the 65 `PENDING_DELETE` candidates only **E-035** (×3) and **E-047** (×6) are cited. **61 candidates are zero-reference** and can be dropped without touching any document.

### ID-space occupancy (measured)

| Fact | Value |
|---|---|
| Entries | **101** |
| ID range in use | E-001 … E-102 |
| Slots available (see D-3) | `E-NNN` (three digits), i.e. 1000 |
| Duplicate IDs | none |

No ID-space pressure exists and none is near. An earlier draft of this issue read the range as 000–099, reported E-100 / E-101 / E-102 as "out of range", and proposed renumbering them; that reading was **wrong** (see D-3) and the renumbering step is withdrawn.

---

## 3. Decisions (adjudicated 2026-09-03)

### D-1 · Counting is dict-carried

The **sole authoritative count** of evidence entries is:

```python
len(tomllib.load(open("docs/spec/evidence-table.toml", "rb"))["evidence"])
```

- **Forbidden** as a count: `grep -c '^id = '`, line counts, or any textual tally. Rationale: text tallies count commented-out lines, multi-line strings, and malformed entries; they also contradict §1.4's own promise that the table is *machine-manageable* (`机器可管理/可 diff/可脚本过筛`). If the count cannot be produced by parsing, the table is not machine-manageable regardless of its `.toml` extension.
- Consequence: the sweep script must **load the file, not scan it**. Load failure (TOML syntax error) is a hard error, not a warning — an unparseable table has no count at all.
- The count is the input to the volume trigger (D-5), so this rule is load-bearing rather than cosmetic.

### D-2 · Two-tier expiry: 60 min → await refresh; 72 h → mark for deletion

| Age since `validated_at` | Status | Disposition |
|---|---|---|
| ≤ 60 min | `FRESH` | Trustworthy; may back a spec write |
| > 60 min, ≤ 72 h | `STALE` | **Kept, awaiting refresh**. Retained as a re-verification trace; must not back a spec write |
| > 72 h | `PENDING_DELETE` | **Marked for deletion**. Not deleted immediately — see D-4 |

Rules that follow:

1. **Status is derived, not declared.** Every run recomputes status from `validated_at`. A hand-written `status` disagreeing with the computed value is overwritten, and the disagreement is reported — a persistent disagreement means someone is editing status by hand, which is the failure this issue exists to remove.
2. **Marking is not deleting.** `PENDING_DELETE` never removes an entry by itself.
3. **A cited entry is deleted like any other (D-7).** The sweep grants no exemption for being referenced. Deletion is unconditional; the citations it strands are recorded in `meta.dangling_ids` and printed with their locations. Rationale: exempting cited entries lets them pin themselves in the table forever, and "resolve the reference by hand" is precisely the human action this issue exists to remove. The debt belongs **in the table**, where the next reader is forced to see it, not in a blocking exit code that trains operators to reach for `--no-verify`.
4. **`PENDING_DELETE` is a third status value**, not an alias for `STALE`. §1.4 defined exactly two; adding a third is a spec change and goes through §1.3 before any script lands.

### D-3 · ID space: `E-NNN` (three digits), an identifier for readers, not a budget for the script

- **Format**: `E-NNN`, zero-padded 3 digits, range **0–999** (1000 slots). The earlier reading of "0 to 99" is corrected: the numerals exist so that **a human or an agent can refer to an entry by name**. They are not a resource the script rations.
- **The script does not manage IDs.** It does not allocate them, does not reject an entry because of its ID, does not renumber, and does not gate slot reuse. ID allocation stays with whoever registers the evidence.
- **Consequence**: E-100 / E-101 / E-102 are in range, the previously proposed renumbering is **withdrawn**, and no migration step exists.
- **Scan exemption for self-reference (required).** Discussing an ID inside a governance document registers as a citation — this issue alone mentions E-008 ten times. Without an exemption the sweep would report this issue's own prose as dangling references and the operator could not tell real breakage from discussion. The scan takes an `--exclude` glob list defaulting to `docs/spec/evidence-table.toml` **and this issue**, and reports excluded hits separately so nothing is silently dropped. Corollary for authors: **do not commit a bare unallocated `E-NNN`** — it self-registers as a dangling reference.

### D-4 · Sweep order: delete first, then mark; the grace period is one inter-run interval

Each run performs, in order:

1. **Delete phase** — remove every entry whose status is `PENDING_DELETE` **as of the previous run**. An entry marked in run *N* is deleted in run *N+1* at the earliest, so it survives exactly one full inter-run interval: the operator gets a whole cycle to notice and rescue it.
2. **Mark phase** — recompute statuses for the survivors and mark the newly overdue ones `PENDING_DELETE`.

- **The grace period is not a duration; it is one inter-run interval.** No second timer exists, and none is needed — wanting a longer grace period means running the script less often.
- **The first run is mark-only.** Nothing was previously marked, so nothing is deleted; the 65 overdue entries are marked and the count stays at 101 for one cycle. This is normal, not a failure.
- **Conflict with rule 3, resolved by D-7 (user decision).** D-4 says "delete any entry marked pending-delete"; the earlier rule 3 said a cited entry blocks deletion. They disagreed about E-035 (×3) and E-047 (×6). Resolution: **delete them anyway**, leave the citations dangling, and record them in `meta.dangling_ids`. A dangling reference is the recoverable failure — the referring text names the ID, and the parent commit still holds the deleted entry. A permanently exempt entry is the unrecoverable one, because nothing will ever force anyone to look at it again.
- **A refreshed entry survives.** The delete phase removes an entry only when its status is *both* declared `PENDING_DELETE` and still computed `PENDING_DELETE`. Bumping `validated_at` before the next sweep rescues it. Without this check the grace window would be decorative: refreshing an entry would not save it.

### D-5 · The script is a cleaner; T1 deletes, T2 only warns

**Role**: cleanup only. `evidence_sweep.py` deletes and re-marks. It is not an allocator, not a gate on registration, not a validator of entry content.

| Trigger | Condition | Action |
|---|---|---|
| **T1 · age** | entries marked `PENDING_DELETE` in the previous run (>72 h since `validated_at`, not refreshed since) | **delete them**, cited or not |
| **T2 · volume** | `len(entries) > 100` | **warn only.** No forced deletion, no target level, no oldest-first pass |

- **T1 is the only deletion trigger.** T2 was demoted to advisory by the user: no hard cap, no clean-down level. Table size is bounded by the age rule, not by a number.
- **T2 is still reported, because the two triggers see different things.** T1 cannot touch a burst of freshly registered evidence (dozens of entries in an afternoon, all under 72 h). T2 cannot touch a small table that has quietly rotted (40 entries, all a year old, T2 silent throughout). Today T1 is active — 65 candidates — and T2 is a fuse that has not blown.

### D-6 · The beat is `git commit`; the sweep never depends on anyone remembering

The freshness obligation is real, but nothing can compel an agent or a human to tidy the table by hand: an agent session starts from zero with no reminder, and a human has no trigger. So the sweep rides a beat that already occurs on every change.

- **Mount point**: `hooks/pre-commit`, which is already versioned (`core.hooksPath = hooks`) and already gates committer identity, comment style, and doc links. The sweep block runs **last**, so it rewrites the table only after every other gate has passed.
- **Throttle**: the sweep no-ops while `meta.last_sweep` is younger than 24 h. Without it, "the grace period is one inter-run interval" (D-4) collapses to the gap between two commits — often minutes — and every commit would carry a table diff. **The 24 h floor is therefore both the minimum interval and the real lower bound on the grace window.**
- **Re-staging**: the hook runs `git add -- docs/spec/evidence-table.toml` afterwards. `git commit` builds its tree from the index *after* pre-commit, so the swept table lands inside the commit and the pre-delete state is always in the parent commit.
- **Guards**: (a) if the table has unstaged working-tree edits, skip the sweep — never rewrite a file someone is editing; (b) if `python3` has no `tomllib`, skip with a warning — an environment gap must never block a commit.
- **Accepted hole**: `--no-verify` bypasses the sweep. The sweep is idempotent, so the next ordinary commit catches up. A CI backstop was considered and deferred until a real bypass is observed.

### D-7 · Delete cited entries; record the debt in the table

User decision, against the tentative proposal in the previous draft. Deletion is unconditional (see rule 3 and D-4). What the script owes instead is **visibility**: the deleted IDs that are still referenced are written to `meta.dangling_ids` and printed with every reference location. The debt survives the session that created it, which is the only property that matters — the alternative was a blocking exit code, and a blocked commit gets bypassed, while a recorded debt does not.

---

## 4. Implementation steps (topological, independently verifiable)

| Step | Deliverable | Verification |
|---|---|---|
| S1 | spec §1.4: three-state tier, two-phase sweep order, 24 h minimum interval, commit-hook beat, delete-cited-anyway, advisory cap, ID space | §1.3 registration; text review |
| S2 | `tools/evidence_sweep.py` — stdlib `tomllib` only; modes `--stats` / `--check` / `--apply` / `--hook`, plus `--dry-run`, `--force`, and an optional table path for testing | `--stats` reproduces **101 entries / 65 pending / 1 dangling** before anything is written |
| S3 | First `--apply` (mark-only per D-4), committed on its own | count unchanged at 101, 65 entries now declared `PENDING_DELETE`, `meta.last_sweep` set |
| S4 | E-008 disposition: delete the 2 retirement *instructions* in `docs/spec/pini-landing-plan-v048.md` | `--stats` reports no dangling IDs |
| S5 | Wire the sweep into `hooks/pre-commit`; note `core.hooksPath` in `GIT_WORKFLOW.md` | throttled path skips with a message; `--force` against a scratch copy performs the deletion |
| S6 | Deletion pass — fires automatically on the first commit ≥24 h after S3 | count 101 → ~36; `meta.dangling_ids` lists E-035 / E-047 with every reference location |
| S7 | Register evidence for the post-sweep state | `tomllib` parse + citation scan |

**Stop-loss**: if `--stats` fails to reproduce **101 / 65 / 1 dangling** (tolerance ±10 on the entry count), stop and re-estimate. That means the citation scan is missing a reference shape and the delete surface is under-measured; deleting under those conditions destroys recoverable text. The scan must cover the **whole repo minus the table itself** — the `docs/`-only version under-counted the citation surface by 2×.

**Veto window**: the 24 h throttle doubles as a chance to back out. The first deletion cannot happen until the first commit that is at least 24 h after S3; until then, removing the sweep block from `hooks/pre-commit` cancels it entirely.

---

## 5. Impact assessment (§1.3 step 2)

| Dimension | Assessment |
|---|---|
| Spec surface | §1.4 only: counting rule (D-1) + tier table and third status (D-2) + ID-space statement (D-3) + sweep order (D-4) + trigger definition (D-5). No other section references the status vocabulary. |
| Table surface | First `--apply` rewrites **98 of 101** statuses in one diff. Large but one-time; every later sweep is incremental. Staging the rewrite across commits would mean knowingly running with a wrong table in between — rejected. |
| Citation surface | 9 occurrences across 2 IDs (E-035 ×3, E-047 ×6). Under D-7 these are **not** blockers: the entries are deleted and the 9 citations are recorded as debt in `meta.dangling_ids`. The other 63 candidates are zero-reference and touch nothing. |
| ID surface | **None.** E-100 / E-101 / E-102 are in range under D-3; no renumbering, no migration, no reference rewrite. (This reverses an earlier draft that treated them as out of range.) |
| Tooling surface | `tools/evidence_sweep.py`, alongside the existing `tools/check-doc-links.sh` — no new top-level directory. No dependency beyond stdlib `tomllib` (Python ≥ 3.11). **First mutating hook in this repository**: the existing three hooks are read-only gates; the sweep rewrites the table and re-stages it, which is why D-6 carries the unstaged-edit guard and the `git add` step. |
| Risk: silent deletion | Addressed by D-4's two-phase order (mark in run *N*, delete in run *N+1*) plus recoverability: the swept table is staged into the same commit, so the pre-delete state is always in the parent. Nothing disappears in the run that marks it, and nothing disappears without a commit that records it. |
| Risk: dangling references | **Accepted, not prevented** (D-7). Recorded in `meta.dangling_ids` and printed with locations at every sweep. The alternative — blocking on cited entries — was rejected because a blocked commit gets bypassed, while a recorded debt does not. |
| Risk: runaway growth | **Accepted.** T2 is advisory only. Under a heavy registration burst the table can exceed 100 until the age rule catches up; the sweep reports it and does nothing else. |

---

## 6. Resolved and remaining open decisions

**Resolved by the user on 2026-09-03:**

- **O-1 → D-3.** IDs stay 3-digit over `E-NNN` (three digits). They are identifiers for humans and agents to read; the script neither allocates nor polices them.
- **O-2 → D-4.** Grace period = one inter-run interval: delete first (last run's marks), then mark (this run's newly overdue). No duration-based timer. Refined by D-6, which puts a 24 h floor on that interval.
- **O-4 → withdrawn.** The renumbering question existed only under the misreading of the ID range as 0–99. With the range at 0–999 there is nothing to renumber.
- **O-5 → D-6.** The trigger is `git commit`, not a scheduled job and not a reminder. `core.hooksPath` already pointed at a versioned `hooks/` directory, so no new infrastructure was needed — the sweep simply joins the existing gate chain.
- **O-6 → D-6.** Throttle = **24 h**, which is simultaneously the minimum interval between sweeps and the real floor on the grace window. Chosen over 12 h (twice the diff noise, half the window) and 72 h (entries lingering up to ~6 days).
- **O-7 → D-7.** Cited entries are deleted like any other; the 9 stranded citations are recorded in `meta.dangling_ids`. Chosen over skip-and-warn (which would let cited entries pin themselves in the table permanently, since nothing forces a human to act) and over abort-on-cited (which trains operators to reach for `--no-verify`).
- **O-8 → D-5.** T2 carries **no hard rule**: volume only warns. "100" is a reporting threshold, not a cap and not a deletion trigger.

**Closed during execution:**

- **O-3 · E-008 disposition — done.** Both `docs/spec/pini-landing-plan-v048.md` references (lines 46, 87) were *instructions* ("E-008 置 STALE/废弃"), not citations. The v0.48 plan has long landed (CHANGELOG reaches v0.48.3) and E-008 is already absent from the table, so the instructions were completed to-dos that were never struck out. Both clauses were deleted at S4.
- **O-9 · pseudo-citations from prose about the ID space — done.** Writing the ID range with literal numerals instead of a placeholder — in the issue, in the script docstring, and again in the very paragraph that recorded this lesson — self-registers as dangling references, because the scanner cannot tell "describing the format" from "citing an entry". All three were reworded to a `E-NNN` placeholder. Corollary for authors, restated: **do not write a bare unallocated `E-NNN` in a committed document.**

---

## 7. Out of scope

- No change to spec body text that cites evidence (S6 may touch cited entries, but only via the human-escalation path).
- No ID renumbering or migration — withdrawn under D-3.
- No C-domain test-directory regrouping (separate issue; `docs/spec/test-dir-taxonomy-2026-09-03.md`).
- No change to the `assertion` / `spec_ref` / `code_ref` / `note` field semantics — §1.4's symbol-over-line rule stands unchanged.
