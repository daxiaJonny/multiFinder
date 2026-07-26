# MultiFinder 开发计划

> 更新于 2026-07-26。当前已完成：多窗格布局与持久化、每窗格多标签页（v4 格式 + v3 迁移）、
> 收藏/Recents/Spotlight 位置、QuickLook、带撤销/重做/冲突处理/进度/取消的文件操作队列、
> 批量重命名、zip/tar 压缩解压、跨窗格拖拽、工作区模板、iTerm2 集成、mfd CLI、
> Developer ID 分发配置与公证脚本（docs/DISTRIBUTION.md）。

每个批次内的功能可以并行开发（多 agent / 多分支），批次之间按顺序进行。
每个功能的硬性要求：跟随现有代码风格、走现有操作队列（涉及文件变更时）、
`xcodegen generate` 后 Debug 构建 + 全量测试通过、附带新测试。

---

## 批次一：日常体验补齐

### 1.1 窗格内即时过滤
- **目标**：焦点窗格按 `/`（或 ⌘F）唤出过滤输入框，输入即按文件名筛选当前列表，Esc 清除。
- **范围**：`FileBrowserViewModel` 增加 `filterText`，在 items 上做过滤层（不触发重新加载）；
  `FileBrowserPane`/`FileListView` 加输入框 UI；状态栏显示"N of M items"。
- **不做**：递归子目录过滤、内容搜索（Spotlight 位置已覆盖）。
- **验收**：过滤态下排序/选择/操作正常；切换标签或目录自动清除过滤；测试覆盖过滤逻辑。
- **规模**：小（半天）。

### 1.2 F5/F6 跨窗格复制/移动
- **目标**：经典双栏操作——把焦点窗格选中项复制（F5）/移动（F6）到"相邻窗格"当前目录。
- **范围**：`LayoutManager` 增加 `adjacentPane(of:)`（同行右侧优先，行尾回绕/下一行）；
  菜单 + 快捷键（F5/F6，注意 macOS 功能键需 fn，可另配 ⌘⇧C/⌘⇧M 备选）；
  复用 `FileOperationService` 的 copy/move（含冲突处理与撤销）。
- **验收**：单窗格时禁用；目标窗格是 Recents/Spotlight（无目录）时禁用；操作完成后目标窗格刷新并选中新项。
- **规模**：小（半天）。

### 1.3 Git 状态集成
- **目标**：git 仓库内的目录，文件列表显示状态角标（修改/未跟踪/暂存/忽略），路径栏显示当前分支。
- **范围**：新建 `Services/GitStatusService.swift`——用 `Process` 跑
  `git -C <dir> status --porcelain=v2 --branch`（不引第三方库），按目录缓存、
  借助现有 `DirectoryMonitor` 失效缓存；`FileItem` 增加可选 git 状态；
  `FileListView` 加角标列/覆盖图标；`PathBarView` 显示分支名。
- **注意**：git 不存在或超时要静默降级；大仓库首次加载不能阻塞列表（异步填充）。
- **验收**：非 git 目录零开销；状态随文件操作/外部变更刷新；测试用临时 git 仓库验证解析与缓存。
- **规模**：中（1–2 天）。

---

## 批次二：文件管理器基本盘

### 2.1 Get Info 面板 + 文件夹大小
- **目标**：⌘I 打开检查器（可做侧栏或独立窗口）：名称、类型、大小、创建/修改时间、
  权限（POSIX + 简单编辑）、macOS 标签（Tag）读写；目录支持"计算大小"（递归、可取消、结果缓存）。
- **范围**：新建 `Views/InfoPanel.swift`、`Services/DirectorySizeCalculator.swift`；
  Tag 读写用 `URLResourceValues.tagNames`；Size 列对已计算目录显示数值。
- **验收**：多选显示合计；计算中可取消；权限修改走操作队列可撤销。
- **规模**：中。

### 2.2 图标网格视图 + 图片缩略图
- **目标**：列表/网格两种视图模式切换（⌘1/⌘2），网格用 QuickLook 缩略图
  （`QuickLookThumbnailing`），按窗格记忆模式并持久化（PaneState/TabState 加字段，注意格式版本迁移）。
- **范围**：新建 `Views/FileGridView.swift`（LazyVGrid）；扩展 `IconCache` 支持异步缩略图；
  选择/右键/拖拽行为与列表一致。
- **验收**：千级文件目录滚动流畅；两种视图切换保持选中项；持久化迁移测试。
- **规模**：中。

### 2.3 保存的搜索（Smart Folder）
- **目标**：Spotlight 搜索位置可以"存入侧边栏"，点击即重新执行。
- **范围**：`FavoritesStore` 或新 store 持久化搜索条件；`BrowserLocation` 已支持
  Spotlight 类型，主要是持久化 + 侧边栏 UI + 重命名/删除。
- **规模**：小。

### 2.4 设置窗口
- **目标**：统一 Preferences（⌘,）：通用（新标签默认位置、是否显示隐藏文件默认值）、
  集成（默认终端/编辑器，为批次三 3.2 预留）、快捷键说明页。
- **范围**：新建 `Views/SettingsView.swift` 用 SwiftUI `Settings` scene；设置存 UserDefaults。
- **规模**：小–中。

---

## 批次三：效率与生态

### 3.1 命令面板（⌘K）
- 模糊搜索并执行：跳转收藏/最近目录、切换工作区模板、触发操作（新标签、压缩、重命名等）。
- 新建 `Views/CommandPalette.swift` + 可注册命令表；依赖 2.4 的设置基础设施可选。
- **规模**：中。

### 3.2 终端/编辑器抽象
- 把 `ITermService` 泛化为 `TerminalProvider` 协议（iTerm2 / Terminal.app / Warp / kitty），
  默认项在设置里选；同样加"用编辑器打开"（VS Code 等，`NSWorkspace` 即可）。
- **依赖**：2.4 设置窗口。**规模**：小–中。

### 3.3 mfd CLI 扩展
- `mfd --workspace <模板名>` 恢复工作区、`mfd --new-tab <path>` 新标签打开；
  URL scheme 增加对应参数，`MultiFinderApp` 的外部打开路径处理已有入口（`openExternalPath`）。
- **规模**：小。

### 3.4 AI 整理（探索性）
- 自然语言批量操作："把上个月的截图归档到 Screenshots/2026-06"。
- 思路：LLM 把指令翻译成结构化操作计划（筛选条件 + 操作列表）→ UI 预览确认 →
  走现有操作队列执行（天然可撤销）。先做只读的"自然语言找文件"降低风险。
- **前置**：需要决定 API key 管理方式（设置窗口）。**规模**：大，单独立项。

---

## 工程债 / 随批次顺带处理

- **CI 增强**：ci.yml 目前只跑 Debug build+test，加 Release 构建校验（防止签名配置回归）。
- **性能**：万级文件目录的加载与排序基准测试；`DirectoryMonitor` 事件风暴节流。
- **本地化**：界面串中文化（zh-Hans），建议在批次二结束、UI 稳定后一次性做。
- **App Store 路线重评估**：若未来要上架，见 docs/DISTRIBUTION.md 中沙盒化前提。

## 建议节奏

| 批次 | 内容 | 预估 |
|------|------|------|
| 一 | 过滤 + F5/F6 + Git 集成 | 2–3 天 |
| 二 | Info 面板 + 网格视图 + Smart Folder + 设置 | 4–5 天 |
| 三 | 命令面板 + 终端抽象 + CLI + AI 探索 | 按需裁剪 |

批次一的三个功能相互独立，适合继续用多 agent 并行（过滤和 F5/F6 都会碰
`ContentView`/`MultiFinderApp` 的菜单区，合并时预留少量冲突处理）。
