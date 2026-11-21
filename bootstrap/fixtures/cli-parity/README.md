# 命令行对照夹具

- `cases.tsv`：用例清单；参数按空白切分，`<ROOT>` 在运行时换成仓库根。
- `inputs/`：被测源文件，故意留错，供两侧报同一类诊断。
- `golden/host/`、`golden/self/`：两侧的标准输出、标准错误与退出码，已按归一规则抹平机器前缀。

重取：`python3 bootstrap/tools/cli-parity.py --bless`；只比对：不带参数跑同一条命令。
读数表在 `bootstrap/tests/parity/cli.tsv`，签名只许变好；期望列与实测不符即红。
