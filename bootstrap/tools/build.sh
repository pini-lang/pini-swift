#!/usr/bin/env bash
# bootstrap/tools/build.sh — 自举工作区构建入口。
# 临时目录显式落在仓库内：构建期的原子写要求目标同卷可建可删，系统临时目录在受限环境里会被拒。
# 退出码为 0 不等于产物已更新，故构建后回读时间戳与字节数，把「构建成功」变成有证据的结论。
set -uo pipefail

root="$(git rev-parse --show-toplevel 2>/dev/null || echo "$PWD")"
cd "$root" || exit 1

# 宿主只取 release：debug 不参与门禁，也就不在构建链里留回退。
pini="$root/.build/release/pini"
if [ ! -x "$pini" ]; then
    echo " 行不通  [构建] 缺 release 宿主；先 swift build -c release --disable-sandbox" >&2
    exit 1
fi

tmp="$root/bootstrap/.build/tmp"
if ! mkdir -p "$tmp"; then
    echo " 行不通  [构建] 无法创建临时目录 $tmp" >&2
    exit 1
fi

started="$(date +%s)"
echo "构建开始 $(date '+%Y-%m-%d %H:%M:%S')，临时目录 $tmp"

# 运行时段走 release：产物每次值操作都跨 C ABI 进来，debug 构建实测慢五倍且产物相同。
. "$(dirname "${BASH_SOURCE[0]}")/runtime-lib.sh"
runtime_log="$tmp/runtime-build.log"
if ! swift build -c release --product PiniRuntime --disable-sandbox > "$runtime_log" 2>&1; then
    echo " 行不通  [构建] 运行时段构建失败；日志 $runtime_log" >&2
    tail -20 "$runtime_log" >&2
    exit 1
fi
runtime="$(pini_runtime_lib "$root")" || exit 1
export PINI_RUNTIME_LIB="$runtime"
echo "运行时段 $runtime"

# 编译器自身构建不装标准库：否则改标准库就要重建编译器，自举环里多一道回边。
TMPDIR="$tmp" "$pini" build --no-stdlib "$root/bootstrap"
code=$?
if [ "$code" -ne 0 ]; then
    echo " 行不通  [构建] 退出码 ${code}；产物未验证" >&2
    exit "$code"
fi

# 编译器产物一旦并进标准库，自举链就多一道回边；驱动包出现扩展方法符号即说明没带 --no-stdlib。
guard_ir="$root/bootstrap/.build/debug/packages/driver/pini-bootstrap.ll"
if grep -q -E '@[A-Za-z_]+__(String|Array)\(' "$guard_ir"; then
    echo " 行不通  [构建] 编译器产物含标准库扩展符号；构建须带 --no-stdlib" >&2
    exit 1
fi

# 回读：二进制必须在，更新数按时间戳判，避免把「全部跳过」当成「构建成功」。
python3 - "$root" "$started" <<'PY'
"""回读构建产物：二进制须存在，本次更新数按起始时间戳统计。"""
import datetime
import sys
from pathlib import Path

root = Path(sys.argv[1])
started = int(sys.argv[2])

binary = root / "bootstrap" / ".build" / "debug" / "bin" / "pini-bootstrap"
if not binary.is_file():
    print(f" 行不通  [构建] 缺产物 {binary}", file=sys.stderr)
    raise SystemExit(1)

packages = root / "bootstrap" / ".build" / "debug" / "packages"
lls = sorted(packages.glob("*/*.ll")) if packages.is_dir() else []
fresh = [path for path in lls if path.stat().st_mtime >= started]
total = sum(path.stat().st_size for path in lls)
stamp = datetime.datetime.fromtimestamp(binary.stat().st_mtime).strftime("%Y-%m-%d %H:%M:%S")

print(f"产物 {binary.relative_to(root)}：{binary.stat().st_size} 字节，最后写入 {stamp}")
print(f"中间产物：{len(lls)} 份 .ll，共 {total / 1024 / 1024:.2f} MB，本次更新 {len(fresh)} 份")
if not fresh:
    print(" 提示  [构建] 本次未更新任何中间产物；刚改过源码时先查是否被增量跳过")
PY
read_rc=$?

# 源码摘要：merge 检出会刷新 .pini 时间戳而内容不变，摘要一致时下游不再判落后。
python3 - "$root" <<'PY'
"""记下本次构建所依据的源码摘要，供对照判据判断产物是否仍有效。"""
import hashlib
import sys
from pathlib import Path

root = Path(sys.argv[1])
files = sorted(path for path in (root / "bootstrap" / "packages").rglob("*.pini")
               if "src" in path.parts)
digest = hashlib.sha256()
for path in files:
    digest.update(path.relative_to(root).as_posix().encode())
    digest.update(b"\0")
    digest.update(path.read_bytes())
    digest.update(b"\0")
stamp = root / "bootstrap" / ".build" / "debug" / "sources.sha256"
stamp.parent.mkdir(parents=True, exist_ok=True)
stamp.write_text(digest.hexdigest() + "\n", encoding="utf-8")
print(f"源码摘要 {digest.hexdigest()[:16]} 记于 {stamp.relative_to(root)}")
PY

exit "$read_rc"
