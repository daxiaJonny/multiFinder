# AI 问答与整理设计

> 状态：已实现（2026-07-27）。使用前需本机 Cursor CLI 已登录
> （`agent login`）。

## 1. 产品边界

MultiFinder 将搜索、问答和整理明确分开：

1. **搜索**：使用 Spotlight 的文件名和内容查询，不经过 AI。
2. **问当前文件夹**：用 Cursor CLI `ask` 模式生成自然语言回答，可按需
   读取当前文件夹，但不修改文件。
3. **AI 整理**：用 Cursor CLI `plan` 模式生成结构化操作计划，由应用校验、
   预览、确认和执行。

问答不伪装成搜索结果，整理也不能跳过预览直接改动文件。

## 2. 请求链

```text
工具栏放大镜 / ⌘F
  → Spotlight 搜索
  → 结果在当前窗格展示

工具栏闪光 / ⌥⌘A
  → agent -p --mode ask --trust --output-format text
  → 窗格顶部展示自然语言回答
  → 最多携带本窗格最近 6 轮对话

工具栏魔杖
  → 输入整理要求
  → agent -p --mode plan --trust --output-format json
  → PlanValidator
  → 操作预览
  → FileOperationService 执行（可撤销）
```

GUI 应用的 `PATH` 不可靠，默认使用 `~/.local/bin/agent`；可通过
`AIPlannerExecutablePath` UserDefaults 覆盖。请求超时为 120 秒，取消或超时都会
终止子进程。

## 3. 问答模式

- 工作目录设为当前窗格的文件夹。
- 直接显示 CLI 的文本回答，不再要求 `search/organize` JSON。
- 可回答“有多少个项目、分别是什么”、“这个项目如何启动”等目录上下文
  问题，也允许普通问答。
- 导航到其他目录时清空原目录的对话，避免上下文串扰。
- `ask` 是只读模式；即使用户在问答中要求改文件，也不会进入执行链。

## 4. 整理计划

Cursor CLI 只能返回 `organize` 计划：

```json
{
  "kind": "organize",
  "summary": "按月份归档截图",
  "operations": [
    {"op": "createFolder", "path": "Screenshots/2026-06"},
    {
      "op": "move",
      "source": "IMG_001.png",
      "destination": "Screenshots/2026-06/IMG_001.png"
    }
  ]
}
```

白名单操作只有 `createFolder` / `move` / `copy` / `rename` / `trash`。路径必须是
作用域根目录下的相对路径，禁止绝对路径、`..` 和符号链接越界。单次计划
上限为 500 条操作。

所有计划先进入预览：目标冲突会标红，用户可排除个别项后重新校验。
`trash` 始终使用废纸篓；整个计划作为一条 `AI Organize` 操作记录，可整体撤销。

## 5. UI

工具栏中的三个固定入口：

- `magnifyingglass`：普通搜索，可选当前文件夹或全局范围。
- `sparkles`：展开“问当前文件夹”面板，快捷键为 `⌥⌘A`。
- `wand.and.stars`：打开 AI 整理弹窗，生成计划后在同一弹窗切换到预览。

CLI 不可用时，问答和整理入口禁用，普通搜索仍可用。

## 6. 测试

- `CursorCLIPlannerTests`：验证问答使用 `ask + text`，整理使用 `plan + json`，
  以及超时、取消、错误和解析重试。
- `FileBrowserViewModelTests`：验证问答记录和切换目录时的上下文清理。
- `PlanValidatorTests`：验证路径越界、操作白名单、冲突和数量上限。
- `AIOrganizeServiceTests`：在临时目录执行真实整理计划并验证撤销。
