#!/usr/bin/env bash
# check-host-string-complexity.sh — 宿主侧字符串的「代价分离」判据：同一工作两档规模（4×）的耗时比，
# O(len) ≈ 4、O(len²) ≈ 16；五条臂（read / read-local / index-base / concat / slices）每次只差一处。
# LINEAR_ARMS 与 PENDING_ARMS 两侧都判：线性臂超上限即红，二次臂变成线性则要求更新声明。
set -u

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MAX_LINEAR_RATIO=6      # 线性臂的比值上限（O(len) ≈ 4）
MIN_SECONDARY_RATIO=8   # 二次臂的判定下界（O(len²) ≈ 16；取 8 留出抖动余量）

LINEAR_ARMS="concat index-base read read-local slices"
PENDING_ARMS=""

PINI_BIN="${PINI_BIN:-}"
if [ -z "$PINI_BIN" ]; then
    for cand in "$REPO_ROOT/.build/debug/pini" "$REPO_ROOT/.build/release/pini"; do
        if [ -x "$cand" ]; then PINI_BIN="$cand"; break; fi
    done
fi
if [ -z "$PINI_BIN" ] || [ ! -x "$PINI_BIN" ]; then
    echo " 注意  无法判定：种子二进制取不到（ 行不通  这不是「判据不过」）"
    echo "   ⇒ 报 2 不报 1：前提缺失 ≠ 违规。先构建宿主，或把 PINI_BIN 指对。"
    exit 2
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/probe.pini" <<'PINI_EOF'
; 宿主侧字符串「代价分离」探针 —— **自足**（独立文件参考不到模块符号）。
; 五条臂，每次只差一处；详见调用它的器械件头。

参数|func(k: I32,) -> (String,):
    let a = argv()
    var i = 0
    var out = ""
    for (x,) in a:
        if i == k:
            out = x
        i = i + 1
    return out

读|func(text: String,) -> (I32,):
    var acc = 0
    var i = 0
    while i < len(text):
        if text[i] == "z":
            acc = acc + 1
        i = i + 1
    return acc

读局部长|func(text: String,) -> (I32,):
    let n = len(text)
    var acc = 0
    var i = 0
    while i < n:
        if text[i] == "z":
            acc = acc + 1
        i = i + 1
    return acc

下标基线|func(text: String,) -> (I32,):
    let cs = text.split("")
    let n = len(cs)
    var acc = 0
    var i = 0
    while i < n:
        if cs[i] == "z":
            acc = acc + 1
        i = i + 1
    return acc

拼接|func(text: String,) -> (I32,):
    let cs = text.split("")
    let n = len(cs)
    var buf = ""
    var i = 0
    while i < n:
        buf = buf + cs[i]
        i = i + 1
    return len(buf)

切片|func(text: String,) -> (I32,):
    var buf = ""
    var i = 0
    while i < len(text):
        buf = buf + text.substring(i, i + 1)
        i = i + 1
    return len(buf)

main|func() -> ():
    let mode = 参数(0,)
    let path = 参数(1,)
    let text = readFile(path)
    if mode == "read":
        print("READ \(len(text),) \(读(text),)")
        return
    if mode == "read-local":
        print("READ-LOCAL \(len(text),) \(读局部长(text),)")
        return
    if mode == "index-base":
        print("INDEX-BASE \(下标基线(text),)")
        return
    if mode == "concat":
        print("CONCAT \(拼接(text),)")
        return
    if mode == "slices":
        print("SLICES \(切片(text),)")
        return
    print("probe: 未知模式 \(mode)")
PINI_EOF

now() {
    if command -v perl >/dev/null 2>&1; then
        perl -MTime::HiRes=time -e 'printf("%d\n", time*1000000)'
    else
        python3 -c 'import time;print(int(time.time()*1000000))'
    fi
}

gen() { awk -v n="$1" 'BEGIN{for(i=0;i<n;i++) print "let alpha = beta + gamma * delta"}' > "$2"; }
gen 200  "$TMP/s.txt"
gen 800  "$TMP/l.txt"
gen 1000 "$TMP/bs.txt"
gen 4000 "$TMP/bl.txt"

arm() {  # arm <mode> <file> ⇒ ms（跑不出读数 ⇒ BROKEN）
    local t0 t1
    t0="$(now)"
    "$PINI_BIN" run "$TMP/probe.pini" "$1" "$2" > "$TMP/out.txt" 2>&1
    t1="$(now)"
    local pat
    case "$1" in
        read) pat='^READ ' ;; read-local) pat='^READ-LOCAL ' ;;
        index-base) pat='^INDEX-BASE ' ;; concat) pat='^CONCAT ' ;; slices) pat='^SLICES ' ;;
    esac
    grep -qE "$pat" "$TMP/out.txt" || { echo "BROKEN"; return; }
    echo $(( (t1 - t0) / 1000 ))
}

ratio() { awk -v a="$1" -v b="$2" 'BEGIN{printf "%.2f", (a>0 ? b/a : 0)}'; }

echo "── 宿主侧字符串代价分离（4× 规模比 · O(len)≈4 · O(len²)≈16）──"
printf '%-14s %9s %9s %8s   %s\n' 臂 小ms 大ms 比值 判定

fail=0
measured_linear=""
measured_secondary=""

for m in read read-local index-base concat slices; do
    case "$m" in
        index-base) sf="$TMP/bs.txt"; lf="$TMP/bl.txt" ;;
        *)          sf="$TMP/s.txt";  lf="$TMP/l.txt"  ;;
    esac
    s="$(arm "$m" "$sf")"; l="$(arm "$m" "$lf")"
    if [ "$s" = "BROKEN" ] || [ "$l" = "BROKEN" ]; then
        printf '%-14s %9s %9s %8s   ❌ 跑不出读数\n' "$m" "$s" "$l" -
        fail=1
        continue
    fi
    r="$(ratio "$s" "$l")"
    verdict=""
    if awk -v x="$r" -v t="$MAX_LINEAR_RATIO" 'BEGIN{exit !(x <= t)}'; then
        verdict="O(len)"
        measured_linear="$measured_linear $m"
    elif awk -v x="$r" -v t="$MIN_SECONDARY_RATIO" 'BEGIN{exit !(x >= t)}'; then
        verdict="O(len²)"
        measured_secondary="$measured_secondary $m"
    else
        verdict=" 注意  落在两档之间（分辨率不足）"
    fi
    printf '%-14s %9s %9s %8s   %s\n' "$m" "$s" "$l" "$r" "$verdict"
done

echo

# ── 判据一：已声明线性的臂不许退化 ──
for m in $LINEAR_ARMS; do
    case " $measured_linear " in
        *" $m "*) : ;;
        *)  echo "❌ 红：臂 \`$m\` 已声明为线性，实测**不在**线性档 ⇒ 退化（或负载形状变了）"
            fail=1 ;;
    esac
done

# ── 判据二：已声明二次的臂若变线性 ⇒ 声明已过时（须知会， 行不通  不是「红」）──
for m in $PENDING_ARMS; do
    case " $measured_secondary " in
        *" $m "*) : ;;
        *)  case " $measured_linear " in
                *" $m "*) echo " 重要  提示：臂 \`$m\` 已实测为线性 —— 它所在的那处站点大概已经被修好了，"
                          echo "   ⇒ 请把 \`$m\` 从 PENDING_ARMS 移到 LINEAR_ARMS（本件头也一并刷新）。" ;;
              *)  echo " 注意  提示：臂 \`$m\` 落在两档之间（既非线性也非二次）⇒ 本次读数不足以判定它。" ;;
            esac ;;
    esac
done

# ── 判据三：实测为二次的臂必须已声明 ──
# 缺了它，判据一就能靠移除 PENDING 那一行来消红；单向名单会退化成永久豁免。
for m in $measured_secondary; do
    case " $PENDING_ARMS " in
        *" $m "*) : ;;
        *)  echo "❌ 红：臂 \`$m\` 实测为**二次**，却不在 PENDING_ARMS 里 ⇒ 存在未声明的慢站点"
            fail=1 ;;
    esac
done

echo
if [ "$fail" -eq 0 ]; then
    echo " 完成  声明与实际一致（线性：${LINEAR_ARMS# } · 待修：${PENDING_ARMS# }）"
    exit 0
fi
echo "❌ 有臂退化（逐条见上）"
exit 1
