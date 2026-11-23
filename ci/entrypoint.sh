#!/usr/bin/env bash
# Linux CI 流水线：环境 → 静态门禁 → 构建 → 并流判据。
# 阶段之间是屏障，阶段内部互不依赖的判据并发跑：先红先停留在阶段粒度。
# 任何一步非零即整体非零，不吞退出码。
set -euo pipefail

# 并流池靠 `wait -n` 收活儿：bash 5.1 起才有，旧版会静默不等待，红绿都不可信。
if [ "${BASH_VERSINFO[0]}" -lt 5 ]; then
    echo " 行不通  [环境] 并流池需要 bash 5.1+，当前 $BASH_VERSION" >&2
    exit 1
fi

cd "$(dirname "$0")/.."
script_start=$(date +%s)

# 并流宽度：6 核里 `测试` 自己就吃满，留一槽给别的判据穿插，峰值只多一个争抢者。
pool_width="${PINI_CI_JOBS:-3}"
jobs_dir="$(mktemp -d)"
trap 'rm -rf "$jobs_dir"' EXIT

# 串行阶段：进入打印标题，退出打印用时。并行阶段由 run_task 自己计时。
step_begin() {
    printf '\n=== %s ===\n' "$1"
    STEP_START=$SECONDS
}

step_end() {
    printf '  用时 %ss\n' "$((SECONDS - STEP_START))"
}

# 等先行阶段的完成标记：先行阶段无论成败都落标记，下游据产物自行判断。
wait_marker() {
    local start=$SECONDS
    while [ ! -f "$jobs_dir/$1.done" ]; do
        if [ $((SECONDS - start)) -ge 1800 ]; then
            echo " 行不通  [等待] $1 未在 1800s 内完成" >&2
            return 1
        fi
        sleep 0.2
    done
}

# 阶段实现：逐条对应串行版的动作，成败由调用方记录。
run_body() {
    case "$1" in
    "注释门禁")
        bash hooks/comment-lint.sh
        ;;
    "文档链接门禁")
        bash tools/check-doc-links.sh
        ;;
    "诊断表一致性门禁")
        # zh / en 共用一次查找：一边缺码、字段或占位符，只会在另一门语言里显出乱码。
        # 自检先证明两条判据会开火，再读真表。
        python3 tools/diagnostics-parity-check.py --self-test
        python3 tools/diagnostics-parity-check.py
        # 自举侧码表从同一份 zh 资源生成：两边码集漂移时这里先红，运行时不读 TOML。
        python3 bootstrap/tools/gen-diagnostics-table.py --check
        ;;
    "IR 契约门禁")
        python3 tools/ir-contract-check.py
        ;;
    "运行时 ABI 门禁")
        python3 tools/runtime-abi-check.py
        ;;
    "内建清单门禁")
        # 三方对照：运行时 ABI 契约 · 编译器清单 · CodeGen 的降级点。任一处不等即失败。
        python3 tools/builtin-inventory-check.py --self-test
        python3 tools/builtin-inventory-check.py
        ;;
    "标量集合门禁")
        # `*T` 的白名单只有一份，导入面与运行时各取一次名；单边增删在构建期与测试里都可能漏过。
        python3 tools/scalar-set-check.py --self-test
        python3 tools/scalar-set-check.py
        ;;
    "Unicode 数据门禁")
        # 生成物与登记的摘要逐字一致，头部声明的版本必须是钉定版本；判据不读宿主 Unicode 数据。
        python3 bootstrap/tools/gen-unicode-tables.py --check
        ;;
    "后端义务门禁（警告级）")
        # 只报不拦：决策族归零之后，这个脚本用来盯「旧的判断有没有长回来」。
        python3 tools/backend-duty-check.py
        ;;
    "能力普查门禁")
        # 拒绝所标的族必须等于该节点在契约里的小节：标错就把读者送到不含该节点的那一节。
        python3 tools/capability-census.py --check
        ;;
    "IR 契约清单门禁")
        # 清单表由契约生成：契约加了节点而没重新生成时先红，双向检查才有意义。
        python3 bootstrap/tools/gen-ir-contract-table.py --check
        ;;
    "工作区奠基门禁")
        # 首代产物是后面两段的输入；无论成败都落标记，等它的两段据产物自行报错。
        local rc=0
        .build/debug/pini build bootstrap || rc=1
        if [ "$rc" -eq 0 ]; then
            local out
            out="$(cd bootstrap && ./.build/debug/bin/pini-bootstrap)" || rc=1
            case "$out" in
            "workspace-ok "*" true") ;;
            *)
                echo "工作区产物输出不符：$out" >&2
                rc=1
                ;;
            esac
        fi
        touch "$jobs_dir/工作区奠基门禁.done"
        return "$rc"
        ;;
    "工作区测试门禁")
        # `自解析` 已由 syntax 原生门禁执行，解释器那份是重复；跳过规则零命中会直接红。
        .build/debug/pini test bootstrap --skip 自解析
        ;;
    "自举测试入口自检")
        # 失败夹具必须红、筛选与跳过必须绿、零命中必须非零：入口自身的判据先开火。
        wait_marker 工作区奠基门禁
        bash bootstrap/tools/test-gate.sh
        ;;
    "验收语料")
        # 八类共二十六例，逐例驱动宿主与自举；已知跨通道差异在 divergence-baseline.tsv，只许缩小。
        wait_marker 工作区奠基门禁
        python3 bootstrap/tools/conformance.py
        ;;
    "support 原生测试门禁")
        .build/debug/pini test-llvm bootstrap/packages/support
        ;;
    "unicode 原生测试门禁")
        .build/debug/pini test-llvm bootstrap/packages/unicode
        ;;
    "diagnostics 原生测试门禁")
        .build/debug/pini test-llvm bootstrap/packages/diagnostics
        ;;
    "syntax 原生测试门禁")
        .build/debug/pini test-llvm bootstrap/packages/syntax
        ;;
    "module-loader 原生测试门禁")
        .build/debug/pini test-llvm bootstrap/packages/module-loader
        ;;
    "semantics 原生测试门禁")
        .build/debug/pini test-llvm bootstrap/packages/semantics
        ;;
    "driver 原生测试门禁")
        .build/debug/pini test-llvm bootstrap/packages/driver
        ;;
    "ir 原生测试门禁")
        .build/debug/pini test-llvm bootstrap/packages/ir
        ;;
    "格式门禁")
        # 语料已是规范形；豁免表在 tools/fmt-exempt.tsv，拒绝态与语法标本两类都受检，过期即红。
        PINI_BIN="$PWD/.build/debug/pini" python3 tools/fmt-gate.py
        ;;
    "示例门禁")
        # 三腿：check / run / run-llvm。已知失败在 examples/gate-baseline.tsv，只许缩小。
        PINI_BIN="$PWD/.build/debug/pini" python3 tools/examples-gate.py
        ;;
    "差分探针门禁")
        # 判据自检不需要 lli：证明「按设计拒绝」那一格会开火，也不会吞掉真缺口。
        python3 tools/ir-parity-probe.py --self-test
        # 镜像没有 lli 时明确跳过并说出原因：跳过不等于通过，故这一行必须打出来。
        if [ -n "${PINI_LLVM_BIN:-}" ] || command -v lli >/dev/null 2>&1; then
            PINI_SWEEP_BIN="$PWD/.build/debug/pini" python3 tools/ir-parity-probe.py \
                --root examples --baseline tools/ir-parity-baseline.tsv
        else
            echo "  跳过：镜像里没有 lli（未设 PINI_LLVM_BIN，PATH 里也没有）"
        fi
        ;;
    "测试")
        # `-q` 只留失败条目与汇总：逐条 passing 行把日志推到两千行以上。
        swift test -q --disable-sandbox
        ;;
    *)
        echo " 行不通  [流水线] 未登记的阶段 $1" >&2
        return 1
        ;;
    esac
}

# 单个阶段：日志与耗时各写自己那份，池按声明顺序回放，读法与串行一致。
run_task() {
    local name="$1"
    (
        set -e
        start=$SECONDS
        trap 'code=$?; if [ "$code" -eq 0 ]; then printf "  用时 %ss\n" "$((SECONDS - start))"; else printf " 行不通  [%s] 用时 %ss\n" "$name" "$((SECONDS - start))"; fi' EXIT
        printf '\n=== %s ===\n' "$name"
        run_body "$name"
    )
}

# 池：按宽度并发，全部结束后按声明顺序回放日志；任一失败即池失败。
run_pool() {
    local width="$1"
    shift
    local -a names=("$@")
    local index=0 running=0 failed=0 slot
    while [ "$index" -lt "${#names[@]}" ] || [ "$running" -gt 0 ]; do
        while [ "$running" -lt "$width" ] && [ "$index" -lt "${#names[@]}" ]; do
            slot="$index"
            (
                run_task "${names[$slot]}" >"$jobs_dir/$slot.log" 2>&1
                printf '%s' "$?" >"$jobs_dir/$slot.status"
            ) &
            index=$((index + 1))
            running=$((running + 1))
        done
        if [ "$running" -gt 0 ]; then
            wait -n || true
            running=$((running - 1))
        fi
    done
    for slot in "${!names[@]}"; do
        cat "$jobs_dir/$slot.log"
        if [ "$(cat "$jobs_dir/$slot.status" 2>/dev/null || echo 1)" -ne 0 ]; then
            failed=1
        fi
    done
    return "$failed"
}

step_begin "环境"
# 不以 root 跑：只读文件的权限判据在 root 下恒真，那一条会从「判据」退化成「空判」。
# 容器默认用户是 root，故由调用方用 `--user` 指定，此处只做兜底断言。
if [ "$(id -u)" -eq 0 ]; then
    echo "不应以 root 运行：权限类判据会失效。请用 --user \$(id -u):\$(id -g) 并设 HOME=/tmp。" >&2
    exit 1
fi
swift --version
printf 'clang: %s\n' "$(command -v clang || echo 缺失)"
printf 'lli:   %s\n' "$(command -v lli || echo 缺失)"
printf 'python3: %s\n' "$(python3 --version 2>&1)"

# 工具链自检：Package.swift 声明的最低工具链必须被满足。
# 不满足时给出「声明值 vs 实际值」两个数，而不是让 SwiftPM 抛一句解析失败。
declared="$(sed -n 's#.*swift-tools-version:\([0-9][0-9.]*\).*#\1#p' Package.swift | head -1)"
actual="$(swift --version | sed -n 's/.*Swift version \([0-9][0-9.]*\).*/\1/p' | head -1)"
printf 'tools-version 声明: %s · 实际 Swift: %s\n' "${declared:-未知}" "${actual:-未知}"
if [ -z "$declared" ] || [ -z "$actual" ]; then
    echo "工具链自检无法读数，判为不通过" >&2
    exit 1
fi
if [ "$(printf '%s\n%s\n' "$declared" "$actual" | sort -V | head -1)" != "$declared" ]; then
    echo "工具链过旧：包声明 $declared，镜像是 $actual。换镜像，不要改包声明。" >&2
    exit 1
fi

# 缺工具链即失败：跳过在本地可以容忍，在 CI 不行 —— 否则「全绿」与「这批根本没跑」在读数上
# 长得一样。示例门禁与测试读同一位：前者缺 lli 时拒跑，后者缺产物时记失败。
export PINI_REQUIRE_TOOLCHAIN=1
step_end

step_begin "静态门禁（11 项并发）"
if ! run_pool 6 \
    "注释门禁" \
    "文档链接门禁" \
    "诊断表一致性门禁" \
    "IR 契约门禁" \
    "运行时 ABI 门禁" \
    "内建清单门禁" \
    "标量集合门禁" \
    "Unicode 数据门禁" \
    "后端义务门禁（警告级）" \
    "能力普查门禁" \
    "IR 契约清单门禁"; then
    step_end
    echo " 行不通  [流水线] 静态门禁未通过，构建不再开始" >&2
    exit 1
fi
step_end

step_begin "构建"
swift build --disable-sandbox
# 运行时段单建 release：自举产物与宿主 LLVM 通道都链接它，debug 构建实测慢五倍。
swift build -c release --product PiniRuntime --disable-sandbox
. "$PWD/bootstrap/tools/runtime-lib.sh"
runtime="$(pini_runtime_lib "$PWD")" || exit 1
export PINI_RUNTIME_LIB="$runtime"
export PINI_CLI_BIN="$PWD/.build/debug/pini"
# 增量构建按内容判定：内容未变时不重链，产物时间戳也不动；检出却会刷新源码时间戳。
# 构建在此成功即产物对应当前源码，故把它对齐到此刻，免下游「产物不早于源码」误判。
touch "$PWD/.build/debug/pini"
step_end

step_begin "并流判据（16 项）"
if ! run_pool "$pool_width" \
    "工作区测试门禁" \
    "测试" \
    "工作区奠基门禁" \
    "示例门禁" \
    "差分探针门禁" \
    "自举测试入口自检" \
    "验收语料" \
    "semantics 原生测试门禁" \
    "syntax 原生测试门禁" \
    "格式门禁" \
    "ir 原生测试门禁" \
    "driver 原生测试门禁" \
    "module-loader 原生测试门禁" \
    "diagnostics 原生测试门禁" \
    "support 原生测试门禁" \
    "unicode 原生测试门禁"; then
    step_end
    echo " 行不通  [流水线] 有阶段未通过，见各段末尾的标记" >&2
    exit 1
fi
step_end

printf '\n=== 全绿（总耗时 %ss）===\n' "$(( $(date +%s) - script_start ))"
