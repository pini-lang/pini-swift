#!/usr/bin/env python3
"""Automatic maintainer for docs/spec/evidence-table.toml (spec section 1.4).

Why this exists: the freshness obligation on evidence is real, but nothing can
compel an agent or a human to tidy the table by hand -- every agent session
starts from zero and there is no reminder. So the obligation is discharged by a
script, triggered by a beat that already happens on every change: git commit.

What this script is NOT: it is not an ID allocator. IDs are names for readers
(three digits) and belong to whoever registers the evidence. The script never
refuses an entry because of its number, never renumbers, and never reuses a
slot. It only cleans.

Two-phase sweep (D-4): delete what a *previous* run marked PENDING_DELETE, then
recompute statuses on what survives. Nothing is removed in the same run that
marks it. The minimum interval between sweeps (24 h, meta.last_sweep) is what
turns "the interval between two runs" into a real wall-clock grace window --
without it, a commit-triggered sweep would mark and delete minutes apart.

Table edits are line-oriented: everything outside the status lines, the meta
keys it owns, and deleted entry blocks is preserved byte for byte.

Modes
  --stats            report only
  --check            report; exit non-zero only on parse / schema errors
  --apply            perform the sweep
  --hook             --apply, but throttled by meta.last_sweep
  --dry-run          with --apply/--hook: report the changes, write nothing
  --force            with --hook: ignore the throttle

Exit codes: 0 ok, 1 hard error (unparseable table), 3 environment error.
"""

import argparse
import datetime as dt
import fnmatch
import re
import subprocess
import sys
from collections import Counter, defaultdict
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
EID = re.compile(r"\bE-?(\d{3})\b")
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


def scan_citations(root, exclude_globs=()):
    """Return {eid_int: [(relative_path, line_no), ...]} over the whole repo.

    The table itself is excluded by *name* so a scratch copy outside the repo
    cannot turn every ID into a citation. Scanning docs/ only under-counted the
    citation surface by roughly 2x (examples/selfhost/.pini/baseline cites
    E-067 and E-081).

    `meta.scan_exclude` (and --exclude) drop governance documents that *discuss*
    IDs rather than rely on them. Without this, an issue narrating the
    disposition of a retired ID keeps it dangling forever, and a debt list that
    carries false entries is worthless.
    """
    found = defaultdict(list)
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
        text = blob.decode("utf-8", errors="ignore")
        for lineno, line in enumerate(text.splitlines(), 1):
            for match in EID.finditer(line):
                found[int(match.group(1))].append(
                    (str(path.relative_to(root)), lineno)
                )
    return found


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


def render_str_array(values):
    return "[" + ", ".join('"%s"' % v for v in values) + "]"


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
    citations = scan_citations(root, cite_exclude)
    status_now = {}
    for item in entries:
        status_now[item["id"]] = classify(item["validated_at"], now)[0]

    buckets = Counter(status_now.values())
    pending = [i for i, s in status_now.items() if s == "PENDING_DELETE"]
    marked = [e["id"] for e in entries if e.get("status") == "PENDING_DELETE"]

    if args.stats or args.check:
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
        log("carried dangling_ids in meta: %s"
            % (meta.get("dangling_ids") or "none"))
        log("dangling right now (cited but absent): %s"
            % (sorted("E-%03d" % n for n in citations
                      if ("E-%03d" % n) not in set(status_now)) or "none"))
        log("advisory cap %d: %s"
            % (ADVISORY_CAP,
               "over by %d" % (len(entries) - ADVISORY_CAP)
               if len(entries) > ADVISORY_CAP else "within"))
        if args.check:
            log("check ok (parse + schema)")
        return 0

    # Only delete if the entry is *still* overdue. An entry marked in a previous
    # run and refreshed since has a fresh validated_at, so its computed status is
    # no longer PENDING_DELETE and it survives. Without this guard the grace
    # window would be decorative: refreshing would not save anything.
    to_delete = {eid for eid in marked if status_now.get(eid) == "PENDING_DELETE"}
    survivors = [e for e in entries if e["id"] not in to_delete]
    dangling_ids = sorted(
        "E-%03d" % n for n in citations if ("E-%03d" % n) not in
        {e["id"] for e in survivors}
    )

    log("mode: %s%s" % ("hook" if args.hook else "apply",
                        " (dry-run)" if args.dry_run else ""))
    log("delete: %d previously marked" % len(to_delete))
    if to_delete:
        log("  %s" % " ".join(sorted(to_delete)))
    cited_deleted = sorted(
        ("E-%03d" % n for n in citations
         if ("E-%03d" % n) in to_delete)
    )
    if cited_deleted:
        log("WARNING: %d deleted IDs are still cited; those citations now dangle"
            % len(cited_deleted))
        for eid in cited_deleted:
            n = int(eid.split("-")[1])
            where = ", ".join("%s:%d" % loc for loc in citations[n][:6])
            more = "" if len(citations[n]) <= 6 else " (+%d more)" % (len(citations[n]) - 6)
            log("  %s x%d -> %s%s" % (eid, len(citations[n]), where, more))
    log("survivors: %d" % len(survivors))
    log("dangling after sweep: %s" % (dangling_ids or "none"))
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
    kept = set_meta(kept, split_blocks(kept), "dangling_ids",
                    render_str_array(dangling_ids))

    table.write_text("\n".join(kept) + "\n", encoding="utf-8")
    log("wrote %s (entries %d -> %d)" % (table.name, len(entries), len(survivors)))
    return 0


def shifted_index(idx, drop):
    """A status line's index after the lines in `drop` are removed."""
    return idx - sum(1 for d in drop if d < idx)


if __name__ == "__main__":
    sys.exit(main())
