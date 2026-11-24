#!/usr/bin/env python3
# 命令行对照夹具：同一用例跑宿主与自举，归一后比盘上期望，并生成对照读数表。
# 期望按侧分开存：两侧文本形态不同，先把各自现状钉住，再逐位把差异收掉。
# 用法：--bless 重取期望与读数表；不带参数只比，差距或表过期即红。

import argparse
import hashlib
import os
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
CASES = ROOT / "bootstrap" / "fixtures" / "cli-parity" / "cases.tsv"
GOLDEN = ROOT / "bootstrap" / "fixtures" / "cli-parity" / "golden"
LEDGER = ROOT / "bootstrap" / "tests" / "parity" / "cli.tsv"
STDLIB = ROOT / "bootstrap" / "stdlib"
SELF_MAIN = ROOT / "bootstrap" / "packages" / "driver" / "src" / "api" / "main.pini"
TIMEOUT = 180

CODE_RE = re.compile(r"E[0-9]-[0-9]{3}")
LOC_RE = re.compile(r":(\d+):(\d+)")

HEADER = [
    "# 对照夹具读数：每条用例两侧的退出码、首条诊断与全文比对。",
    "# 「签名」三位依次为退出码 / 首条诊断 / 全文；诊断比码、行列与条数，全文按归一后逐字节比。",
    "# 由 bootstrap/tools/cli-parity.py --bless 生成，勿手改；签名只许变好。",
    "用例\t命令\t自举\t宿主rc\t自举rc\t宿主码\t自举码\t码数\t签名\t状态",
]


def fail(message):
    print(f" 行不通  [对照] {message}", file=sys.stderr)


def host_binary():
    """宿主可执行文件：显式环境变量优先，否则只认 release。
    宿主口径由 tools/host-profile-check.py 守；两份并存时按修改时间挑，红绿取决于谁被挑中。
    """
    for candidate in (os.environ.get("PINI_HOST_BIN"), os.environ.get("PINI_CLI_BIN")):
        if not candidate:
            continue
        path = Path(candidate)
        if not path.is_absolute():
            path = ROOT / path
        if path.is_file():
            return path
    found = ROOT / ".build/release/pini"
    if not found.is_file():
        fail("缺宿主可执行文件；先 swift build -c release --disable-sandbox")
        sys.exit(2)
    return found


def self_binary():
    candidate = os.environ.get("PINI_BOOTSTRAP_BIN")
    path = Path(candidate) if candidate else ROOT / "bootstrap" / ".build" / "release" / "bin" / "pini-bootstrap"
    if not path.is_file():
        fail("缺自举产物；先 bash bootstrap/tools/build.sh")
        sys.exit(2)
    return path


def newest_mtime(paths):
    values = [path.stat().st_mtime for path in paths if path.is_file()]
    return max(values) if values else 0.0


def sources_digest(paths):
    """源码摘要：路径与内容一起进哈希，构建脚本按同一算法写标记。"""
    digest = hashlib.sha256()
    for path in sorted(paths):
        digest.update(path.relative_to(ROOT).as_posix().encode())
        digest.update(b"\0")
        digest.update(path.read_bytes())
        digest.update(b"\0")
    return digest.hexdigest()


def stamp_matches(sources, stamp):
    """产物旁记的源码摘要与当前源码一致，即产物对应当前源码，时间戳不必再看。"""
    if not stamp.is_file():
        return False
    try:
        return stamp.read_text(encoding="utf-8").strip() == sources_digest(sources)
    except OSError:
        return False


def ensure_fresh(host, mine):
    """产物必须新于源码：旧二进制会把上一批的行为钉成期望。
    时间戳只作退路：merge 检出会刷新源码时间而内容没变，摘要一致时直接放行。
    """
    host_sources = [
        path for path in (ROOT / "Sources").rglob("*.swift")
        # 运行时库不是宿主二进制的链接输入（CLI 只经 dlopen 加载它），不算它落后。
        if path.relative_to(ROOT / "Sources").parts[0] != "PiniRuntime"
    ] + [ROOT / "Package.swift"]
    mine_sources = [path for path in (ROOT / "bootstrap" / "packages").rglob("*.pini")
                    if "src" in path.parts]
    if newest_mtime(host_sources) > host.stat().st_mtime + 1:
        fail("宿主产物落后于源码；先 swift build -c release")
        sys.exit(2)
    if not stamp_matches(mine_sources, ROOT / "bootstrap" / ".build" / "release" / "sources.sha256"):
        if newest_mtime(mine_sources) > mine.stat().st_mtime + 1:
            fail("自举产物落后于源码；先 bash bootstrap/tools/build.sh")
            sys.exit(2)


def load_cases():
    rows = []
    for line in CASES.read_text(encoding="utf-8-sig").splitlines():
        if not line or line.startswith("#") or line.startswith("用例\t"):
            continue
        parts = line.split("\t")
        if len(parts) != 6:
            fail(f"清单行应是六列：{line}")
            sys.exit(2)
        rows.append({
            "name": parts[0], "command": parts[1], "args": parts[2],
            "self": parts[3], "expect": parts[4], "note": parts[5],
        })
    if not rows:
        fail("清单为空")
        sys.exit(2)
    return rows


def expand_args(text):
    if text.strip() == "-":
        return []
    return [one.replace("<ROOT>", str(ROOT)) for one in text.split()]


def normalize(text):
    """抹掉只与机器有关的前缀；`./` 前缀与版本号保留，二者本身就是待对齐项。"""
    text = text.replace(str(ROOT), "<ROOT>")
    text = re.sub(r"/private/var/folders/[^\s\"']+", "<TMP>", text)
    text = re.sub(r"/var/folders/[^\s\"']+", "<TMP>", text)
    return re.sub(r"/tmp/[^\s\"']+", "<TMP>", text)


def run(binary, args):
    try:
        done = subprocess.run(
            [str(binary)] + args, cwd=str(ROOT), capture_output=True,
            encoding="utf-8", errors="replace", timeout=TIMEOUT,
        )
    except subprocess.TimeoutExpired:
        return 124, "", f"超过 {TIMEOUT} 秒"
    return done.returncode, normalize(done.stdout), normalize(done.stderr)


def first_diagnostic(text):
    """首条诊断的码与行列：码在本行，或在其后两行的 `at` 子句里。"""
    lines = text.splitlines()
    count = len(CODE_RE.findall(text))
    for index, line in enumerate(lines):
        hit = CODE_RE.search(line)
        if not hit:
            continue
        where = LOC_RE.search(line)
        for follow in lines[index + 1:index + 3]:
            if where:
                break
            where = LOC_RE.search(follow)
        if where:
            return f"{hit.group(0)}@{where.group(1)}:{where.group(2)}", count
        return hit.group(0), count
    return "-", count


def measure(binary, case, side):
    argv = [case["command"]] + expand_args(case["args"])
    # 自举侧标准库按产物位置解析；显式给路径，次代产物搬到别处也能跑。
    if side == "self":
        argv = ["--stdlib", str(STDLIB)] + argv
    code, out, err = run(binary, argv)
    label, count = first_diagnostic(out + err)
    return {"rc": code, "out": out, "err": err, "code": label, "count": count}


def signature(host, mine):
    flags = (
        host["rc"] == mine["rc"],
        host["code"] == mine["code"] and host["count"] == mine["count"],
        host["out"] == mine["out"] and host["err"] == mine["err"],
    )
    return "".join("同" if flag else "异" for flag in flags)


def status_of(sig):
    if sig == "---":
        return "缺:命令"
    labels = ("rc", "码", "文")
    gaps = [labels[index] for index, one in enumerate(sig) if one == "异"]
    return "同" if not gaps else "异:" + ",".join(gaps)


def golden_file(side, name, suffix):
    return GOLDEN / side / f"{name}.{suffix}"


def write_golden(side, name, result):
    base = GOLDEN / side
    base.mkdir(parents=True, exist_ok=True)
    golden_file(side, name, "rc").write_text(f"{result['rc']}\n", encoding="utf-8")
    golden_file(side, name, "out").write_text(result["out"], encoding="utf-8")
    golden_file(side, name, "err").write_text(result["err"], encoding="utf-8")


def read_golden(side, name):
    base = GOLDEN / side
    paths = [golden_file(side, name, one) for one in ("rc", "out", "err")]
    if not all(path.is_file() for path in paths):
        return None
    return {
        "rc": int(paths[0].read_text(encoding="utf-8").strip()),
        "out": paths[1].read_text(encoding="utf-8"),
        "err": paths[2].read_text(encoding="utf-8"),
    }


def first_diff(expected, actual):
    expected_lines = expected.splitlines()
    actual_lines = actual.splitlines()
    for index in range(min(len(expected_lines), len(actual_lines))):
        if expected_lines[index] != actual_lines[index]:
            return index + 1, expected_lines[index], actual_lines[index]
    if len(expected_lines) != len(actual_lines):
        tail = min(len(expected_lines), len(actual_lines)) + 1
        return tail, f"共 {len(expected_lines)} 行", f"共 {len(actual_lines)} 行"
    return None


def compare_golden(side, name, result, problems):
    expected = read_golden(side, name)
    if expected is None:
        problems.append(f"{name} / {side}：缺期望文件，先 --bless")
        return
    if expected["rc"] != result["rc"]:
        problems.append(f"{name} / {side}：退出码期望 {expected['rc']}，实测 {result['rc']}")
    for stream in ("out", "err"):
        diff = first_diff(expected[stream], result[stream])
        if diff is None:
            continue
        line, want, got = diff
        problems.append(f"{name} / {side} {stream} 第 {line} 行：期望 {want!r}，实测 {got!r}")


def ledger_text(rows):
    lines = list(HEADER)
    for case in rows:
        host, mine, sig = case["host"], case["mine"], case["sig"]
        if mine is None:
            lines.append(f"{case['name']}\t{case['command']}\t缺\t-\t-\t-\t-\t-\t---\t缺:命令")
            continue
        lines.append(
            f"{case['name']}\t{case['command']}\t在\t{host['rc']}\t{mine['rc']}"
            f"\t{host['code']}\t{mine['code']}\t{host['count']}/{mine['count']}"
            f"\t{sig}\t{status_of(sig)}"
        )
    return "\n".join(lines) + "\n"


def gather(cases, host, mine_binary):
    rows = []
    for case in cases:
        row = dict(case)
        row["host"] = measure(host, case, "host")
        row["mine"] = None if case["self"] == "缺" else measure(mine_binary, case, "self")
        row["sig"] = "---" if row["mine"] is None else signature(row["host"], row["mine"])
        rows.append(row)
    return rows


def self_commands():
    """驱动分派里认得的子命令：`args[0] == "…"` 是唯一写法；命令名允许连字符。"""
    text = SELF_MAIN.read_text(encoding="utf-8")
    return set(re.findall(r'args\[0\] == "([A-Za-z][A-Za-z0-9-]*)"', text))


def check_declared(rows):
    have = self_commands()
    problems = []
    for row in rows:
        marked = row["self"] == "在"
        present = row["command"] in have
        if marked and not present:
            problems.append(f"{row['name']}：清单记「在」，但驱动没有 `{row['command']}` 子命令")
        if not marked and present:
            problems.append(
                f"{row['name']}：清单记「缺」，但驱动已有 `{row['command']}`；"
                "改成「在」并重取期望"
            )
    return problems


def check_expectations(rows):
    problems = []
    for row in rows:
        expect, sig = row["expect"], row["sig"]
        if expect == "待核":
            problems.append(f"{row['name']}：签名未定（实测 {sig}），先 --bless 再填")
        elif expect == sig:
            continue
        elif any(want == "同" and got == "异" for want, got in zip(expect, sig)):
            problems.append(f"{row['name']}：签名退步 {expect} → {sig}；先修行为，别改期望")
        else:
            problems.append(f"{row['name']}：签名变化 {expect} → {sig}；确认后改「期望」列")
    return problems


def main():
    parser = argparse.ArgumentParser(description="命令行对照夹具")
    parser.add_argument("--bless", action="store_true", help="重取期望与读数表")
    args = parser.parse_args()

    host = host_binary()
    mine_binary = self_binary()
    ensure_fresh(host, mine_binary)
    rows = gather(load_cases(), host, mine_binary)

    if args.bless:
        for row in rows:
            write_golden("host", row["name"], row["host"])
            if row["mine"] is not None:
                write_golden("self", row["name"], row["mine"])
        LEDGER.parent.mkdir(parents=True, exist_ok=True)
        LEDGER.write_text(ledger_text(rows), encoding="utf-8")
        pending = [row for row in rows if row["expect"] == "待核"]
        if pending:
            print("对照夹具已重取，以下签名待填：")
            for row in pending:
                print(f"  {row['name']}：{row['sig']}（{status_of(row['sig'])}）")
            return 0
        problems = check_declared(rows) + check_expectations(rows)
        for one in problems:
            fail(one)
        print(f"对照夹具已重取：{len(rows)} 条")
        return 0 if not problems else 1

    problems = []
    for row in rows:
        compare_golden("host", row["name"], row["host"], problems)
        if row["mine"] is not None:
            compare_golden("self", row["name"], row["mine"], problems)
    problems.extend(check_declared(rows))
    problems.extend(check_expectations(rows))
    expected_ledger = ledger_text(rows)
    if not LEDGER.is_file() or LEDGER.read_text(encoding="utf-8") != expected_ledger:
        problems.append("读数表与实测不符；重取：python3 bootstrap/tools/cli-parity.py --bless")

    if problems:
        for one in problems:
            fail(one)
        return 1

    same = sum(1 for row in rows if row["sig"] == "同同同")
    absent = sum(1 for row in rows if row["sig"] == "---")
    print(f"对照夹具：{len(rows)} 条，全文同 {same}，异 {len(rows) - same - absent}，缺命令 {absent}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
