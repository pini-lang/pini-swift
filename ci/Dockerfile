# Pini Linux CI 镜像：钉死工具链，不为每次运行安装任何东西。
#
# 基础镜像取 swift:6.4-noble —— 与 Package.swift 的 swift-tools-version:6.4 对齐。
# 版本不符时 CI 在第一步就响亮失败（见 ci/entrypoint.sh 的工具链自检），不留半懂不懂的报错。
FROM swift:6.4-noble

# 固定 locale 与时区：诊断文案含中文，排序与格式化不得随宿主环境漂移。
# PATH 前置 llvm-18：让 lli 与 clang 同一版本成对出现，不让「新 clang 产 IR、旧 lli 解析」发生。
ENV LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    TZ=UTC \
    PINI_LLVM_BIN=/usr/lib/llvm-18/bin \
    PATH=/usr/lib/llvm-18/bin:${PATH}

# python3：四道门禁脚本的解释器。
# clang-18 与 llvm-18：成对安装。lli 与 clang 同源，避免「用新 clang 产 IR、让旧 lli 解析」。
# 钉主版本、不钉补丁：Ubuntu 安全更新会推进补丁号，钉死补丁会让镜像在某次源更新后无法重建。
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        python3 \
        clang-18 \
        llvm-18 \
    && rm -rf /var/lib/apt/lists/*

# 容器内 UID 与宿主不一致时 git 会拒绝读仓（dubious ownership），门禁因此误红。
RUN git config --system --add safe.directory '*'

WORKDIR /src

# 无 ENTRYPOINT 的默认动作：跑完整流水线。CI 与本地用同一条命令。
CMD ["bash", "ci/entrypoint.sh"]
