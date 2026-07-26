# AI 整理功能设计文档

> 对应《开发计划》批次三 3.4。状态：已实现（2026-07-27，四 agent 并行完成）。
> 注意：使用前需本机 Cursor CLI 已登录（`agent login`）。
> 结论先行：AI 后端采用本机 Cursor CLI（`agent` 命令），AI 只产出"结构化计划"，
> 一切文件变更由 MultiFinder 的 FileOperationService 执行——可预览、可取消、可撤销。

## 1. 目标与范围

两个用户场景，按先后实现：

1. **自然语言找文件**（只读，先做）：在当前窗格输入"上周改过的 PDF"，
   窗格展示匹配结果列表。
2. **自然语言整理文件**（写操作，后做）："把上个月的截图都归档到 Screenshots/2026-06"，
   弹出操作预览，确认后作为一个可撤销批量操作执行。

明确不做：让 AI 直接执行任何文件操作；后台自动整理；跨窗格/全盘扫描（每次以
焦点窗格当前目录为作用域根）。

## 2. 总体架构

```
用户输入（⌘⇧A 唤出 AI 输入条，位于焦点窗格顶部）
   ↓
AIPlannerService（新增协议层）
   ├─ 协议 AIPlanner：func plan(_ request: AIPlanRequest) async throws -> AIPlan
   └─ 实现 CursorCLIPlanner：Process 调用 agent CLI
   ↓
PlanValidator：白名单校验（见 §5），不通过整单拒绝
   ↓
找文件：由 MultiFinder 执行搜索条件，结果进窗格
整理：AIPlanPreviewSheet 预览 → 确认 → FileOperationService 批量执行（可撤销）
```

分层原则：`CursorCLIPlanner` 是唯一知道 CLI 存在的类型；以后接 Claude API 或
本地模型时新增一个 `AIPlanner` 实现即可。

## 3. Cursor CLI 调用约定

- 可执行文件：`~/.local/bin/agent`（绝对路径调用；GUI 应用 PATH 无 `~/.local/bin`）。
  路径可在设置中覆盖；启动时探测不存在则整个 AI 入口隐藏/禁用。
- 调用形式：
  `agent -p --mode plan --output-format json <prompt>`
  - `--mode plan`：只读模式，agent 可检索/读目录但不能改文件（第一道防线）。
  - cwd 设为焦点窗格当前目录；提示词中声明作用域根，禁止越界。
  - 可选 `--sandbox enabled` 再加一层。
  - 超时 120s，超时/取消即 `Process.terminate()`（复用压缩解压的进程管理写法）。
- 输出：外层是 CLI 的 JSON 包装，取最终文本字段；文本要求为纯 JSON 计划
  （提示词强制"只输出 JSON，不要 markdown 代码块"）。解析失败自动带错误重试一次，
  再失败则报错给用户。

## 4. 计划 JSON Schema

顶层：

```json
{
  "kind": "search" | "organize",
  "summary": "给用户看的一句话中文说明",
  "search": { ... },        // kind=search 时必填
  "operations": [ ... ]     // kind=organize 时必填
}
```

`search`（找文件——agent 返回条件，不返回文件列表；搜索由 App 执行，避免信任
agent 给的路径，也更快）：

```json
{
  "nameContains": ["截图", "Screenshot"],   // 可选，OR 关系
  "extensions": ["png", "jpg"],             // 可选
  "modifiedAfter": "2026-06-01",            // 可选，ISO 日期
  "modifiedBefore": "2026-07-01",           // 可选
  "minSize": 0, "maxSize": 0,               // 可选，字节，0=不限
  "recursive": true
}
```

执行方式：作用域根内 FileManager 枚举 + 谓词过滤（复用 FileItem 元数据）。
结果以新的 `BrowserLocation` case（如 `.aiSearch(root:criteria:title:)`）呈现，
行为对齐现有 Spotlight 位置（只读、不支持新建）。

`operations`（整理——五种白名单操作，逐条列出，不允许通配符/脚本）：

```json
[
  {"op": "createFolder", "path": "Screenshots/2026-06"},
  {"op": "move",   "source": "IMG_001.png", "destination": "Screenshots/2026-06/IMG_001.png"},
  {"op": "copy",   "source": "...", "destination": "..."},
  {"op": "rename", "source": "...", "newName": "..."},
  {"op": "trash",  "source": "..."}
]
```

所有路径一律为相对作用域根的相对路径。

## 5. 校验规则（PlanValidator，纯逻辑、可单测）

整单校验，任何一条不过即拒绝执行并展示原因：

1. `op` 必须在五种白名单内；未知字段忽略、未知 op 拒绝。
2. 所有路径解析后（standardized，拒绝 `..`、绝对路径、符号链接逃逸）必须仍在作用域根内。
3. `move/copy/rename/trash` 的 source 必须真实存在；`createFolder` 的父目录必须存在
   或由更早的 createFolder 创建。
4. 目标冲突：destination 已存在或批内重复 → 标记该条为冲突，在预览中红色显示，
   默认整单不可执行（不做静默改名；用户可去掉冲突条目后执行）。
5. 上限保护：单个计划最多 500 条操作，超出拒绝。
6. `trash` 永远走废纸篓，不做永久删除。

## 6. 执行与撤销

- 预览确认后，整个计划作为**一个**队列操作提交（新增 `FileOperationKind.aiOrganize`，
  名称如 "AI Organize"），内部按顺序执行各条目。
- 撤销复用现有变更记录模型：move/rename 记 `.moved`，copy/createFolder 记 `.created`，
  trash 记现有删除语义——与批量重命名/压缩解压完全同构，无需新撤销机制。
- 进度按条目计数；取消停在当前条目，已完成部分可整体撤销。

## 7. UI

- **入口**：⌘⇧A 或工具栏按钮，在焦点窗格顶部展开 AI 输入条（TextField + 进行中
  转圈 + 取消按钮）。CLI 不可用时入口隐藏。
- **AIPlanPreviewSheet**（复用 BatchRenameSheet 的视觉模式）：顶部显示 `summary`，
  列表每行 = 一条操作（图标区分五种 op，move/rename 显示 旧 → 新），冲突行红色 +
  原因，底部 "执行 N 项操作" / 取消。允许勾选排除个别条目（排除后重跑校验）。
- **搜索结果**：直接在窗格内呈现（同 Spotlight 位置的展示方式），路径栏显示
  自然语言标题，可加星收藏（依赖 Smart Folder 落地情况，初版可不支持收藏）。
- 错误态：CLI 报错 / 解析失败 / 校验拒绝，均在输入条下方显示简短原因。

## 8. 测试计划

- `PlanValidatorTests`：路径逃逸（`..`、绝对路径、symlink）、白名单、冲突、上限、
  createFolder 前置依赖——全部纯逻辑单测。
- `AIPlanParsingTests`：JSON 解析容错（包 markdown 代码块的输出、多余字段、缺字段）。
- `CursorCLIPlannerTests`：用假的可执行脚本（echo 固定 JSON）替换 agent 路径，
  测 Process 调用、超时、取消、重试；不依赖真实 CLI 和网络。
- 执行/撤销：加进现有 `FileOperationServiceTests` 模式，临时目录跑真实计划 +
  撤销还原断言。
- 手工验收清单：三条真实指令（找截图 / 按月归档 / 清理重复后缀）在真实 CLI 上过一遍。

## 9. 实现拆分（多 agent 并行）

| Agent | 范围 | 依赖 |
|-------|------|------|
| A | `AIPlanner` 协议 + 计划模型（Codable）+ `PlanValidator` + 解析容错 + 全部纯逻辑测试 | 无 |
| B | `CursorCLIPlanner`（Process/超时/取消/重试/CLI 探测）+ 假可执行测试 | A 的模型定义（可先按本文档 schema 各自实现，合并时对齐） |
| C | UI：AI 输入条 + `AIPlanPreviewSheet` + `.aiSearch` 位置展示 | A 的模型定义 |
| D | 执行层：`FileOperationKind.aiOrganize` 批量执行 + 撤销 + 服务测试 | A 的模型定义 |

合并顺序：A → B/C/D 并行 → 集成联调（真实 CLI 手工验收）。
预估：A/B/D 各 0.5–1 天，C 1 天，联调 0.5 天。

## 10. 风险与对策

| 风险 | 对策 |
|------|------|
| agent 输出不守 JSON 纪律 | 解析容错（剥代码块）+ 带错重试一次 + 失败可见 |
| plan 模式未来行为变化（比如允许写） | 不依赖该保证：App 只执行校验过的计划，agent 的任何直接改动一概不认；可选 --sandbox |
| CLI 未安装/未登录 | 启动探测，入口禁用 + 设置中可改路径；报错文案引导 |
| 大目录检索慢 | 搜索由 App 执行（不等 agent 枚举）；递归枚举带取消 |
| 误操作恐惧 | 预览默认全选可细调 + 冲突即阻断 + 一键撤销 + trash 不永久删除 |
