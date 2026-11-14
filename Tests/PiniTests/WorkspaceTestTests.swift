import Foundation
import PiniHost
import Testing

@Suite("工作区测试闭环", .serialized)
struct WorkspaceTestTests {

    @Test("通过用例输出固定报告并以 0 退出")
    func reportsPassingWorkspace() throws {
        guard PiniTestEnvironment.requireToolchain(["PINI_CLI_BIN"]) else { return }
        let root = try WorkspaceTestFixtures.passingWorkspace(tag: "pass")
        defer { try? FileManager.default.removeItem(at: root) }
        let cli = try #require(PiniTestEnvironment.cliPath())

        let result = try WorkspaceTestSupport.run(cli, ["test", "."], cwd: root)
        #expect(result.status == 0, "工作区测试失败：\(result.stderr)")
        #expect(result.stderr.isEmpty)
        #expect(
            result.stdout
                == """
                测试目标: 工作区 .（2 个测试 target）
                包 alpha / alpha-tests（3 个测试）
                 ✓ 加法成立
                 ✓ 负数可用
                 ✓ 减法成立
                包 beta / beta-tests（1 个测试）
                 ✓ 字符串长度
                结果: 4 通过, 0 失败

                """)
    }

    @Test("失败断言中止本测试但后续测试继续，退出码为 1")
    func keepsRunningAfterFailure() throws {
        guard PiniTestEnvironment.requireToolchain(["PINI_CLI_BIN"]) else { return }
        let root = try WorkspaceTestFixtures.failingWorkspace(tag: "fail")
        defer { try? FileManager.default.removeItem(at: root) }
        let cli = try #require(PiniTestEnvironment.cliPath())

        let result = try WorkspaceTestSupport.run(cli, ["test", "."], cwd: root)
        #expect(result.status == 1)
        #expect(result.stderr.isEmpty)
        #expect(
            result.stdout
                == """
                测试目标: 工作区 .（1 个测试 target）
                包 gamma / gamma-tests（3 个测试）
                 ✓ 甲
                 ✗ 乙: 必失
                 ✓ 丙
                结果: 2 通过, 1 失败

                """)
    }

    @Test("筛选只收窄执行面，不改变判定与顺序")
    func filtersWithoutReordering() throws {
        guard PiniTestEnvironment.requireToolchain(["PINI_CLI_BIN"]) else { return }
        let root = try WorkspaceTestFixtures.passingWorkspace(tag: "filter")
        defer { try? FileManager.default.removeItem(at: root) }
        let cli = try #require(PiniTestEnvironment.cliPath())

        let narrowed = try WorkspaceTestSupport.run(
            cli, ["test", ".", "--filter", "减法"], cwd: root)
        #expect(narrowed.status == 0, "筛选运行失败：\(narrowed.stderr)")
        #expect(
            narrowed.stdout
                == """
                测试目标: 工作区 .（1 个测试 target）
                包 alpha / alpha-tests（1 个测试）
                 ✓ 减法成立
                结果: 1 通过, 0 失败

                """)

        let missing = try WorkspaceTestSupport.run(
            cli, ["test", ".", "--filter=不存在"], cwd: root)
        #expect(missing.status == 2)
        #expect(missing.stdout.isEmpty)
        #expect(missing.stderr.contains("没有测试名匹配筛选条件 '不存在'"), "实际 stderr：\(missing.stderr)")
    }

    @Test("被筛掉的用例不执行，其输出与失败都不得出现")
    func filterSkipsExecution() throws {
        guard PiniTestEnvironment.requireToolchain(["PINI_CLI_BIN"]) else { return }
        let root = try WorkspaceTestFixtures.filterWorkspace(tag: "filter-exec")
        defer { try? FileManager.default.removeItem(at: root) }
        let cli = try #require(PiniTestEnvironment.cliPath())

        let result = try WorkspaceTestSupport.run(
            cli, ["test", ".", "--filter", "保留"], cwd: root)
        #expect(result.status == 0, "筛选运行失败：\(result.stderr)")
        #expect(result.stdout.contains("保留-执行"))
        #expect(!result.stdout.contains("排除-执行"))
        #expect(
            result.stdout
                == """
                保留-执行
                测试目标: 工作区 .（1 个测试 target）
                包 delta / delta-tests（1 个测试）
                 ✓ 保留
                结果: 1 通过, 0 失败

                """)
    }

    @Test("声明的测试 target 收集不到 |test 时门禁转红")
    func rejectsDeclaredTargetWithoutTests() throws {
        guard PiniTestEnvironment.requireToolchain(["PINI_CLI_BIN"]) else { return }
        let root = try WorkspaceTestSupport.temporaryDirectory(tag: "unregistered")
        defer { try? FileManager.default.removeItem(at: root) }
        try WorkspaceTestFixtures.writePackage(
            root, name: "gamma",
            targets: """
                [[test]]
                name = "gamma-tests"
                entry = "tests"
                """, files: ["tests/helper.pini": "旁路|func() -> ():\n    return\n"])
        try WorkspaceTestSupport.write(
            root, "pini.toml", "[workspace]\nmembers = [\"packages/gamma\"]\n")
        let cli = try #require(PiniTestEnvironment.cliPath())

        let result = try WorkspaceTestSupport.run(cli, ["test", "."], cwd: root)
        #expect(result.status == 2)
        #expect(result.stdout.isEmpty)
        #expect(result.stderr.contains("未收集到任何 |test 测试函数"), "实际 stderr：\(result.stderr)")
    }

    @Test("重复运行得到逐字节相同的报告")
    func repeatsDeterministically() throws {
        guard PiniTestEnvironment.requireToolchain(["PINI_CLI_BIN"]) else { return }
        let root = try WorkspaceTestFixtures.passingWorkspace(tag: "repeat")
        defer { try? FileManager.default.removeItem(at: root) }
        let cli = try #require(PiniTestEnvironment.cliPath())

        let first = try WorkspaceTestSupport.run(cli, ["test", "."], cwd: root)
        let second = try WorkspaceTestSupport.run(cli, ["test", "."], cwd: root)
        #expect(first.status == 0, "首次运行失败：\(first.stderr)")
        #expect(first.status == second.status)
        #expect(first.stdout == second.stdout)
        #expect(first.stderr == second.stderr)
    }

    @Test("bootstrap 工作区的测试由同一条链执行")
    func runsBootstrapWorkspaceTests() throws {
        guard PiniTestEnvironment.requireToolchain(["PINI_CLI_BIN"]) else { return }
        let cli = try #require(PiniTestEnvironment.cliPath())

        let result = try WorkspaceTestSupport.run(
            cli, ["test", "."], cwd: WorkspaceTestSupport.bootstrapRoot)
        #expect(result.status == 0, "工作区测试失败：\(result.stderr)")
        #expect(result.stderr.isEmpty)
        let expected = """
                测试目标: 工作区 .（8 个测试 target）
                包 support / support-tests（7 个测试）
                 ✓ 字节缓冲按UTF8计数
                 ✓ 切片共享存储
                 ✓ 构建器写UTF8
                 ✓ 源文本行表
                 ✓ 符号表按首次出现驻留
                 ✓ 负宽度归零
                 ✓ 位移使用归一宽度
                包 diagnostics / diagnostics-tests（20 个测试）
                 ✓ 行首与行内
                 ✓ 多字节按标量计列
                 ✓ 标量中间回退
                 ✓ 回车计入列
                 ✓ 偏移夹紧
                 ✓ 空文本
                 ✓ 合规诊断无问题
                 ✓ 未知诊断码
                 ✓ 空消息与空文件名
                 ✓ 跨度与主标签
                 ✓ 缺少主标签
                 ✓ 标签与备注保序
                 ✓ 严重度与标签名
                 ✓ 渲染基本形状
                 ✓ 主标签在前
                 ✓ 无标签只渲染头行
                 ✓ 空标签说明
                 ✓ 顺序不影响结果
                 ✓ 重复渲染相同
                 ✓ 未知文件不借位置
                包 package / package-tests（19 个测试）
                 ✓ 工作区清单
                 ✓ 包清单
                 ✓ 错误用例
                 ✓ 缺表
                 ✓ 拓扑序固定
                 ✓ 成员顺序无关
                 ✓ 产物路径
                 ✓ 重复包名
                 ✓ 成环
                 ✓ 可执行重名
                 ✓ 成员路径
                 ✓ 成员缺清单
                 ✓ 平表与点分
                 ✓ 数组表分行
                 ✓ 数组与注释
                 ✓ 形状错误
                 ✓ 注释与空行
                 ✓ 工作区标记可识别
                 ✓ 根计划可装配
                包 driver / driver-tests（1 个测试）
                 ✓ 公开调用可用
                包 unicode / unicode-tests（41 个测试）
                 ✓ 骨架折叠形近字母
                 ✓ 骨架跨脚本折叠
                 ✓ 骨架多标量目标
                 ✓ 骨架先分解
                 ✓ 骨架不折叠大小写
                 ✓ 骨架数字零
                 ✓ 骨架未映射保持
                 ✓ 骨架幂等
                 ✓ 骨架非法输入原样
                 ✓ 等价拼写同键
                 ✓ 中文键不变
                 ✓ 区间限定
                 ✓ 越界夹紧
                 ✓ 分解预组合字符
                 ✓ 组合基字与附标
                 ✓ 已组合保持
                 ✓ 组合阻断
                 ✓ 规范重排
                 ✓ 组合排除
                 ✓ 韩文算术
                 ✓ 不做兼容等价
                 ✓ 等价写法归一
                 ✓ 非法输入原样
                 ✓ 脚本归属
                 ✓ 混写判定
                 ✓ 宽度与偏移
                 ✓ 拒绝截断
                 ✓ 拒绝游离续字节
                 ✓ 拒绝续字节错位
                 ✓ 拒绝过长编码
                 ✓ 拒绝代理区
                 ✓ 拒绝超出上限
                 ✓ 错误前保留标量
                 ✓ 编码往返
                 ✓ 编码宽度边界
                 ✓ 分类字母数字
                 ✓ 分类空白
                 ✓ 标识符判据
                 ✓ 单步解码消费字节数
                 ✓ 单步解码失败类别
                 ✓ 版本与特殊标量
                包 syntax / syntax-tests（61 个测试）
                 ✓ 节点池
                 ✓ 分池计数
                 ✓ 缺省子节点
                 ✓ 跨包谓词
                 ✓ 字面量谓词
                 ✓ 标签实参谓词
                 ✓ 容器谓词
                 ✓ 匹配语句谓词
                 ✓ 枚举项谓词
                 ✓ 语句谓词
                 ✓ 变量可变性
                 ✓ 元组谓词
                 ✓ 简单行
                 ✓ 关键字全表
                 ✓ 缩进与反缩进
                 ✓ 嵌套反缩进
                 ✓ 空行与注释透明
                 ✓ 括号内抑制布局
                 ✓ 块携带括号
                 ✓ 数值扫描
                 ✓ 运算符最长匹配
                 ✓ 字符串分段
                 ✓ 插值配平
                 ✓ 字符串终止符
                 ✓ 反引号标识符
                 ✓ 注释跳过
                 ✓ 制表符缩进报错
                 ✓ 坏字节与未闭合字符串
                 ✓ CRLF归一化
                 ✓ 文件末尾
                 ✓ 关键字默认英文
                 ✓ 关键字中文表
                 ✓ 关键字词表同序
                 ✓ 中文关键字宽度
                 ✓ 组合附标续写
                 ✓ 组合附标不得起始
                 ✓ 注释双向控制记警告
                 ✓ 字符串双向控制记警告
                 ✓ 代码位双向控制仍报问题
                 ✓ 真值字面量
                 ✓ 运算符拼写
                 ✓ 复合赋值映射
                 ✓ 函数声明形状
                 ✓ 参数退面
                 ✓ 优先级与结合
                 ✓ 后缀链
                 ✓ 如果分派
                 ✓ 循环与遍历
                 ✓ 匹配分派
                 ✓ 枚举与导入
                 ✓ 函数字面量
                 ✓ 错误诊断
                 ✓ 词法问题透传
                 ✓ 中文关键字解析
                 ✓ 元组序号成员
                 ✓ 本型方法标记
                 ✓ 返回列表
                 ✓ 空花括号
                 ✓ 匹配模式
                 ✓ 位置绑定
                 ✓ 自解析
                包 module_loader / module-loader-tests（14 个测试）
                 ✓ 单目标装载
                 ✓ 全量收集
                 ✓ 两次收集一致
                 ✓ 抽样零诊断
                 ✓ 测试目标含两份源码
                 ✓ 类别专用
                 ✓ 合法字节通过
                 ✓ 中途序列不算BOM
                 ✓ 换行归一
                 ✓ 单元构造
                 ✓ 条目分类
                 ✓ 排除项判定
                 ✓ 路径排序
                 ✓ 排序与输入顺序无关
                包 semantics / semantics-tests（262 个测试）
                 ✓ 参数播种
                 ✓ 自身播种
                 ✓ 本型无自身
                 ✓ 非方法无自身
                 ✓ 参数重名
                 ✓ 退面名字完整
                 ✓ 返回类型不符
                 ✓ 返回缺值
                 ✓ 值返回禁带
                 ✓ 空体缺返回
                 ✓ 空体通过
                 ✓ 测试体返回空
                 ✓ 分支全返回
                 ✓ 分支缺否则
                 ✓ 匹配全返回
                 ✓ 匹配缺臂
                 ✓ 匹配通配兜底
                 ✓ 循环不算返回
                 ✓ 延迟不算返回
                 ✓ 嵌套块返回
                 ✓ 返回类型未知
                 ✓ 体检查两次
                 ✓ 声明依赖放行
                 ✓ 未声明依赖
                 ✓ 内部实现
                 ✓ 目标非成员
                 ✓ 自导入放行
                 ✓ 归一折叠
                 ✓ 包序无关
                 ✓ 单元归属
                 ✓ 边界两次一致
                 ✓ 内建表齐全
                 ✓ 字符串成员类型
                 ✓ 数组成员类型
                 ✓ 字典成员类型
                 ✓ 形状名
                 ✓ 位置调用
                 ✓ 标签调用
                 ✓ 混合调用
                 ✓ 未知标签
                 ✓ 缺标签
                 ✓ 退面收标签
                 ✓ 重复标签
                 ✓ 个数不足
                 ✓ 个数过多
                 ✓ 默认值省略
                 ✓ 实参类型不匹配
                 ✓ 函数值调用
                 ✓ 不可调用
                 ✓ 内建函数
                 ✓ 内建成员调用
                 ✓ 实参提取
                 ✓ 待定调用
                 ✓ 调用两次一致
                 ✓ 数组字面量
                 ✓ 元素不一致
                 ✓ 跨族数值
                 ✓ 同族提升
                 ✓ 空数组无期望
                 ✓ 空数组有期望
                 ✓ 期望下传
                 ✓ 字典字面量
                 ✓ 字典键不一致
                 ✓ 集合字面量
                 ✓ 下标数组
                 ✓ 下标字符串
                 ✓ 下标字典
                 ✓ 字典键不符
                 ✓ 下标非容器
                 ✓ 下标浮点
                 ✓ 切片
                 ✓ 切片非容器
                 ✓ len参数
                 ✓ 成员调用
                 ✓ 两次判定
                 ✓ 条件非布尔
                 ✓ 条件通过
                 ✓ elif条件
                 ✓ 条件循环
                 ✓ 未知条件放过
                 ✓ 数组遍历
                 ✓ 字典遍历
                 ✓ 集合遍历
                 ✓ 元素个数
                 ✓ 非集合遍历
                 ✓ 模式不合法
                 ✓ 遍历占位
                 ✓ 步进可见
                 ✓ 循环外跳出
                 ✓ 循环内跳出
                 ✓ 嵌套循环
                 ✓ 循环变量不外泄
                 ✓ 控制两次一致
                 ✓ 类型表长
                 ✓ 类型写入
                 ✓ 类型错误标记
                 ✓ 类型表越界
                 ✓ 类型覆盖
                 ✓ 类型表确定
                 ✓ 符号对齐
                 ✓ 导入对齐
                 ✓ 未命中
                 ✓ 符号排序
                 ✓ 索引确定
                 ✓ 声明对齐
                 ✓ 同偏移分文件
                 ✓ 声明未命中
                 ✓ 声明确定
                 ✓ 空结构
                 ✓ 单字段
                 ✓ 嵌套结构
                 ✓ 两用例枚举
                 ✓ 无载荷枚举
                 ✓ 头三族共用
                 ✓ 可选两槽
                 ✓ 结果三槽
                 ✓ 字段顺序
                 ✓ 只吃形态表
                 ✓ 未约定类别
                 ✓ 布局两次一致
                 ✓ 既有包形状
                 ✓ 整数缺省
                 ✓ 浮点缺省
                 ✓ 字符串布尔缺省
                 ✓ 整数标注
                 ✓ 浮点标注
                 ✓ 非数值期望
                 ✓ 空值期望
                 ✓ 插值判定
                 ✓ 非字面量
                 ✓ 错误落表
                 ✓ 判定确定
                 ✓ 码表
                 ✓ 臂内可见
                 ✓ 臂绑定不外泄
                 ✓ 臂内遮蔽
                 ✓ 匹配语句缺变体
                 ✓ 匹配语句通配兜底
                 ✓ 匹配语句未知用例
                 ✓ 匹配语句绑定数不符
                 ✓ 重复绑定一条
                 ✓ 主体判不出
                 ✓ 延迟记录
                 ✓ 延迟体不外泄
                 ✓ 延迟体照查
                 ✓ 匹配两次一致
                 ✓ 全覆盖
                 ✓ 缺变体
                 ✓ 通配兜底
                 ✓ 未知用例
                 ✓ 字面量臂
                 ✓ 标量枚举项
                 ✓ 绑定数不符
                 ✓ 绑定作用域
                 ✓ 重复绑定
                 ✓ 可选模式
                 ✓ 可选未知
                 ✓ 空值非可空
                 ✓ 同名消歧
                 ✓ 模式分类
                 ✓ 判不出类型
                 ✓ 两次检查
                 ✓ 字段命中
                 ✓ 方法签名
                 ✓ 本型方法
                 ✓ 实例方法经类型名
                 ✓ 枚举项
                 ✓ 元组序号
                 ✓ 元组标签
                 ✓ 私有字段
                 ✓ 文件内字段跨文件
                 ✓ 未找到成员
                 ✓ 接收者未定
                 ✓ 两次判定一致
                 ✓ 加法与提升
                 ✓ 跨族拒绝
                 ✓ 字符串拼接
                 ✓ 字符串相减
                 ✓ 比较
                 ✓ 相等
                 ✓ 逻辑
                 ✓ 位运算
                 ✓ 移位
                 ✓ 一元数值
                 ✓ 逻辑与位非
                 ✓ 取址
                 ✓ try解包
                 ✓ 待定
                 ✓ 运算两次一致
                 ✓ 顶层重声明
                 ✓ 成员同名
                 ✓ 扩展块内同名
                 ✓ 扩展跨块覆盖
                 ✓ 导入撞名
                 ✓ 导入别名按文件隔离
                 ✓ 跨文件重名
                 ✓ 顺序无关
                 ✓ 可见性进表
                 ✓ 真实包注册
                 ✓ 表长对齐
                 ✓ 写入读取
                 ✓ 越界
                 ✓ 标识符覆盖
                 ✓ 成员调用覆盖
                 ✓ 形式名
                 ✓ 单元分表
                 ✓ 表确定
                 ✓ 参数入帧
                 ✓ 自身入帧
                 ✓ 跨帧遮蔽
                 ✓ 同帧重名
                 ✓ NFC同键
                 ✓ 槽位单调
                 ✓ 空栈
                 ✓ 帧与局部
                 ✓ 构造确定
                 ✓ 四级收紧
                 ✓ 次序与取严
                 ✓ 导出判定
                 ✓ 键按NFC判等
                 ✓ 键不覆盖原文
                 ✓ 标量文本
                 ✓ 容器文本
                 ✓ 容器正例
                 ✓ 可选指针文本
                 ✓ 元组函数文本
                 ✓ 嵌套文本
                 ✓ 等价正例
                 ✓ 等价反例
                 ✓ 可赋值正例
                 ✓ 可赋值反例
                 ✓ 泛型个数
                 ✓ 结果约束
                 ✓ 未声明类型
                 ✓ 名字非类型
                 ✓ 直接自引用
                 ✓ 间接成环
                 ✓ 容器断开环
                 ✓ 类型顺序无关
                 ✓ 真实包类型
                 ✓ 声明与初值
                 ✓ 标注收窄
                 ✓ 标注不符
                 ✓ 空值无望
                 ✓ let不可变
                 ✓ 参数可赋值
                 ✓ 自身不可赋值
                 ✓ 元组解构
                 ✓ 解构个数
                 ✓ 解构非名字
                 ✓ 复合赋值全部
                 ✓ 复合赋值类型不合
                 ✓ 复合赋值拼接
                 ✓ 字段写
                 ✓ 字段写不符
                 ✓ 下标写
                 ✓ 目标非左值
                 ✓ 声明重名
                 ✓ 跨块遮蔽
                 ✓ 块内声明不外泄
                 ✓ 存检查两次
                 ✓ 下划线占位
                结果: 425 通过, 0 失败

                """
        #expect(result.stdout == expected)
    }

    @Test("测试 target 按包依赖拓扑序展开")
    func ordersSuitesByDependency() throws {
        let root = try WorkspaceTestSupport.temporaryDirectory(tag: "test-order")
        defer { try? FileManager.default.removeItem(at: root) }
        try WorkspaceTestSupport.write(
            root, "pini.toml",
            "[workspace]\nmembers = [\"packages/app\", \"packages/core\"]\n")
        try WorkspaceTestFixtures.writePackage(
            root, name: "app", requires: ["core"],
            targets: """
                [[test]]
                name = "app-tests"
                entry = "tests"
                """, files: ["tests/app_test.pini": "应用|test() -> ():\n    assert(true, \"app\")\n"])
        try WorkspaceTestFixtures.writePackage(
            root, name: "core",
            targets: """
                [[test]]
                name = "core-tests"
                entry = "tests"
                """, files: ["tests/core_test.pini": "核心|test() -> ():\n    assert(true, \"core\")\n"])

        let plan = try #require(try WorkspaceBuilder.plan(rootDirectory: root.path))
        let suites = WorkspaceTestRunner.suites(in: plan)
        #expect(suites.map(\.packageName) == ["core", "app"])
        #expect(suites.map(\.targetName) == ["core-tests", "app-tests"])
    }
}

private enum WorkspaceTestFixtures {

    static func passingWorkspace(tag: String) throws -> URL {
        let root = try WorkspaceTestSupport.temporaryDirectory(tag: tag)
        // 成员清单逆序写入，执行序仍由计划器的确定性排序决定。
        try WorkspaceTestSupport.write(
            root, "pini.toml",
            "[workspace]\nmembers = [\"packages/beta\", \"packages/alpha\"]\nprofile = \"debug\"\n")
        try writePackage(
            root, name: "alpha",
            targets: """
                [lib]
                name = "alpha"
                entry = "src/api/math.pini"

                [[test]]
                name = "alpha-tests"
                entry = "tests"
                """,
            files: [
                "src/api/math.pini": """
                add|func(a: I32, b: I32,) -> (I32,):
                    return a + b
                """,
                "tests/zeta_test.pini": """
                减法成立|test() -> ():
                    assert(add(a = 3, b = 0 - 1) == 2, "3-1")
                    return
                """,
                "tests/alpha_test.pini": """
                加法成立|test() -> ():
                    assert(add(a = 1, b = 1) == 2, "1+1")
                    return

                负数可用|test() -> ():
                    assert(add(a = 0 - 2, b = 1) == 0 - 1, "负数")
                    return
                """,
            ])
        try writePackage(
            root, name: "beta",
            targets: """
                [[test]]
                name = "beta-tests"
                entry = "tests"
                """,
            files: [
                "tests/string_test.pini": """
                字符串长度|test() -> ():
                    assert(len("abc") == 3, "len")
                    return
                """
            ])
        return root
    }

    static func failingWorkspace(tag: String) throws -> URL {
        let root = try WorkspaceTestSupport.temporaryDirectory(tag: tag)
        try WorkspaceTestSupport.write(
            root, "pini.toml", "[workspace]\nmembers = [\"packages/gamma\"]\n")
        try writePackage(
            root, name: "gamma",
            targets: """
                [[test]]
                name = "gamma-tests"
                entry = "tests"
                """,
            files: [
                "tests/run_test.pini": """
                甲|test() -> ():
                    assert(1 == 1, "甲")
                    return

                乙|test() -> ():
                    assert(1 == 2, "必失")
                    return

                丙|test() -> ():
                    assert(2 == 2, "丙")
                    return
                """
            ])
        return root
    }

    static func filterWorkspace(tag: String) throws -> URL {
        let root = try WorkspaceTestSupport.temporaryDirectory(tag: tag)
        try WorkspaceTestSupport.write(
            root, "pini.toml", "[workspace]\nmembers = [\"packages/delta\"]\n")
        try writePackage(
            root, name: "delta",
            targets: """
                [[test]]
                name = "delta-tests"
                entry = "tests"
                """,
            files: [
                "tests/filter_test.pini": """
                保留|test() -> ():
                    print("保留-执行")
                    assert(true, "保留")
                    return

                排除|test() -> ():
                    print("排除-执行")
                    assert(true, "排除")
                    return
                """
            ])
        return root
    }

    static func writePackage(
        _ root: URL, name: String, requires: [String] = [], targets: String,
        files: [String: String]
    ) throws {
        let requirements =
            requires.isEmpty
            ? ""
            : "[require]\n" + requires.map { "\($0) = \"*\"" }.joined(separator: "\n") + "\n"
        try WorkspaceTestSupport.write(
            root, "packages/\(name)/pini.toml",
            "[package]\nname = \"\(name)\"\n\(requirements)\(targets)\n")
        for (relative, text) in files {
            try WorkspaceTestSupport.write(root, "packages/\(name)/\(relative)", text)
        }
    }
}
