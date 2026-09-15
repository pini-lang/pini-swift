#!/usr/bin/env python3
"""Automatic maintainer for docs/spec/evidence-table.toml (spec section 1.4).

Why this exists: the freshness obligation on evidence is real, but nothing can
compel an agent or a human to tidy the table by hand -- every agent session
starts from zero and there is no reminder. So the obligation is discharged by a
script, triggered by a beat that already happens on every change: git commit.

What this script is NOT: it is not an ID allocator. An entry's id is a
self-describing phrase for readers and belongs to whoever registers the
evidence; the script never allocates one, never renumbers, never rejects an
entry because of its id. It only cleans.

Gate: this table is a *rolling* table -- entries are swept by age, so an id
written in any other carrier necessarily ends up pointing at nothing. Spec 1.4
therefore forbids citing an entry id outside the table. When a historical
carrier has to keep the trace of a deleted three-digit number it writes it as
`E-NNN（源已删除）`; any other appearance of such a number outside the table is a
violation. `--check` reports those and exits non-zero, and hooks/pre-commit
runs it on every commit, so a fresh citation cannot land.

Two-phase sweep (D-4): delete what a *previous* run marked PENDING_DELETE, then
recompute statuses on what survives. Nothing is removed in the same run that
marks it. The minimum interval between sweeps (24 h, meta.last_sweep) is what
turns "the interval between two runs" into a real wall-clock grace window --
without it, a commit-triggered sweep would mark and delete minutes apart.

Table edits are line-oriented: everything outside the status lines, the meta
keys it owns, and deleted entry blocks is preserved byte for byte.

Modes
  --stats            report only
  --check            report; exit non-zero on parse / schema errors or on an
                     evidence number outside the table that carries no mark
  --apply            perform the sweep
  --hook             --apply, but throttled by meta.last_sweep
  --dry-run          with --apply/--hook: report the changes, write nothing
  --force            with --hook: ignore the throttle
  --quiet            drop the informational lines (violations still print)

Exit codes: 0 ok, 1 hard error or policy violation, 3 environment error.
"""

import argparse
import datetime as dt
import fnmatch
import re
import subprocess
import sys
from collections import Counter
from pathlib import Path

_MODE = next(
    (a for a in sys.argv[1:] if a in ("--stats", "--check", "--apply", "--hook")),
    None,
)

try:
    import tomllib
except ModuleNotFoundError:
    if _MODE == "hook":
        sys.stderr.write(
            "evidence-sweep: python >= 3.11 (tomllib) required; skipping\n"
        )
        sys.exit(0)
    sys.stderr.write("evidence-sweep: python >= 3.11 (tomllib) required\n")
    sys.exit(3)

TZ = dt.timezone(dt.timedelta(hours=8))
FRESH_HOURS = 1
PENDING_HOURS = 72
MIN_INTERVAL_HOURS = 24
ADVISORY_CAP = 100
TABLE_NAME = "evidence-table.toml"
SKIP_DIRS = {".git", ".build", "__pycache__", "DerivedData"}
EID = re.compile(r"\bE-(\d{3})\b")
# 引用组续写：`.` / `..` / `/` / `、` / `,`，后随可省 `E-` 前缀的三位数字
CONT = re.compile(r"(?:\s*(?:\.\.?|/|、|,)\s*(?:E-)?\d{3}\b)")
MARK = "源已删除"          # 标注正文；`（源已删除）` 与并入括号的 `（源已删除；` 都含它
MARK_WINDOW = 8            # 标注须落在引用组尾之后这么多个字符内
HEADER = re.compile(r"^\[")
KV = re.compile(r'^([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)$')


def log(msg):
    sys.stderr.write("[evidence-sweep] %s\n" % msg)


def repo_root():
    try:
        out = subprocess.run(
            ["git", "rev-parse", "--show-toplevel"],
            capture_output=True, text=True, check=True,
        )
        return Path(out.stdout.strip())
    except Exception:
        return Path(__file__).resolve().parent.parent


def parse_ts(raw, default_tz=TZ):
    stamp = dt.datetime.fromisoformat(str(raw).strip().strip('"'))
    if stamp.tzinfo is None:
        stamp = stamp.replace(tzinfo=default_tz)
    return stamp


def fmt(stamp):
    return stamp.astimezone(TZ).replace(second=0, microsecond=0).isoformat()


def classify(validated_at, now):
    age_hours = (now - parse_ts(validated_at)).total_seconds() / 3600.0
    if age_hours <= FRESH_HOURS:
        return "FRESH", age_hours
    if age_hours <= PENDING_HOURS:
        return "STALE", age_hours
    return "PENDING_DELETE", age_hours


def iter_scanned_lines(root, exclude_globs=()):
    """Yield (relative_path, lineno, line) over every text file outside the table.

    The table itself is excluded by *name* so a scratch copy outside the repo
    cannot turn every id into a citation. The whole tree is walked rather than
    docs/ alone: `examples/selfhost/.pini/baseline` is a real citation site and
    a docs/-only scan under-counted the surface by roughly 2x.

    `meta.scan_exclude` (and --exclude) drop governance documents that *discuss*
    evidence numbering rather than rely on it -- an issue that measures the
    citation surface would otherwise be reported as violating itself.
    """
    for path in sorted(root.rglob("*")):
        if not path.is_file() or path.name == TABLE_NAME:
            continue
        if SKIP_DIRS & set(path.parts):
            continue
        rel = path.relative_to(root).as_posix()
        if any(fnmatch.fnmatch(rel, pat) for pat in exclude_globs):
            continue
        try:
            blob = path.read_bytes()
        except OSError:
            continue
        if b"\0" in blob[:4096]:
            continue
        for lineno, line in enumerate(
            blob.decode("utf-8", errors="ignore").splitlines(), 1
        ):
            yield rel, lineno, line


def ref_spans(line):
    """[(start, end)] for every evidence-number reference on the line.

    A reference is one number plus any connector-joined continuations, so a
    dotted range, a double-dot range whose tail drops the `E-` prefix, and a
    slash-joined list each count as one: a range carries a single mark, at its
    end. (The literal forms are deliberately not spelled out here -- writing
    them would make this docstring cite them.)
    """
    spans, pos = [], 0
    while True:
        match = EID.search(line, pos)
        if not match:
            break
        end = match.end()
        while True:
            cont = CONT.match(line, end)
            if not cont:
                break
            end = cont.end()
        spans.append((match.start(), end))
        pos = end
    return spans


def scan_unannotated(root, exclude_globs=()):
    """[(rel, lineno, token)] for evidence numbering that carries no deletion mark.

    The mark has to sit at the reference's end: a `**` bold closer is stepped
    over, and the mark may have been merged into a following parenthetical. So
    `tail[:MARK_WINDOW]` containing the word is the whole test -- the same rule
    the one-off annotation pass applied, expressed once.
    """
    out = []
    for rel, lineno, line in iter_scanned_lines(root, exclude_globs):
        for start, end in ref_spans(line):
            tail = line[end:]
            if tail.startswith("**"):
                tail = tail[2:]
            if MARK not in tail[:MARK_WINDOW]:
                out.append((rel, lineno, line[start:end]))
    return out


def split_blocks(lines):
    """[(header_index, exclusive_end)] for every `[...]` / `[[...]]` table."""
    starts = [i for i, line in enumerate(lines) if HEADER.match(line)]
    blocks = []
    for idx, start in enumerate(starts):
        end = starts[idx + 1] if idx + 1 < len(starts) else len(lines)
        blocks.append((start, end))
    return blocks


def entry_id(lines, start, end):
    for i in range(start, end):
        m = KV.match(lines[i])
        if m and m.group(1) == "id":
            return m.group(2).strip().strip('"'), i
    return None, None


def status_line(lines, start, end):
    for i in range(start, end):
        m = KV.match(lines[i])
        if m and m.group(1) == "status":
            return i
    return None


def set_meta(lines, blocks, key, rendered):
    """Insert or replace `key = ...` inside the [meta] block."""
    target = None
    for start, end in blocks:
        if lines[start].strip() == "[meta]":
            target = (start, end)
            break
    if target is None:
        return lines
    start, end = target
    for i in range(start + 1, end):
        m = KV.match(lines[i])
        if m and m.group(1) == key:
            lines[i] = "%s = %s" % (key, rendered)
            return lines
    anchor = None
    for i in range(start + 1, end):
        m = KV.match(lines[i])
        if m and m.group(1) in ("last_sweep", "last_refresh"):
            anchor = i
    insert_at = anchor + 1 if anchor is not None else end
    lines.insert(insert_at, "%s = %s" % (key, rendered))
    return lines


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("table", nargs="?", help="path to evidence-table.toml")
    ap.add_argument("--stats", action="store_true")
    ap.add_argument("--check", action="store_true")
    ap.add_argument("--apply", action="store_true")
    ap.add_argument("--hook", action="store_true")
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--force", action="store_true")
    ap.add_argument("--quiet", action="store_true")
    ap.add_argument("--exclude", action="append", default=[],
                    help="extra glob (repo-relative) to skip; "
                         "added to meta.scan_exclude")
    args = ap.parse_args()

    root = repo_root()
    table = Path(args.table) if args.table else root / "docs" / "spec" / TABLE_NAME
    write = args.apply or args.hook
    if not args.stats and not args.check and not write:
        ap.error("pick one of --stats / --check / --apply / --hook")

    try:
        doc = tomllib.loads(table.read_text(encoding="utf-8"))
    except FileNotFoundError:
        log("table not found: %s" % table)
        return 1
    except tomllib.TOMLDecodeError as exc:
        log("table is unparseable: %s" % exc)
        return 1

    entries = doc.get("evidence")
    if not isinstance(entries, list):
        log("table has no [[evidence]] array")
        return 1
    for item in entries:
        if not isinstance(item, dict) or "id" not in item or "validated_at" not in item:
            log("entry missing id/validated_at: %r" % (item,))
            return 1

    now = dt.datetime.now(TZ).replace(second=0, microsecond=0)
    meta = doc.get("meta", {})

    if args.hook and not args.force and meta.get("last_sweep"):
        since = now - parse_ts(meta["last_sweep"])
        if since < dt.timedelta(hours=MIN_INTERVAL_HOURS):
            left = dt.timedelta(hours=MIN_INTERVAL_HOURS) - since
            if not args.quiet:
                log("skipped: swept %s ago, next sweep in %s"
                    % (str(since).split(".")[0], str(left).split(".")[0]))
            return 0

    cite_exclude = list(meta.get("scan_exclude", [])) + list(args.exclude)
    unannotated = scan_unannotated(root, cite_exclude)
    status_now = {}
    for item in entries:
        status_now[item["id"]] = classify(item["validated_at"], now)[0]

    buckets = Counter(status_now.values())
    pending = [i for i, s in status_now.items() if s == "PENDING_DELETE"]
    marked = [e["id"] for e in entries if e.get("status") == "PENDING_DELETE"]

    if args.stats or args.check:
        if not args.quiet:
            log("path: %s" % table)
            log("entries (dict-carried count): %d" % len(entries))
            log("computed status: FRESH %d / STALE %d / PENDING_DELETE %d"
                % (buckets["FRESH"], buckets["STALE"], buckets["PENDING_DELETE"]))
            log("declared PENDING_DELETE: %d" % len(marked))
            drift = sum(1 for e in entries
                        if e.get("status") != status_now.get(e["id"]))
            log("status drift (declared vs computed): %d" % drift)
            log("scan excludes (%d): %s"
                % (len(cite_exclude), cite_exclude or "none"))
            log("advisory cap %d: %s"
                % (ADVISORY_CAP,
                   "over by %d" % (len(entries) - ADVISORY_CAP)
                   if len(entries) > ADVISORY_CAP else "within"))
        log("unannotated evidence numbers outside the table: %d"
            % len(unannotated))
        for rel, lineno, token in unannotated[:40]:
            log("  %s:%d  %s" % (rel, lineno, token))
        if len(unannotated) > 40:
            log("  ... and %d more" % (len(unannotated) - 40))
        if args.check:
            if unannotated:
                log("check FAILED: %d unannotated evidence number(s); write "
                    "`E-NNN（源已删除）` or drop the number" % len(unannotated))
                return 1
            log("check ok (parse + schema + citation marks)")
        return 0

    # Only delete if the entry is *still* overdue. An entry marked in a previous
    # run and refreshed since has a fresh validated_at, so its computed status is
    # no longer PENDING_DELETE and it survives. Without this guard the grace
    # window would be decorative: refreshing would not save anything.
    to_delete = {eid for eid in marked if status_now.get(eid) == "PENDING_DELETE"}
    survivors = [e for e in entries if e["id"] not in to_delete]

    log("mode: %s%s" % ("hook" if args.hook else "apply",
                        " (dry-run)" if args.dry_run else ""))
    log("delete: %d previously marked" % len(to_delete))
    if to_delete:
        log("  %s" % " ".join(sorted(to_delete)))
    log("survivors: %d" % len(survivors))
    if unannotated:
        log("WARNING: %d evidence number(s) outside the table carry no "
            "deletion mark; run --check for the list" % len(unannotated))
    if len(survivors) > ADVISORY_CAP:
        log("ADVISORY: count %d exceeds cap %d (no enforcement; only triggers "
            "next-sweep reporting)" % (len(survivors), ADVISORY_CAP))

    if args.dry_run:
        log("dry-run: nothing written")
        return 0

    lines = table.read_text(encoding="utf-8").splitlines()
    blocks = split_blocks(lines)

    drop = set()
    rewrite = {}
    for start, end in blocks:
        if lines[start].strip() != "[[evidence]]":
            continue
        eid, _ = entry_id(lines, start, end)
        if eid is None:
            continue
        if eid in to_delete:
            drop.update(range(start, end))
            continue
        idx = status_line(lines, start, end)
        if idx is None:
            continue
        new_status = status_now.get(eid)
        if new_status and lines[idx] != 'status = "%s"' % new_status:
            rewrite[idx] = 'status = "%s"' % new_status

    kept = [line for i, line in enumerate(lines) if i not in drop]
    for idx, text in rewrite.items():
        kept[shifted_index(idx, drop)] = text

    kept = set_meta(kept, split_blocks(kept), "last_sweep", '"%s"' % fmt(now))

    table.write_text("\n".join(kept) + "\n", encoding="utf-8")
    log("wrote %s (entries %d -> %d)" % (table.name, len(entries), len(survivors)))
    return 0


def shifted_index(idx, drop):
    """A status line's index after the lines in `drop` are removed."""
    return idx - sum(1 for d in drop if d < idx)


if __name__ == "__main__":
    sys.exit(main())
