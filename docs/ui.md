# UI 视觉语言

> 目标读者：改任何视图、`Theme` 值或窗口 chrome 的人或 Agent。本文描述 **Inbox 应该长什么样以及为什么**；令牌的唯一代码来源是 `Sources/Inbox/Views/Theme.swift`。与代码不一致时，先改文档再改代码——视觉不变量比实现细节更稳定。
>
> 来源：参考 tinycast 的设计系统写法提炼，结合 PRD「Platform-native Interaction」与我们的常驻窗口形态取舍。

## 1. 一段话

Inbox 是一个**常驻的普通窗口**（有标题栏与红绿灯，可缩放），内容表面是系统 sidebar 材质的 behind-window 模糊——不是命令面板，也不是悬浮 panel。表面上的一切"墨色"来自**一条透明度阶梯**：深色模式下是不同 alpha 的白，浅色模式下是同样 alpha 的黑，没有独立的灰色值。Universal Input 是唯一的玻璃胶囊，它自己就是边界，下面不再有分割线；Scope Bar 与底栏是**透明的覆盖层**，列表从它们下面穿过，边缘用滚动驱动的渐隐遮罩**溶解**而不是被分割线裁切。选中行是安静的 10% 墨色圆角块，不是系统强调色整行填充。底栏左边是功能组（Resolved / Sort / Conflicts / Trash）——正方形的填充圆角图标按钮，和 Scope Bar 的描边胶囊一眼分得开；右边什么都没有。按键说明不进界面（交给 Help 菜单或设置）。

五条优先级排序的核心想法：

1. **表面 = 材质，不是颜色。** 不给任何大面积区域填不透明色；深度来自桌面透出来。
2. **一条墨色阶梯，没有灰。** 文字、边框、分隔、选中、hover 全部取自 `Theme.Ink` 的固定档位。
3. **栏是覆盖层，不是 chrome。** 列表占满 Input 以下的整个高度，Scope Bar 与底栏浮在上面。
4. **边缘溶解，不裁切。** 列表进入栏下方的部分按滚动距离渐隐；整个表面没有任何分割线。
5. **玻璃只给 Input。** 主表面与栏都不用玻璃；Scope chip 是描边胶囊，栏按钮是填充圆角矩形。

## 2. 令牌（`Theme.swift` 是唯一来源）

### 2.1 墨色阶梯 `Theme.Ink`

`Theme.Ink.at(_ alpha:)` 返回动态 `NSColor`：深色外观 = `white.withAlphaComponent(alpha)`，浅色外观 = `black.withAlphaComponent(alpha)`。命名档位：

| 档位 | alpha | 用途 |
|---|---|---|
| `primary` | 0.95 | 正文、chip 文字、Input 文字 |
| `secondary` | 0.60 | 时间列、P2 优先级、提示文字 |
| `tertiary` | 0.40 | 已解决行、P3、组头标题 |
| `outline` | 0.20 | chip 描边；填充按钮的选中态底色 |
| `selection` | 0.10 | Row Focus 选中块；填充按钮的选中态底色 |
| `hover` | 0.05 | 底栏图标按钮的底色（比选中行低一档，不和 Record 抢）；鼠标悬停行（如启用） |

**纸色 `Theme.Paper`**：墨色阶梯的镜像——浅色外观是白、深色外观是黑，同一 alpha。墨是「染在表面上」，纸是「从表面上抬起来」（浅色更亮、深色更暗），Input 胶囊就是这种材质。两档：`raised` = 0.7 是 Scope Bar 选中 chip 的填充，`edge` = 1（纯白 / 纯黑）是它 1pt 的描边——描边比填充亮一档，像一圈唇边，与未选中 chip 的 `outline` 描边同粗细。选中 chip 不能用墨色：会和选中行的 10% 墨块撞色；0.45 的纸上屏又几乎等于底色。

语义色只保留系统的：`systemRed`（P0）、`systemOrange`（P1、Conflict 标记）、`controlAccentColor`（仅用于文本光标与拖拽目标指示）。**不得**在视图里直接写 `NSColor.white.withAlphaComponent(...)` 或任何 `*LabelColor`/`separatorColor`——它们各自的 alpha 不成阶梯。

### 2.2 圆角阶梯 `Theme.Radius`

| 名称 | 值 | 用途 |
|---|---|---|
| `input` | 12 | Universal Input 胶囊（continuous） |
| `row` | 10 | 选中块、组头 hover |
| `control` | 6 | 底栏 / Trash 动作栏的填充按钮 |
| chip | 高度 / 2 | Scope Bar 胶囊（不是令牌，由高度决定） |

窗口本身的圆角由系统决定，不设令牌。

### 2.3 尺寸与间距 `Theme.Size` / `Theme.Spacing`

间距阶梯：2 / 4 / 6 / 8 / 10 / 12 / 16 / 20。尺寸：窗口默认 720×480、最小 480×320；Input 高 48；Scope Bar 高 36；底栏高 46（= chip 26 + 窗口边距 12 + 8 溶解余量，派生值）；chip 高 26、内边距 22、间距 8；**窗口边距 `windowInset` = 12**（窗口边缘 → 最外层 chrome：Input 胶囊、Scope Bar 轨道与 "+"、底栏按钮与提示、按钮离底边、Trash 两条栏）；**内容缩进 `contentInset` = 12**（窗口边缘 → 列表自己的轨道：选中块边缘、文字轨、时间列右缘）；两者刻意独立——调窗口这一圈不动列表（当前同为 12：选中块与 Input 同宽、列表文字与 All 字母同轨；8 太极限，16 太大）；文字轨 = 12 + 11 − 2 = 21；行竖向内边距 10；行间距 6；组头高 28。全部在 `Theme.Size` / `Theme.Spacing`（字号与行高仍在 `Preferences`，因为逻辑测试 target 用到）。

### 2.4 字号 `Theme.Typography`

尽量用系统 text style；实测本系统上 `.title3` = 15、`.subheadline` = 11、`.caption1` = 10，与现有度量不符，所以 `Theme.Typography` 里 Input（16）、组头（12 semibold）、chip（12 medium）保留字面点数，行正文 = `Preferences.recordFontSize`（body）。

## 3. 不可变的视觉不变量

- **深色是设计本体，浅色只反转墨色。** 调浅色随意；动深色值要说明理由。
- **表面不填色。** 主表面 `NSVisualEffectView(.sidebar, behindWindow)`；Scope Bar、底栏、组头、行背景全部透明。
- **没有分割线。** Input 胶囊自成边界；列表与 Scope Bar、列表与底栏之间只有溶解。
- **选中块不改变文字颜色，边缘锚在窗口坐标。** 自绘选中（10% 墨色、圆角 10）的左右边缘在窗口两侧各 `contentInset` 处，按窗口而不是按表格宽度算，滚动条出不出现都不动（`contentInset == windowInset` 时恰好与 Input 同宽，当前如此）；`interiorBackgroundStyle` 保持 `.normal`，不出现白字。
- **滚动条永远是 overlay。** `OverlayScrollView` 无视系统首选样式（连鼠标会切成 legacy）：传统滚动条会在透明表面上画不透明轨道，还会让表格变窄。
- **左右两条光学轨按墨迹定义，不按 frame。** 原则：元素各不相同（胶囊、字形、symbol、数字），但视觉上左右各一条线；不是刻板网格，允许按字形纠偏。右轨的基准是组头 chevron 的墨迹：chevron 墨迹中心 = Scope Bar "+" 字形中心（`Theme.Optical.chevronUnderPlus` 0）；日期墨迹右缘在 chevron 墨迹右缘左侧 `Theme.Optical.timeInsideChevron`（3，竖直笔画挨着斜线要内收；对齐 "+" 字形右缘时上屏显得靠右）。左轨：列表文字墨迹左缘 = All 首字母墨迹左缘 + `Theme.Optical.listTextAfterAll`（1，P 与 A 的侧边距差）。实现上这些由 `timeRail`（`contentInset` + 11 + `timeTextNudge` 4）、`textRail`（`contentInset` + 11 + `listTextNudge` −2）、`disclosureNudge` 等令牌给出，但**裁判是冒烟的 `stepOpticalRails`**：渲染窗口位图、扫描各元素墨迹边缘、按 `Theme.Optical` 断言（容差 1）。改任何 nudge / chip 尺寸 / 字号，先跑它。
- **SF Symbol 只按原生尺寸绘制，按 alignmentRect 居中。** 同一点数下所有符号共享一条 8.5pt 高的对齐带（`NSImage.alignmentRect`），平台就是靠居中这条带让眼睛、时钟、垃圾桶看起来一样大、在一条线上；把符号缩进固定槽并按包围盒居中会让尺寸各缩各的、整体低约 1pt。规则：纯符号 chip（"+"、底栏与 Trash 的图标按钮）由 cell 在 `drawInterior` 里直接画，对齐带中心 = chip 中心，原点对齐设备像素（`NSButtonCell` 对空标题不调用 `drawTitle`）；符号+文字 chip（Back、Conflicts）走 attachment，对齐带中心 = 大写字高中心；文字本身也改按大写字高居中到设备像素。冒烟 `stepOpticalRails` 断言四个图标墨迹中心与 chip 中心两轴偏差 ≤1、眼睛两态墨迹同宽同中心。
- **chip 选中不改宽度**（字重不变）。Scope Bar 胶囊：描边 `outline`，选中填 **`Paper.raised`** + 1pt 描边 **`Paper.edge`**（浅色更亮、深色更暗，和 Input 同向；描边是纯白/纯黑，比填充再亮一档）；栏按钮（`Theme.Chip.Style.filled`）：无描边，底色 `Ink.hover`（0.05），选中态 `Ink.selection`——"是按钮"靠填充表达，不用系统 bezel（实测更贵，HISTORY 性能基线）；`.plain` 无底无框、文字与符号 `secondary`，只给导航类控件（Trash 的 Back）。
- **溶解遮罩是亮度遮罩，不是颜色。** 深浅模式下同一份 `CAGradientLayer`，不随外观反转。
- **像素对齐。** 所有 chrome frame 在 backing scale 下整数对齐（冒烟有断言）。
- **先在浅色壁纸上看。** 透明与圆角遮罩的问题在深色壁纸下看不出来。

## 4. 边缘溶解（Edge Dissolve）——原理与参数

这是"列表从栏下面穿过"的实现方式，关键词：**scroll-driven mask / `CAGradientLayer` 作为 `layer.mask` / 渐隐带 / overshoot / 最小 alpha**。

- 结构：`NSScrollView` 的 frame 从 Input 下方 8 pt 一直到窗口底部；Scope Bar 与底栏作为兄弟视图覆盖在它上面（透明背景，`hitTest` 正常）。`scrollView.contentInsets = (top: scopeBarHeight, bottom: utilityBarHeight)`，`automaticallyAdjustsContentInsets = false`，于是静止时第一行正好在 Scope Bar 之下开始、最后一行在底栏之上结束。
- 遮罩：`scrollView.layer.mask = CAGradientLayer`（纵向，`startPoint (0.5,0)` → `endPoint (0.5,1)`），`colors` 是黑色的不同 alpha（亮度遮罩：alpha 1 = 可见，alpha 0 = 隐藏）。
- **顶部渐隐带**：栏自身高度范围内 alpha 为 **0**（chip 是描边透明的，任何幽灵文字都会和 chip 打架——tinycast 的 min 0.15 靠的是它们的玻璃 pill 垫底），再用 **32 pt overshoot** 从 0 渐入到 1（"幽灵化"发生在这一段：用户能感知上面还有内容）。只在 `contentOffset.y > 0` 时启用；列表停在顶端时顶带关闭，第一行完全清晰。
- **底部渐隐带**：同样栏内 alpha 0，**28 pt overshoot** 渐入；只要下方还有被遮挡的内容就启用。
- **坐标系**：`NSScrollView` 的 layer 几何是 flipped 的——`CAGradientLayer` 的 unit y = 0 在视图**顶部**。第一版按"非 flipped"写，把上下两端遮反了，是快照看出来的；改动遮罩时先用 `--snapshot-dir` 的 `main-scrolled-*` 核对方向。
- 更新时机：`NSView.boundsDidChangeNotification`（`contentView.postsBoundsChangedNotifications = true`）与 `layout()`；在 `CATransaction` 里关掉隐式动画；遮罩只读滚动状态、**不改布局**，因此不会反馈成抖动（ScopeBarView 已有同样模式，横向）。
- **前提**：`scrollView.contentView.automaticallyAdjustsContentInsets` 必须保持默认 `true`，否则 `NSScrollView.contentInsets` 根本传不到 clip view（CLAUDE.md 已知坑）。
- 不要用系统的 scroll edge effect（macOS 26 的 `NSScrollView` 边缘效果）：在透明表面上会画出硬边矩形。
- 参考数值来自 tinycast 对 Raycast 滚动区域遮罩的移植；我们的栏更矮，overshoot 先取同值，看快照再调。

## 5. 底栏（Utility Bar）

只有左边一组，右边留空（离线标签出现时靠右）。**按钮离底边 `windowInset`**，与左右留白相同；栏高是派生值 26 + `windowInset` + 8，上面 8 是列表溶解进来的余量。

- **功能组**（从左到右）Resolved · Sort · Conflicts（有冲突时出现） · Trash。Resolved / Sort / Trash 是 **正方形图标按钮**：`ScopeChipButton.iconOnly`，26×26、圆角 `control`、底色 `Ink.hover`（0.05——0.10 会和选中行同色，比 Record 还抢眼）、无描边、只有 SF Symbol（保留自绘，见 HISTORY 性能基线）——
  - Resolved：`eye.slash`（隐藏已解决，默认）⇄ `eye`
  - Sort：`clock`（Newest）⇄ `flag`（Priority），显示的是**当前排序**，点一下切换；tooltip 说明
  - Trash：`trash`
  - Conflicts 保留"⚠ N conflicts"文字 chip：它只在有事时出现，出现了就该被看见。
- Trash 表面的 Restore / Delete Permanently 也是正方形图标按钮：`arrow.uturn.backward` / `xmark.bin`（本机 SF Symbols 没有 shredder），名字在 tooltip 与无障碍标签里。
- **Trash 表面的头部**：头部条与主表面 Scope Bar 同高同轨，里面只有 `‹ Back`（`.plain`：无底无框、`Ink.secondary`，它是出口不是动作），leading = `windowInset − 4`，让 chevron 的墨迹正好落在列表文字轨上（实测两者都在 23.5；和 `listTextNudge` 一样是光学修正）。**"Trash" 标题放在标题栏的位置**——透明标题栏区（窗口顶到 safe area 顶）水平居中，`Typography.windowTitle`（`titleBarFont` 13）、`Ink.secondary`，标签可拖动窗口（`mouseDownCanMoveWindow`）：沉浸式 chrome 不变，二级表面有了名字。结构上 Trash = 头部条 + 列表 + 底部动作条，与主表面 Scope Bar + 列表 + 底栏一一对应。
- **没有按键提示。** 做过键帽 + 动作名的提示组后整体移除：对单人使用、功能本来就少的产品，常驻的快捷键说明比 Record 还抢眼。要说明快捷键，走 Help 菜单或设置，不进主界面。
- 视觉层级从强到弱：Input（纸，最亮/最暗）> Record 与选中块（墨 0.95 / 0.10）> 底栏按钮（墨 0.05）。如果 0.05 仍抢眼，下一步是去掉底色只留图标（`.plain` 样式已有）。

## 6. 列表行

- 选中块：`Ink.selection`，圆角 `Radius.row`，左右边缘在窗口坐标 `contentInset` 处，纵向占整行（含行间距的一半）；只在 Row Focus 存在——Input 取得焦点时清空选区。
- **Trash 的行与主列表完全同一套度量**：同一 `RecordCellView` 测量的显式行高、竖向内边距 10、行间距 6。冒烟断言 Trash 单行 = 主列表单行高。
- 文字色：内容 `primary`；已解决 `tertiary` + 删除线；优先级 P0 `systemRed`、P1 `systemOrange`、P2 `secondary`、P3 `tertiary`；时间 `secondary`；Conflict 标记 `systemOrange`。
- 组头：`subheadline` semibold、`tertiary`；折叠指示用 chevron，`tertiary`。

## 7. 验证

每次视觉改动：`--ui-smoke --snapshot-dir <dir>` 渲染浅/深 × 480/720/1100 × 各状态，逐张看；冒烟里的颜色断言读取 `Theme` 令牌而不是写死值；几何断言（轨道、居中、像素对齐）不变。光学轨（左右墨迹关系）由 `stepOpticalRails` 每次 `--ui-smoke` 都按位图断言，期望值在 `Theme.Optical`；frame 级断言只保证令牌一致，墨迹级断言才保证眼睛看到的一致。
