# Inbox App Icon — Blender Master

规范：[SPEC_ICON.md](SPEC_ICON.md)。参考图：`reference/`。

## 文件

| 路径 | 作用 |
|---|---|
| `build_icon.py` | **唯一的几何来源**。从 `PARAMS` 生成整个场景；Boolean / Array / Bevel 全部保留为 Modifier |
| `blend/icon_master_v001.blend` | 由脚本生成的 master。`CTRL_ICON` 的 Custom Properties 里存着构建时的全部参数 |
| `renders/icon_preview_1024.png` | 灰底预览（视觉评审用） |
| `renders/icon_master_2048.png` / `_rgba_2048.png` | Master；最终 1024 从 2048 降采样 |

## 重新生成

```bash
B=/Applications/Blender.app/Contents/MacOS/Blender
cd design/icon
$B --background --factory-startup --python build_icon.py -- --render --res 1024 --samples 64 --out test
$B --background --factory-startup --python build_icon.py -- --set FRAME_OUTER_RADIUS=2.2 --render --res 768 --samples 48 --out r22
$B --background --factory-startup --python build_icon.py -- --save blend/icon_master_v007.blend
$B --background --factory-startup --python build_icon.py -- --phase B --stats     # 只建 Frame，打印求值后面数/包围盒
```

改参数的正确姿势：改 `PARAMS` → 重跑脚本。不要在 `.blend` 里手动搬顶点——脚本一重跑就没了。
交互式微调可以在 Blender 里直接改 modifier 数值看效果，确认后回填 `PARAMS`。

## 工艺模型

整个底座按**一块等厚钢板弯折**理解：外轮廓（`FRAME_WIDTH/HEIGHT/OUTER_RADIUS`，正圆角 n=2）、板厚（`RIM_WIDTH`）、统一倒角（`FRAME_BEVEL`，G2 截面）。

- **所有棱一个倒角半径**，截面是 n=2.8 的超椭圆（两端曲率为零，与平面 G2 相接，金属反射里没有"倒角起始线"）。`g2_profile()` 已用立方体实测方向：点凸向 (1,1) 即外凸。
- 腔的尺寸 = 外轮廓 − 2·`RIM_WIDTH`；腔圆角 `CAVITY_RADIUS` 按实测单独给（1.0）。
- 豁口是沿 Y 挤出的**胶囊截面**（`notch_section`：直壁 + 半圆底 + 直壁与顶面间 `NOTCH_SHOULDER` 的圆角）。**槽底必须高于腔底 ≥ 2×倒角 + 余量**，它只与 ⟂Y 的平面相交，每条棱二面角恒定。
- 两个 cutter 放在 `CUTTERS` collection 里，一个 Boolean（Exact + Self Intersection）一次切；之后 `Bevel`（angle 30°、`vmesh_method CUTOFF`、不开 clamp overlap）→ `Weighted Normal`。
- 几何验收用 `python3 /tmp/t5.py` 那类脚本：BVH 自重叠面计数必须为 0（`build_icon.py --stats` 只看包围盒，抓不到 Bevel 翻卷）。

## 像素实测（主参考图，框宽 878 px = 10 BU；`measure.py` 对两张图跑同一套边缘检测）

| 项 | Reference | 采用 | 备注 |
|---|---|---|---|
| 外圆角 | 正圆 r=2.02（rmse 1.2 px，超椭圆都更差） | 2.00，n=2 | |
| rim | 1.34 | 1.30 | |
| rim 内倒角带 | 0.25 | 0.20 | 用户明确说 0.25 看着大 |
| 腔圆角 | ≈1.0 | 1.00 | |
| 页边 | ±3.46 | ±3.45 | ✓ |
| 腔壁顶缘 | ±3.63 | ±3.61 | ✓ |
| 豁口 | 半宽 1.24 一路不变、最后 0.26 内收圆 | 胶囊，直径 2.5 | |
| 前立面可见高 | 0.74 | 2.8·sin15° = 0.72 | |
| 页堆每级台阶（屏幕） | 0.36–0.40 | Y −0.28 / Z −0.17 → 0.31 | |
| 腔后壁可见带 | 0.58 | 0.41 | 参考图有透视（腔投影高 7.8 > 宽 7.32），正交做不到 |
| 豁口深度 | ≈72% 体厚 | 64% | 上限由"槽底 ≥ 腔底 + 2×倒角"决定 |

亮度探针（/tmp/lum.py 思路：对应位置 9×9 均值）：rim 顶 ±5 以内、前立面 ±5；腔壁偏亮 +35–47（参考图腔内更暗）、外倒角偏暗（反射两侧地平线）。

## 光照模型（由亮度探针反推）

参考图：腔后壁 162、前立面 170 暗，rim 顶 229–238 亮 → **主光在后上方**；`KEY_POS` (0, 9, 12)，`FILL_POS` 前上方 60° 弱光照页前立面，`RIM_POS` 正上方。World 是影棚穹顶（地面亮、地平亮、中高角 softbox 最亮），并对 −Y 半球做 `WORLD_FRONT_DARKEN` 方位衰减（相机一侧无光源）。材质 metallic 1.0 / roughness 0.32 / 无 coat。shadow plane 只承接阴影与预览背景、不进反射（灰底预览与 RGBA master 里倒角反射一致）。

## 与规范的其他偏离

| 参数 | 规范 | 实际 | 原因 |
|---|---|---|---|
| `FRAME_DEPTH` | 1.15 | 2.80 | 前立面可见高 |
| `CAVITY_DEPTH` | 0.88 | 2.25 | 页堆落底；槽底 1.78 要高于腔底 ≥ 0.45 |
| Page | 6.45×5.60 | 6.90×5.70，radius **0.50** | 实测；页与腔壁四周等距 0.25，页圆角明显小于腔圆角 1.0（两条弧不平行才读得出层次；等距同心的 0.75 看起来像一条粗线） |
| Page 位置 | Z −0.12 | Z −1.665，Y +0.60 | 底页前缘离前壁 ≥ \|Z\|·tan(tilt)，否则页边被壁顶挡住 |
| Glyph | 浮起 | 压印 0.035 + 灰色嵌件 | 爆炸图 2A/3 |
| `PAGE_STACK` | 单对象 Array×4 | `PAGE_TOP` + `PAGE_STACK`（Array×3），共享 mesh | 顶页需要压印 boolean |

## 已知坑

- **Bevel 失败的几何形态**（每一条都真实撞过）：cutter 曲面与顶面相切（Exact 退化：卷边/虚线/黑洞）；cutter 面与体面共面（共面区被当 cutter 内部，顶面被挖空）；停在顶面下再竖直向上（极矮小墙的 90° 棱被 0.2 倒角放大成尖刺）；沿 Y 放样变半径（Bevel 把站间棱当倒角棱，上千重叠面）；圆孔圆心低于顶面（倒扣棱，巨大翻卷面）；槽底 == 腔底（半圆底相切；圆角矩形底在壁面交出 0° 尖角）；槽底低于腔底（台阶面与腔底线交出四价顶点）。`notch_section` 的 6° 穿出角是扫描出来的（4°/6° 零重叠，8° 起出现）。
- Boolean 结果面继承 cutter 的 smooth 标记：cutter 不平滑，切出来的面就是平面着色（`mark_cutter` 已调 `shade_smooth`）。
- Bevel 的 `harden_normals` 把相邻四边形压成平面着色，腔壁会出竖条；改用 Weighted Normal。
- 任何两条要倒角的平行棱间距必须 **>** 2×`FRAME_BEVEL`（正好等于也会相撞），包括腔底到底面、槽底到腔底。

- **Bevel 的 `use_clamp_overlap` 是全局的**：一处会重叠就把所有棱一起缩，外缘实测只剩 0.2。关掉它，靠几何保证不重叠（任何两条要倒角的平行棱间距 ≥ 2×`FRAME_BEVEL`，包括腔底到底面）。
- Bevel modifier 在**二面角沿棱变化**的棱上会翻边：曲面 cutter 只能与 ⟂ 其挤出方向的平面相交（圆柱豁口只碰前立面和腔前壁），不能切到腔底。
- 豁口圆柱底若低于腔底会在腔底多切一条沟，沟的两条棱相距太近，倒角相撞；若与腔底相切则 Exact boolean 退化。保持 ≥ 2×bevel 的距离。
- `bpy.ops.object.shade_auto_smooth` 只作用于**选中**对象，脚本里没选区时静默跳过，结果是全平滑（平顶圆柱变球面）。`shade_smooth()` 用 bmesh 按二面角标 sharp edge。
- 轮廓生成对圆/胶囊（r = 半宽）会产生四段弧相接处的重复点，`_dedupe` 去掉；不去重 Exact boolean 会炸。
- 并行起多个 `--background` Blender 互不干扰，但共享一块 GPU，三个以上同时渲染不比串行快。
