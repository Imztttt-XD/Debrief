# CLAUDE.md

Debrief（面试复盘）是一个 macOS 15+ 的 SwiftUI App：录制面试，转写，用 LLM 复盘，沉淀题库，做模拟面试。
产品介绍见 [README.md](README.md)，实现细节、数据布局和发布流程见 [ARCHITECTURE.md](ARCHITECTURE.md)。这里只写给 AI 助手的工作规则。

## 1. 构建与验证（完成任何改动前必须跑）

```sh
swift build                 # 编译，必须零 error；不要新增 warning
./scripts/test.sh           # 单元测试（Tests/DebriefTests）+ RecorderSelfTest
./build-app.sh              # 改了 Info.plist / 资源 / 签名相关时才需要
```

- 不要直接跑 `swift test`：Command Line Tools 的 Swift Testing 宏插件不在默认搜索路径上，`scripts/test.sh` 会补上。
- 不要用 `swift run Debrief` 启动 App（没有 Info.plist，申请麦克风权限时会被系统杀掉）。
- 需要看界面时用 ARCHITECTURE.md 里的 snapshot 流程（`DEBRIEF_DATA_DIR` + `DEBRIEF_SNAPSHOT_DIR`），不要去碰用户的真实数据。

## 2. 硬约束

- **只用 Command Line Tools，没有 Xcode。** 凡是依赖 Xcode 宏插件的东西都不能用：SwiftData、`@Observable`、`#Preview`、`@State` 等。状态一律用 `ObservableObject` + `@Published`。
- **用户界面文案不能硬编码。** 所有文案都写在 `scripts/gen_strings.py` 的表里（简中、繁中、英文、日文四列都要填），再运行 `python3 scripts/gen_strings.py Resources`，代码里用 `L10n.tr("key")`。生成出来的 `.strings` 文件不要手改。
- **不碰真实数据。** 任何会读写数据的运行和测试都要设置 `DEBRIEF_DATA_DIR` 指向临时目录。不要删除、移动 `~/Library/Application Support/Debrief/` 和 `~/Movies/Debrief/` 下的文件。
- **先问再改**：Bundle ID、Keychain service 名称、`Info.plist` 权限描述、数据文件名或 JSON 结构。这些一改，用户已有的权限、密钥或数据就会失效。
- 改 `Codable` 模型时，新字段必须有默认值，旧 JSON 要能继续解码；解码失败会把整个文件当作损坏处理。

## 3. 代码规范

- 注释用英文，沿用现有风格：解释“为什么”，不复述代码在做什么。
- 可测试的业务逻辑写成纯函数或值类型上的方法，不要写进 View 或 `AppStore`。参考 `Bank/BankMerge.swift`：`AppStore` 只负责调用和保存。
- 改动或新增业务逻辑时，同时在 `Tests/DebriefTests/` 加测试或更新测试（Swift Testing：`@Test`、`#expect`）。边界值（时间窗口的两端、阈值的两侧）要单独写用例。
- 改 `RecorderCore` 时，要确认 `RecorderSelfTest` 仍然全部 PASS。
- 不要引入第三方依赖，除非用户明确同意。

## 4. App 内 LLM 输出的处理规范

App 依赖模型返回结构化结果（`Review/ReviewAnalyzer.swift`、`Bank/MockEngine.swift`）。新增或修改这类调用时：

1. **只要 JSON**：调用时开启 `jsonOutput: true`，prompt 里给出完整的 JSON 示例。
2. **DTO 字段全部可选**：模型可能漏字段、给错类型。解码进 `…DTO` 后再转成领域模型，缺失的字段补默认值。
3. **不信任模型返回的值**：
   - 行号、下标要按实际范围做校验和截断；区间两端颠倒时交换。
   - 分数夹到合法范围（1–5）。
   - 枚举类字段（如 `category`）不在白名单里就归为 `other`。
4. **失败处理**：JSON 无效时重试一次，仍然失败就抛出带本地化文案的 `AIError`。只有 429、5xx 和网络错误标记为 `retryable`。
5. **每一步完成就落盘**：长流程（转写 → 抽题 → 点评 → 总结）每完成一步立即保存，保证中断后可以“继续分析”。
6. **不编造事实**：点评和参考答案只能基于转写内容和用户简历里的真实经历；prompt 里要写明这一点，改 prompt 时不能删掉这条约束。
7. **控制输出语言**：prompt 正文用中文写，输出语言通过 `outputLanguage` 传入，不要在 prompt 里写死某一种语言。
8. 改 prompt 后，用 demo 数据（`scripts/make_demo_data.py`）或一份真实转写跑一遍，对比改动前后的输出，并在汇报里写明对比结果。

## 5. 回复与汇报规范

- 用简体中文回复；代码、命令、标识符保持原文。
- 引用代码时写出文件路径（及行号）。
- 完成任务后的汇报按这个顺序写：
  1. **改了什么**：涉及的文件和行为变化，一两句说清。
  2. **怎么验证的**：实际运行的命令和结果（例如“16 个测试通过”）。
  3. **没验证的 / 风险**：没跑的步骤、需要用户在真机上确认的地方（录音权限、提醒通知、悬浮按钮等）。
- 没有实际运行过，就不能说“已测试”“能正常工作”。测试失败时贴出失败输出，不要绕过或删除测试。
- 发现与当前任务无关的问题时，单独指出，不要顺手大改。
- 为了验证而临时做的改动（例如故意改坏代码，看测试能不能抓到）必须还原，并确认已经还原。
- 除非用户要求，否则不要 commit 或 push。
