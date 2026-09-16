#!/usr/bin/env python3
"""全量回归的分块驱动：把测试类切成 N 块，每块一次 `swift test --filter`，再合并失败集合。

WHY IT EXISTS

A single whole-suite run dies at roughly 94 of 115 suites on this machine
(SIGPIPE, deterministic -- two consecutive runs stop at the same place), while
running the classes one at a time costs 116 invocations. Three chunks reach
every class with no signal at all, and the failure set it produces is equal,
item by item, to what the per-class sweep produces. Splitting is therefore a
robust way to *measure*, not a repair of the underlying defect.

⚠️ ALWAYS RUN THIS IN THE FOREGROUND.

Run from a background shell, the sandbox refuses `swift test`'s cleanup of its
temporary directory. The result is not an error: every class reports zero
executions, and the failure count is zero as well, so the whole table reads as
a clean pass with a perfectly legal shape. This has happened twice. The guard
below exists because of it -- an invalid reading must be impossible to mistake
for a green one.

USAGE

    python3 tools/hir-chunk-run.py <class-list-file> <chunk-count> <output-prefix>

`<class-list-file>` is one test class name per line. Outputs `<prefix>-chunkN.log`
for each chunk and `<prefix>-fails.json` holding the merged failure set.

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

SUITE_RUN = re.compile(r"Test Suite '([^']+)' started at")
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
        if m.group(1) not in ran:
            ran.append(m.group(1))
    fails = set(re.findall(r"Test Case '-\[([\w.]+) ([\w]+)\]' failed", log))
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
json.dump(sorted((c, m) for c, m in fails_all),
          open(f'{prefix}-fails.json', 'w'), ensure_ascii=False, indent=1)
print('失败清单落盘 =', f'{prefix}-fails.json')
