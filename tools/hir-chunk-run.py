#!/usr/bin/env python3
"""全量回归的分块驱动：把测试类切成 N 块，每块一次 `swift test --filter`，再合并失败集合。

WHY IT EXISTS

A single whole-suite run dies at roughly 94 of 115 suites on this machine
(SIGPIPE, deterministic -- two consecutive runs stop at the same place), while
running the classes one at a time costs 116 invocations. Three chunks reach
every class with no signal at all, and the failure set it produces is equal,
item by item, to what the per-class sweep produces. Splitting is therefore a
robust way to *measure*, not a repair of the underlying defect.

⚠️ 上面那两个数字（94 / 115）是 **115 类那棵测试树**的实测，该树已于 2026-09-18 清空、
2026-09-19 起重建（当前只有两个套件）。切块本身仍成立：它是「一次跑不完就分块量」的
量具，不依赖旧树规模。

FRAMEWORKS

本器械读**两个框架**的输出：XCTest 与 Swift Testing。后者的套件起始行、失败行、
汇总行与前者都不同（且不产出任何 `Executed ...` 行），只认一种会把另一种的套件
整体读成「未跑」—— 护栏会据此判作废，于是账目看起来只是「这次读不出来」，
真实原因是量具认不出框架。改动量具的解析层时，两种形状都要喂一遍。

⚠️ ALWAYS RUN THIS IN THE FOREGROUND.

Run from a background shell, the sandbox refuses `swift test`'s cleanup of its
temporary directory. The result is not an error: every class reports zero
executions, and the failure count is zero as well, so the whole table reads as
a clean pass with a perfectly legal shape. This has happened twice. The guard
below exists because of it -- an invalid reading must be impossible to mistake
for a green one.

USAGE

    python3 tools/hir-chunk-run.py <class-list-file> <chunk-count> <output-prefix>

`<class-list-file>` is one test class name per line. 名单可由
`swift test list | sed 's#/[^/]*$##' | sort -u` 现取 —— 两个框架都产这个形状；
`--filter` 接受裸套件名（实测 Swift Testing 套件同样被它命中）。
Outputs `<prefix>-chunkN.log`
for each chunk and `<prefix>-fails.json` holding the merged failure set.
失败集合的元素是字符串：XCTest 侧为 `类.方法`，Swift Testing 侧为用例显示名。

EXIT CODES

    0   a valid reading (every class reached, list written)
    2   reading discarded (some class never ran) -- no list is written, and a
        stale one at that path is deleted so it cannot be mistaken for this run
"""
import re, subprocess, sys, pathlib, json

if len(sys.argv) != 4:
    print(__doc__.split('USAGE')[1].strip(), file=sys.stderr)
    sys.exit(64)

classes_file, nchunks, prefix = sys.argv[1], int(sys.argv[2]), sys.argv[3]
classes = [c.strip() for c in pathlib.Path(classes_file).read_text().split('\n') if c.strip()]
# 无测试的辅助类：出现在清单里但不会产出任何 suite
classes = [c for c in classes if c != 'RecordingDebugDriver']
size = -(-len(classes) // nchunks)
chunks = [classes[i:i + size] for i in range(0, len(classes), size)]

# 套件起始行两式并存：XCTest 报 `Test Suite 'X' started at`，Swift Testing 报
# `Suite X started.`（前缀一个图标字符）。只认一种，另一种的套件会整体落进「未跑」
# 而被护栏判作废 —— 那是静默失效，不是报错。
SUITE_RUN = re.compile(r"Test Suite '([^']+)' started at|Suite (\S+) started\.")
# 失败行同样两式：XCTest 报「类 + 方法」，Swift Testing 报用例显示名。
# 两侧都归一到字符串（Swift Testing 没有类/方法二分，保留元组会让并集不可比）。
FAIL_XCTEST = re.compile(r"Test Case '-\[([\w.]+) ([\w]+)\]' failed")
FAIL_SWIFT_TESTING = re.compile(r'Test "([^"]+)" recorded an issue|Test "([^"]+)" failed after')
fails_all, suites_all = set(), []
for ci, chunk in enumerate(chunks, 1):
    pat = '(' + '|'.join(chunk) + ')'
    out = f'{prefix}-chunk{ci}.log'
    with open(out, 'w', encoding='utf-8') as fh:
        rc = subprocess.run(['swift', 'test', '--disable-sandbox', '--filter', pat],
                            cwd='.', stdout=fh, stderr=subprocess.STDOUT,
                            env={'PATH': '/usr/bin:/bin:/usr/local/bin',
                                 'HOME': str(pathlib.Path.home()), 'TMPDIR': '/tmp'}).returncode
    log = pathlib.Path(out).read_text(encoding='utf-8', errors='replace')
    ran = []
    for m in SUITE_RUN.finditer(log):
        name = m.group(1) or m.group(2)
        if name not in ran:
            ran.append(name)
    fails = {"%s.%s" % (cls, method) for cls, method in FAIL_XCTEST.findall(log)}
    fails |= {a or b for a, b in FAIL_SWIFT_TESTING.findall(log)}
    fails_all |= fails
    suites_all += ran
    missing = [c for c in chunk if c not in ran]
    print(f"块{ci}: 类 {len(chunk)} · 跑到 {len(ran)} · 未跑 {len(missing)} · "
          f"失败 {len(fails)} · signal13 ×{log.count('signal code 13')} · rc={rc}", flush=True)

reached = len(set(suites_all))
missing_total = [c for c in classes if c not in set(suites_all)]
print()
print('合计跑到类数 =', reached, '/', len(classes))

# ── 读数有效性护栏（2026-09-17 两次事故后固化）
# 跑到类数为 0，或有类根本没跑到，一律判作废：不写清单、删掉该路径上的旧清单、
# 非零退出。旧清单必须删 —— 留着它，下一次的读者会把上一轮的读数当成本轮结果。
if reached == 0 or missing_total:
    out_json = pathlib.Path(f'{prefix}-fails.json')
    stale = out_json.exists()
    if stale:
        out_json.unlink()
    print('读数判作废：跑到类数 = %d · 未跑 = %d' % (reached, len(missing_total)))
    for name in missing_total[:10]:
        print('  未跑:', name)
    if len(missing_total) > 10:
        print('  ... 及另外 %d 个' % (len(missing_total) - 10))
    print('  成因提示：`swift test` 必须前台跑；后台的沙箱会拦它的临时目录清理，')
    print('            于是每类 0 执行、失败 0 —— 形状合法的整表假绿。')
    print('  ⇒ 未写 %s%s，退出码 2。' % (out_json, '（已删除该路径上的旧清单）' if stale else ''))
    sys.exit(2)

print('合计失败方法 =', len(fails_all))
json.dump(sorted(fails_all),
          open(f'{prefix}-fails.json', 'w'), ensure_ascii=False, indent=1)
print('失败清单落盘 =', f'{prefix}-fails.json')
