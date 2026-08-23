# Blender Icon Master — Agent 重建规范 v1.0

## 0. 任务目标

在 Blender 中重建当前已经确认方向的 macOS 应用 Icon，并将 `.blend` 文件作为后续所有设计调整的 **Source of Truth**。

目标视觉：

- 银白、轻盈、清透的现代金属质感。
- 接近玻璃的“润”和完整表面感，但明确仍然是金属。
- 不使用明显拉丝、磨砂颗粒、划痕、Noise 或旧化 Texture。
- 主体为一个带底部中央豁口的金属收纳框 / Inbox。
- 内部堆叠 4 层 Page。
- 最上层 Page 包含 3 个极简 List Item。
- 摄像机整体接近顶视图。
- 外框允许保留非常轻微的立体感。
- Page 必须与外框使用完全一致的投影关系，不允许出现单独的不自然透视。
- 风格目标是新的 macOS 图标语言，而非传统写实工业产品渲染。

最终必须同时满足：

1. 视觉接近当前 Reference。
2. 所有主要形态可参数修改。
3. 不依赖人工移动 Vertex 才能修改造型。
4. 不破坏 Modifier Stack。
5. Agent 后续能够通过 Blender MCP / `bpy` 精确修改参数。
6. 能稳定输出 1024×1024 macOS Icon。

---

# 1. Agent 工作原则

## 1.1 Blender 是 Master

所有最终几何、材质、灯光和 Camera 均保存在 Blender。

不要：

- 将 AI 图片直接贴图冒充 3D。
- 通过 Image Trace 得到不可维护的高密度 Mesh。
- Apply 所有 Modifier。
- Sculpt 主体。
- 手工移动大量 Vertex。
- 使用随机 Noise 制造金属纹理。
- 为了“看起来差不多”而破坏参数结构。

---

## 1.2 优先使用确定性控制

如果 MCP 支持执行 Blender Python：

**优先使用 `bpy` 创建与修改对象。**

不要依赖：

- 鼠标坐标点击。
- 不稳定的 UI Automation。
- 临时手工拖拽。

场景必须能够通过参数重新生成。

---

# 2. 场景坐标约定

统一规定：

```text
X = 左 / 右
Y = 前 / 后
Z = 高度
```

其中：

```text
+Y = Icon 后方 / 画面上方
-Y = Icon 前方 / 画面下方

+Z = 向上
-Z = 向下
```

Bottom Notch 永远位于：

```text
X = 0
-Y 方向
```

整个 Icon 的几何中心保持：

```text
X = 0
Y = 0
```

禁止依靠 Object Origin 偏移修正构图。

---

# 3. Collection 结构

必须建立以下 Collection：

```text
ICON_MASTER

├── 00_REFERENCE
│   └── REF_CURRENT_ICON
│
├── 10_CONTROL
│   └── CTRL_ICON
│
├── 20_FRAME
│   ├── FRAME_BODY
│   ├── CUTTER_CAVITY
│   └── CUTTER_NOTCH
│
├── 30_PAGES
│   └── PAGE_STACK
│
├── 40_GLYPH
│   ├── GLYPH_DOT_01
│   ├── GLYPH_DOT_02
│   ├── GLYPH_DOT_03
│   ├── GLYPH_LINE_01
│   ├── GLYPH_LINE_02
│   └── GLYPH_LINE_03
│
├── 50_LIGHTING
│   ├── LIGHT_KEY
│   ├── LIGHT_FILL
│   ├── LIGHT_RIM
│   └── SHADOW_PLANE
│
├── 60_CAMERA
│   └── CAMERA_ICON
│
└── 90_EXPORT
```

所有 Boolean Cutter：

```text
Viewport = 可见
Render = 隐藏
```

---

# 4. 总控制器 CTRL_ICON

创建一个 Empty：

```text
CTRL_ICON
```

它不参与渲染。

所有重要设计变量作为 Custom Properties 保存在这里。

以后 Agent 修改 Icon 时，优先修改这些参数，而不是直接修改 Mesh。

---

# 5. 第一版参数基准

采用 Blender Unit。

整体约定：

```text
约 1 BU = 视觉设计中的一个相对单位
```

不需要对应真实厘米。

## Frame

```text
FRAME_WIDTH             = 10.00
FRAME_HEIGHT            = 10.00

FRAME_DEPTH             = 1.15

FRAME_OUTER_RADIUS      = 1.95

CAVITY_WIDTH            = 7.55
CAVITY_HEIGHT           = 7.55
CAVITY_RADIUS           = 1.35

CAVITY_DEPTH            = 0.88

FRAME_BEVEL             = 0.16
FRAME_BEVEL_SEGMENTS    = 6
```

初始 Rim 宽度约：

```text
(10.00 - 7.55) / 2
≈ 1.225
```

这是当前视觉的重要比例。

---

# 6. Frame 几何

## 6.1 外轮廓

不要使用简单低段数 Rounded Cube。

生成一个接近 Continuous Corner 的二维轮廓。

推荐：

```text
Superellipse
```

公式：

```text
|x/a|^n + |y/b|^n = 1
```

初始：

```text
n ≈ 4.0 ~ 4.5
```

推荐：

```text
FRAME_SUPERELLIPSE_N = 4.2
```

至少：

```text
64 Samples
```

推荐：

```text
96 Samples
```

目的不是增加无意义面数，而是获得平滑、连续的 macOS 风格轮廓。

生成：

```text
FRAME_BODY
```

然后 Extrude：

```text
Z = 0
到
Z = -FRAME_DEPTH
```

---

# 7. Inner Cavity

创建：

```text
CUTTER_CAVITY
```

同样使用 Continuous Rounded Rectangle / Superellipse。

参数：

```text
CAVITY_WIDTH
CAVITY_HEIGHT
CAVITY_RADIUS
```

位置：

```text
X = 0
Y ≈ 0
```

从顶面向下切：

```text
Z = +0.30
到
Z = -CAVITY_DEPTH
```

Boolean：

```text
FRAME_BODY
    Boolean Difference
        CUTTER_CAVITY
```

Solver：

```text
Exact
```

必须保留 Modifier。

不要 Apply。

---

# 8. Bottom Notch

这是整个 Icon 最重要的识别结构之一。

必须：

- 正中。
- 左右完全对称。
- 从前方打开。
- 内端形成柔和 U 型。
- 能看到 Page Stack。
- 比普通浅缺口更深一些。

初始：

```text
NOTCH_WIDTH          = 2.15
NOTCH_RADIUS         = 0.68
NOTCH_DEPTH_Y        = 1.25
NOTCH_DEPTH_Z        = 0.90
```

推荐构造：

```text
Rounded Rectangle Channel
+
Circular / Capsule End
```

组成一个 Cutter：

```text
CUTTER_NOTCH
```

位置：

```text
X = 0
Y = Frame 前缘
```

Boolean：

```text
FRAME_BODY
    Boolean Difference
        CUTTER_NOTCH
```

顺序：

```text
Base Geometry
→ Cavity Boolean
→ Notch Boolean
→ Bevel
→ Normal / Smooth
```

---

# 9. Frame Bevel

Bevel 是金属质感的重要组成部分。

初始：

```text
Width       = 0.16
Segments    = 6
Profile     ≈ 0.55
```

目标：

不是制造明显倒角。

而是形成：

```text
宽而柔和的 Highlight Roll-Off
```

边缘不能：

- 像刀切。
- 像厚重机械零件。
- 出现极窄的高亮白线。

需要的是：

**柔和、连续、润的边缘反射。**

---

# 10. Page Stack

Page 不要分别人工建模。

只创建一个：

```text
PAGE_STACK
```

基础 Page：

```text
PAGE_WIDTH       = 6.45
PAGE_HEIGHT      = 5.60
PAGE_RADIUS      = 0.68

PAGE_THICKNESS   = 0.13
PAGE_BEVEL       = 0.10
```

同样优先采用 Continuous Rounded Rectangle。

Page 本身应该明显比 Frame 更薄、更轻。

---

# 11. Page 堆叠

推荐使用：

```text
Array Modifier
```

而非复制 4 个独立对象。

初始：

```text
PAGE_COUNT = 4
```

Constant Offset：

```text
X = 0

Y = -0.18
Z = -0.17
```

也就是每下一层：

- 稍微向前。
- 稍微降低。

形成当前 Reference 中：

```text
Page 01
 Page 02
  Page 03
   Page 04
```

向 Notch 方向展开的层叠关系。

---

# 12. Page 位置

最上层 Page：

```text
PAGE_TOP_X = 0
PAGE_TOP_Y ≈ +0.15
PAGE_TOP_Z ≈ -0.12
```

Page 必须完全位于 Cavity 内部。

顶层 Page 左右 Margin：

必须近似相等。

禁止通过透视制造：

```text
上窄下宽
左宽右窄
```

等不自然结构。

---

# 13. Page 投影原则

这是当前 Reference 后续优化最关键的一条。

**Page 不允许拥有独立的假透视。**

所有 Page：

- 几何平行。
- 同一个 Camera。
- 相同尺寸。
- 相同 Rounded Corner。
- 相同投影模型。

它们的差异只能来源于：

```text
Y Offset
Z Offset
真实遮挡
真实阴影
```

而不是手工 Scale 制造远近。

---

# 14. 顶层 List Item

只存在于最顶层 Page。

保持极简。

三行：

```text
● ─────────
● ─────────
● ─────────
```

---

## Dot

```text
DOT_DIAMETER = 0.62

DOT_X = -2.15
```

Y：

```text
+1.35
 0.00
-1.35
```

---

## Line

```text
LINE_LENGTH = 3.35
LINE_HEIGHT = 0.16

LINE_X ≈ +0.55
```

使用 Rounded Rectangle。

Line 圆角：

```text
LINE_HEIGHT / 2
```

形成 Capsule。

---

# 15. Glyph 深度

不要做成明显浮在 Page 上面的独立按钮。

推荐：

```text
Z Offset ≈ 0.01 ~ 0.02
```

视觉目标：

```text
浅浮雕 / 浅压印
```

如果 Agent 能稳定实现 shallow Boolean，可考虑：

```text
0.01 ~ 0.02 BU
```

的浅凹槽。

但第一版不需要为了真实 Boolean 增加不稳定性。

---

# 16. Frame Material

Material：

```text
MAT_FRAME
```

视觉目标：

> 银白金属，但不是传统拉丝铝，也不是纯玻璃。

推荐 Principled BSDF 初始值：

```text
Base Color:
Very Light Cool Silver
约 sRGB #DDE2E8

Metallic:
0.70 ~ 0.80

Default:
0.75

Roughness:
0.18 ~ 0.24

Default:
0.20

Coat Weight:
≈ 0.20 ~ 0.30

Default:
0.25

Coat Roughness:
≈ 0.08 ~ 0.12

Default:
0.09
```

---

# 17. 禁止的 Frame Material 特征

第一版明确禁止：

```text
Noise Texture
Bump
Scratch
Fingerprint
Brushed Metal Texture
Anisotropic Brush Pattern
Grunge
Wear
Dust
Edge Damage
```

不要尝试通过 Texture 表达高级感。

高级感主要来自：

```text
Geometry
Bevel
Reflection
Lighting
Tone Mapping
```

---

# 18. “清透金属”的实现原则

不要真的增加大量：

```text
Transmission
```

因为这样会变成玻璃。

视觉上的“透”来自：

- 干净表面。
- 较低 Roughness。
- 大面积柔光。
- 宽 Highlights。
- 明亮环境。
- 克制的局部 Contrast。
- Clear Coat。

所以：

```text
Transmission ≈ 0
```

仍然保持金属物理属性。

---

# 19. Page Material

Material：

```text
MAT_PAGE
```

推荐：

```text
Base Color:
#EEF0F2

Metallic:
0.00 ~ 0.05

Roughness:
0.26 ~ 0.32

Default:
0.28

Coat:
≈ 0.10 ~ 0.20
```

Page 应该比 Frame：

- 更柔。
- 更漫反射。
- 更像高级合成纸 / UI Surface。
- 不能抢 Frame 的金属高光。

---

# 20. Glyph Material

```text
MAT_GLYPH
```

颜色：

```text
#AEB4BA
```

但整体必须非常克制。

不要纯黑。

Roughness：

```text
≈ 0.30
```

目标：

缩小后还能看出来是 List。

但不能变成 Icon 的第一视觉焦点。

---

# 21. Camera

使用：

```text
Orthographic Camera
```

明确禁止：

```text
Perspective Camera
```

原因：

我们需要：

- 顶视图感。
- 几何比例稳定。
- Page 和 Frame 投影一致。
- 类似新版 macOS Icon 的正面呈现。

---

# 22. Camera Angle

不是完全数学意义的 90° 顶视图。

允许非常轻微的 Tilt，使外框保留少量厚度。

第一版：

```text
CAMERA_TILT = 10° ~ 12°
```

推荐：

```text
12°
```

如果后续觉得仍太有透视：

```text
8°
```

如果太平：

```text
14°
```

正常调整范围：

```text
8° ~ 15°
```

不要超过：

```text
18°
```

---

# 23. Camera 构图

保持：

```text
X = 0
```

Camera 对准 Icon 中心附近。

Orthographic Scale：

```text
≈ 13.4 ~ 13.8
```

初始：

```text
13.6
```

目标：

Icon 主体占整个 1:1 Canvas：

```text
约 72% ~ 76%
```

宽度。

四周必须有足够 breathing room。

---

# 24. Lighting 总原则

不要使用：

```text
小型硬光源
强 Spotlight
强烈 HDRI
复杂彩色灯光
```

使用：

**Large Softbox Lighting**

让金属的高级感来自大型柔和反射。

---

# 25. LIGHT_KEY

大型 Area Light。

位置大致：

```text
右前上方
```

尺寸：

```text
8 ~ 10 BU
```

它应该产生：

- 宽阔高光。
- 顶部柔和提亮。
- 金属表面大尺度 gradient。

不要形成清晰硬边。

---

# 26. LIGHT_FILL

位置：

```text
左侧 / 左后
```

尺寸：

```text
6 ~ 8 BU
```

强度明显低于 Key。

负责：

- 防止阴影过黑。
- 让左侧仍然保持清透。

---

# 27. LIGHT_RIM

非常柔和的顶部 / 后方 Area。

作用：

- 拉开 Frame 外轮廓。
- 给上缘提供一点连续 Highlight。

不要形成摄影棚式强 Rim Light。

---

# 28. World

World：

```text
非常浅的 Neutral Gray
```

Strength：

```text
≈ 0.3 ~ 0.5
```

默认：

```text
0.4
```

不要使用纯黑 World。

---

# 29. Shadow Plane

在 Icon 下方放置：

```text
SHADOW_PLANE
```

颜色：

```text
#F3F3F3
```

Roughness：

```text
≈ 0.6
```

Shadow 必须：

- 非常柔。
- 接近 Contact Shadow。
- 不制造明显悬浮。
- 不形成摄影产品的黑色重阴影。

---

# 30. Render Engine

Master Render：

```text
Cycles
```

不要以 Eevee 最终结果作为 Master。

Eevee 可以用于实时 Preview。

---

# 31. Cycles 设置

建议：

```text
Samples:
256
```

Final：

```text
256 ~ 512
```

Denoise：

```text
OpenImageDenoise
```

Adaptive Sampling：

```text
ON
```

---

# 32. Color Management

优先：

```text
AgX
```

Look：

```text
Medium Low Contrast
```

或接近中性的 AgX。

Exposure 初始：

```text
+0.2 ~ +0.3
```

目标：

- High Key。
- 不发灰。
- 不过曝。
- Highlight 仍有层次。

---

# 33. Render Resolution

工作 Preview：

```text
1024 × 1024
```

Master：

```text
2048 × 2048
```

最终 1024 Icon：

从 2048 Downsample。

不要直接只在 1024 做最终抗锯齿判断。

---

# 34. Alpha 输出

建议同时保留：

## Master

```text
RGBA
Transparent Film
```

## Preview

```text
Light Gray Background
```

Master 用于以后真正生成 macOS Icon Asset。

Preview 用于视觉评审。

---

# 35. Reference Image

如果 Agent 能获得当前已经确认效果的 PNG：

放入：

```text
00_REFERENCE
```

创建：

```text
REF_CURRENT_ICON
```

类型优先：

```text
Image Empty
```

不要把 Reference Plane 放进最终 Render。

Reference：

```text
Render Visibility = OFF
```

建议在 Camera View 中：

```text
Opacity ≈ 0.30 ~ 0.50
```

用于核对：

- 外框比例。
- Page 大小。
- Notch。
- 构图。
- Page Stack。

---

# 36. Agent 不要逐像素 Trace Reference

Reference 只负责：

```text
视觉比例校准
```

真正几何必须由参数决定。

如果 Reference 存在轻微 AI 几何错误：

**以正确的参数化 3D 几何为准，而不是忠实复制错误。**

---

# 37. Agent 执行阶段

必须分阶段执行。

---

## Phase A — Scene Skeleton

完成：

- Collection。
- CTRL_ICON。
- Camera。
- 基础 Render Setting。

保存：

```text
icon_master_A.blend
```

---

## Phase B — Frame

完成：

- FRAME_BODY。
- CUTTER_CAVITY。
- CUTTER_NOTCH。
- Bevel。
- Smooth Normal。

Render Preview。

只检查：

```text
Silhouette
Rim
Notch
Depth
Camera
```

此时不要做 Page。

---

## Phase C — Page Stack

建立：

```text
PAGE_STACK
```

检查：

- Width。
- Height。
- Radius。
- 4 Layer Stack。
- 与 Notch 的关系。
- Page 是否和 Frame 使用一致投影。

Render Preview。

---

## Phase D — Glyph

加入：

- 3 Dot。
- 3 Line。

只允许极简。

---

## Phase E — Material

先做：

```text
MAT_FRAME
MAT_PAGE
MAT_GLYPH
```

不要立刻增加 Texture。

---

## Phase F — Lighting

依次调整：

```text
KEY
FILL
RIM
WORLD
```

调整目标：

> 让 Metal 变润，而不是增加 Metal Texture。

---

## Phase G — Final Render

输出：

```text
icon_preview_1024.png

icon_master_2048.png

icon_master_rgba_2048.png
```

保存：

```text
icon_master_v001.blend
```

---

# 38. Master 文件中的参数区

最终必须确保以下参数可以独立修改：

```text
FRAME_WIDTH
FRAME_HEIGHT
FRAME_DEPTH

FRAME_OUTER_RADIUS
FRAME_BEVEL

CAVITY_WIDTH
CAVITY_HEIGHT
CAVITY_RADIUS
CAVITY_DEPTH

NOTCH_WIDTH
NOTCH_RADIUS
NOTCH_DEPTH_Y
NOTCH_DEPTH_Z

PAGE_WIDTH
PAGE_HEIGHT
PAGE_RADIUS
PAGE_THICKNESS
PAGE_COUNT

PAGE_STEP_Y
PAGE_STEP_Z

DOT_DIAMETER

LINE_LENGTH
LINE_HEIGHT

LIST_VERTICAL_GAP

CAMERA_TILT
CAMERA_ORTHO_SCALE
```

---

# 39. 推荐额外保存 Material 参数

```text
FRAME_METALLIC
FRAME_ROUGHNESS
FRAME_COAT
FRAME_COAT_ROUGHNESS

PAGE_ROUGHNESS

WORLD_STRENGTH

KEY_POWER
FILL_POWER
RIM_POWER
```

这样未来材质也能通过 Agent 精确调整。

---

# 40. Agent 后续修改协议

后续用户可能发出：

> 外框圆角再大一点。

Agent 应转换成：

```text
FRAME_OUTER_RADIUS += X
```

---

> 豁口深一些，但是不要变宽。

只修改：

```text
NOTCH_DEPTH_Y
```

禁止修改：

```text
NOTCH_WIDTH
```

---

> Page 再紧凑一点。

优先修改：

```text
PAGE_STEP_Y
PAGE_STEP_Z
```

不要重新 Scale 每个 Page。

---

> Page 圆角更大。

只修改：

```text
PAGE_RADIUS
```

---

> 更像顶视图。

只修改：

```text
CAMERA_TILT
```

不要 Scale Page 模拟顶视图。

---

> 金属更润一点。

优先依次尝试：

```text
FRAME_ROUGHNESS ↓
FRAME_COAT ↑
LIGHT_SIZE ↑
LIGHT_POSITION
WORLD_STRENGTH
```

不要首先添加 Texture。

---

# 41. 几何验收标准

Frame：

- 左右完全对称。
- Notch 位于 X=0。
- Cavity 位于 X=0。
- Rounded Corner 连续。
- 无 Boolean Artifact。
- 无明显 Normal Artifact。

Page：

- 4 层完全平行。
- 左右 Margin 一致。
- 每层 Y Offset 一致。
- 每层 Z Offset 一致。
- 不存在独立透视 Scale。

---

# 42. 视觉验收标准

1024：

- 金属清透。
- Frame 仍明显是金属。
- 没有明显 Texture。
- Page Stack 一眼可见。
- Notch 有明确深度。
- Icon 整体安静、单色。

128px：

必须还能辨认：

```text
Frame
Notch
Stacked Page
List
```

64px：

至少还能辨认：

```text
Frame + Notch + Page
```

32px：

Silhouette 必须仍然成立。

---

# 43. 明确失败条件

出现以下任一情况均视为偏离方向：

### 材质

```text
明显拉丝
磨砂颗粒
划痕
工业铝
旧化
塑料感
纯玻璃感
```

### Camera

```text
明显 Perspective
Page 上窄下宽
Page 和 Frame 透视不一致
```

### Shape

```text
Notch 偏心
Page 不对称
Frame 过厚重
Rounded Corner 像普通廉价圆角矩形
```

### Lighting

```text
黑色重阴影
锐利硬高光
强烈 Studio Product Photography 感
```

---

# 44. 第一轮不要做的事情

暂时不要加入：

- 彩色状态 Dot。
- Checkbox。
- Issue 编号。
- Text。
- Logo 字母。
- Glass Shader。
- 背景渐变。
- 高复杂度 Geometry Nodes。
- HDRI 素材依赖。
- 材质贴图。
- 动画。

先把：

```text
Shape
Proportion
Camera
Material
Lighting
```

五件事情做好。

---

# 45. Blender Master 最终结构

最终 Scene 应保持类似：

```text
CTRL_ICON
   │
   ├── parameters
   │
   ▼

FRAME_BODY
   ├── Boolean: Cavity
   ├── Boolean: Notch
   └── Bevel

PAGE_STACK
   ├── Bevel
   └── Array × 4

GLYPH
   └── Top Page Only

CAMERA_ICON
   └── Orthographic

LIGHTING
   ├── Key
   ├── Fill
   └── Rim
```

这是整个 Icon 的长期 Master。

---

# 46. 最重要的设计原则

Agent 必须始终遵循：

> 这个 Icon 的高级感不是来自复杂度，而是来自比例、曲面、边缘、反射和克制。

优先级：

```text
1. Silhouette
2. Proportion
3. Camera
4. Bevel
5. Lighting
6. Material
7. Detail
```

不要颠倒顺序。

---

# 47. 第一版 Agent 的完成定义

只有同时完成以下内容才算完成：

- [ ] 创建规范 Collection。
- [ ] 创建 `CTRL_ICON` 参数控制器。
- [ ] 创建可编辑 Frame。
- [ ] Cavity 使用独立 Boolean Cutter。
- [ ] Notch 使用独立 Boolean Cutter。
- [ ] 所有 Boolean 保持 Non-destructive。
- [ ] Page Stack 使用统一参数。
- [ ] 建立 4 层 Page。
- [ ] 创建 3 行 List Glyph。
- [ ] Camera 为 Orthographic。
- [ ] Camera 接近顶视图。
- [ ] Metal 无 Texture。
- [ ] 完成三灯 Softbox Lighting。
- [ ] 使用 Cycles 完成 Preview。
- [ ] 输出 1024 Preview。
- [ ] 输出 2048 Master。
- [ ] 保存 `.blend` Master。
- [ ] 后续修改无需重新建模。