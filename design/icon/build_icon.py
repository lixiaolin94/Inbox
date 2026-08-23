"""Inbox macOS App Icon — Blender master builder.

按 design/icon/SPEC_ICON.md 重建整个场景。所有几何从 CTRL_ICON 上的
Custom Properties 派生，Boolean / Array / Bevel 一律保留为 Modifier。

    Blender --background --factory-startup --python build_icon.py -- [选项]

选项：
    --phase {A,B,C,D,E,F,G}   构建到哪个阶段为止（默认 G）
    --render                  渲染预览
    --samples N               覆盖 Cycles 采样数
    --res N                   渲染边长（默认 1024）
    --out NAME                渲染文件名（不含扩展名）
    --alpha                   透明底（否则灰底 + Shadow Plane）
    --save PATH               保存 .blend 到指定路径
    --set KEY=VALUE           覆盖单个参数，可重复
"""

import argparse
import math
import os
import sys

import bpy
import bmesh
from mathutils import Vector

# ---------------------------------------------------------------- 参数基准
# SPEC §5 / §38 / §39。这里是唯一的数值来源，构建时写进 CTRL_ICON。

PARAMS = {
    # Frame ------------------------------------------------------- §5 §6
    "FRAME_WIDTH": 10.00,
    "FRAME_HEIGHT": 10.00,
    "FRAME_DEPTH": 2.80,          # 前立面可见高 2.8·sin15° = 0.72 ≈ 参考图 0.74
    "FRAME_OUTER_RADIUS": 2.00,   # 主参考图拟合：正圆 r=2.02 BU（rmse 1.2 px），超椭圆都更差
    "FRAME_SUPERELLIPSE_N": 2.0,  # 参考图转角是正圆，不是超椭圆
    "FRAME_SAMPLES": 192,
    "FRAME_BEVEL": 0.20,          # 参考图 rim 内侧倒角带 17 px / 87.8 = 0.19          # 全部棱同一半径：外缘、腔缘、豁口肩/唇、腔底（参考图 rim 内外倒角带等宽）
    "FRAME_BEVEL_SEGMENTS": 14,
    "BEVEL_G2_N": 2.8,            # 倒角截面用超椭圆：两端曲率为零，与平面 G2 相接
    "RIM_WIDTH": 1.30,            # 腔 = 外轮廓减去这个量（实测 1.34）
    # Cavity ------------------------------------------------------ §7
    # CAVITY_WIDTH/HEIGHT 由 FRAME_* − 2·RIM_WIDTH 派生
    "CAVITY_RADIUS": 1.00,
    "CAVITY_DEPTH": 2.25,         # 底厚 0.55 > 2×bevel
    # Notch ------------------------------------------------------- §8
    "NOTCH_WIDTH": 2.50,          # 圆柱直径：前视是半径 1.25 的半圆（参考图逐行实测）
    "NOTCH_DEPTH_Z": 1.78,        # 64% 体厚（参考约 72%）。下限：胶囊半圆 1.25 + 肩圆角 0.45 + 0.05；
                                  # 上限：腔底 − 2×bevel − 余量。槽底与腔底齐平或更低都会让 Bevel 翻边
    "NOTCH_SHOULDER": 0.45,       # 直壁与顶面相接处的圆角（用户要求比统一倒角更圆润）
    # Page -------------------------------------------------------- §10 §11 §12
    "PAGE_WIDTH": 6.90,           # 主参考图 ±3.46 → 6.9；腔宽 7.4，两侧各留 0.25
    "PAGE_HEIGHT": 5.70,          # 顶页后缝 = 侧缝 = 0.25；底页前缘仍离前壁 ≥ |Z|·tan(tilt)
    "PAGE_RADIUS": 0.50,          # 参考图实测页圆角 ≈0.45–0.5，明显小于腔圆角 1.0，两条弧不平行才读得出层次
    "PAGE_THICKNESS": 0.15,
    "PAGE_BEVEL": 0.04,
    "PAGE_COUNT": 4,
    "PAGE_STEP_Y": -0.28,         # 主参考图垂直中线：每级台阶屏幕 0.36–0.40
    "PAGE_STEP_Z": -0.17,
    "PAGE_TOP_X": 0.00,
    "PAGE_TOP_Y": 0.60,           # 顶页后缘 3.45（后缝 0.25）；底页前缘 −3.09，离前壁 0.61
    "PAGE_TOP_Z": -1.665,         # 底页落在腔底 −2.25；腔后壁可见带 1.59·sin15 ≈ 0.41（参考 0.58）
    # Glyph ------------------------------------------------------- §14 §15
    "DOT_DIAMETER": 0.77,
    "DOT_X": -2.10,
    "LINE_LENGTH": 3.50,
    "LINE_HEIGHT": 0.16,
    "LINE_X": 0.67,
    "LIST_VERTICAL_GAP": 1.54,
    "LIST_Y": 0.30,               # 三行整体相对页中心上移
    "GLYPH_RECESS": 0.035,        # 顶页压印深度
    "GLYPH_INLAY_DROP": 0.012,    # 嵌件顶面低于页面的量
    # Camera ------------------------------------------------------ §21-23
    "CAMERA_TILT": 15.0,
    "CAMERA_ORTHO_SCALE": 14.24,  # 框宽 = 画布 70%，与主参考图一致
    "CAMERA_TARGET_Z": -0.70,
    # Material ---------------------------------------------------- §16 §19 §20
    "FRAME_METALLIC": 1.0,        # 不锈钢：纯金属，不要 coat——清漆层是"玻璃/塑料感"的来源
    "FRAME_ROUGHNESS": 0.32,      # 参考图是缎面：反射糊成渐变，U 槽底不会出现亮带
    "FRAME_COAT": 0.0,
    "FRAME_COAT_ROUGHNESS": 0.09,
    "PAGE_ROUGHNESS": 0.40,
    "PAGE_METALLIC": 0.02,
    "PAGE_COAT": 0.0,
    "GLYPH_ROUGHNESS": 0.30,
    # Lighting ---------------------------------------------------- §24-29
    "WORLD_STRENGTH": 0.80,
    "WORLD_FRONT_DARKEN": 0.30,   # 朝相机(−Y)一侧的环境亮度系数：影棚里相机一侧是暗的
    # 参考图亮度探针：腔后壁 162、前立面 170 暗，rim 顶 229–238 亮 → 主光在后上方（背光）
    "KEY_POWER": 5000.0,
    "KEY_SIZE": 12.0,
    "KEY_POS": [0.0, 9.0, 12.0],
    "FILL_POWER": 900.0,
    "FILL_SIZE": 10.0,
    "FILL_POS": [1.5, -6.0, 10.0], # 前上方约 60°：照亮页前立面，而前唇给 U 槽底投影（参考图槽底是暗的）
    "RIM_POWER": 600.0,
    "RIM_SIZE": 8.0,
    "RIM_POS": [0.0, 0.0, 14.0],
    # Render ------------------------------------------------------ §31 §32
    "EXPOSURE": 0.45,
}

COLORS = {  # sRGB hex，§16 §19 §20 §29
    "FRAME": "C2C6CA",            # 不锈钢反射色（metallic=1 时 base color 即镜面色）
    "PAGE": "E8EAEC",
    "GLYPH": "8E9398",
    "SHADOW_PLANE": "FFFFFF",
}

COLLECTIONS = [
    "00_REFERENCE",
    "10_CONTROL",
    "20_FRAME",
    "30_PAGES",
    "40_GLYPH",
    "50_LIGHTING",
    "60_CAMERA",
    "90_EXPORT",
]

HERE = os.path.dirname(os.path.abspath(__file__))


# ---------------------------------------------------------------- 小工具


def srgb_to_linear(c):
    return c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4


def hex_rgba(h, alpha=1.0):
    h = h.lstrip("#")
    rgb = tuple(int(h[i : i + 2], 16) / 255.0 for i in (0, 2, 4))
    return tuple(srgb_to_linear(c) for c in rgb) + (alpha,)


def set_input(node, names, value):
    """Principled BSDF 的输入名跨版本会变，按候选名依次尝试。"""
    if isinstance(names, str):
        names = [names]
    for n in names:
        if n in node.inputs:
            node.inputs[n].default_value = value
            return True
    print(f"  ! 输入名未命中 {names}（节点 {node.name}）")
    return False


def clear_scene():
    for obj in list(bpy.data.objects):
        bpy.data.objects.remove(obj, do_unlink=True)
    for block in (
        bpy.data.meshes,
        bpy.data.materials,
        bpy.data.lights,
        bpy.data.cameras,
        bpy.data.images,
    ):
        for item in list(block):
            if item.users == 0:
                block.remove(item)
    scene = bpy.context.scene
    for coll in list(scene.collection.children):
        scene.collection.children.unlink(coll)
    for coll in list(bpy.data.collections):
        bpy.data.collections.remove(coll)


def setup_collections():
    scene = bpy.context.scene
    root = bpy.data.collections.new("ICON_MASTER")
    scene.collection.children.link(root)
    made = {"ICON_MASTER": root}
    for name in COLLECTIONS:
        c = bpy.data.collections.new(name)
        root.children.link(c)
        made[name] = c
    return made


def link(obj, coll):
    for c in list(obj.users_collection):
        c.objects.unlink(obj)
    coll.objects.link(obj)


# ---------------------------------------------------------------- 轮廓生成


def _dedupe(pts):
    """去掉相邻重复点与首尾重合点——零长边会让 Exact boolean 失败。"""
    out = []
    for pt in pts:
        if not out or (abs(pt[0] - out[-1][0]) + abs(pt[1] - out[-1][1])) > 1e-6:
            out.append(pt)
    if len(out) > 1 and (abs(out[0][0] - out[-1][0]) + abs(out[0][1] - out[-1][1])) < 1e-6:
        out.pop()
    return out


def corner_arc(cx, cy, r, a0, a1, n, steps):
    """超椭圆转角弧：|x/r|^n + |y/r|^n = 1 从角 a0 到 a1（度）。n=2 为正圆。"""
    exp = 2.0 / n
    pts = []
    for i in range(steps + 1):
        t = math.radians(a0 + (a1 - a0) * i / steps)
        ct, st = math.cos(t), math.sin(t)
        ux = math.copysign(abs(ct) ** exp, ct) if abs(ct) > 1e-12 else 0.0
        uy = math.copysign(abs(st) ** exp, st) if abs(st) > 1e-12 else 0.0
        pts.append((cx + r * ux, cy + r * uy))
    return pts


def continuous_rounded_rect(w, h, r, n=4.2, samples=96):
    """连续曲率圆角矩形：直边 + 超椭圆转角（§6）。逆时针。"""
    hw, hh = w / 2.0, h / 2.0
    r = min(r, hw, hh)
    steps = max(4, int(samples) // 4)
    pts = []
    pts += corner_arc(hw - r, hh - r, r, 0, 90, n, steps)
    pts += corner_arc(-(hw - r), hh - r, r, 90, 180, n, steps)
    pts += corner_arc(-(hw - r), -(hh - r), r, 180, 270, n, steps)
    pts += corner_arc(hw - r, -(hh - r), r, 270, 360, n, steps)
    return _dedupe(pts)


def notch_section(r, depth, shoulder, exit_deg=6.0, corner=None):
    """豁口的 XZ 截面（(x, z) 闭合折线）：半宽 r 的直壁 + 底部两个半径 corner 的
    圆角（corner == r 即胶囊/半圆底），最低点 -depth；直壁与顶面 z=0 的两条棱用
    半径 shoulder 的圆角过渡。

    为什么是直壁而不是圆：圆孔若要深过半径，圆心就落到顶面之下，孔在顶面处
    变成倒扣（顶窄中宽），Bevel 在倒扣棱上生成巨大的翻卷面。参考图逐行实测也
    支持：半宽 1.24 一路不变，最后才收圆。

    圆角圆心 (±(r+R), -R·cos(exit))：与直壁外切、但**不**与顶面相切——弧以
    exit_deg 的小角度穿出顶面，穿出点落在折线段中间，穿出棱的二面角
    180°-exit 不会被 Bevel 的 30° 阈值选中；穿出后继续到顶面之上再竖直向上。
    exit_deg 实测（BVH 自重叠面计数）：4°/6° 为 0，8° 4，10° 20，35° 148。
    失败过的做法：与顶面相切（Exact 退化）；沿顶面共面延伸（顶面被挖空）；
    停在顶面下再竖直向上（极矮小墙被倒角放大成尖刺）；沿 Y 放样变半径
    （Bevel 把站间棱当倒角棱）。
    """
    rc = r if corner is None else min(corner, r)
    cz = -depth + rc                                     # 底圆角圆心 z
    R = max(shoulder, 1e-4)
    ex = math.radians(exit_deg)
    zc = -R * math.cos(ex)                                # 顶圆角圆心 z
    assert cz < zc - 0.05, "豁口太浅：底圆角顶已高过顶圆角切点，没有直壁段"
    xc = r + R
    stop = 90.0 + exit_deg / 2.0
    right = corner_arc(xc, zc, R, stop, 180.0, 2.0, 14)            # 顶面 → 直壁切点 (r, zc)
    wall_r = [(r, cz)]
    br = corner_arc(r - rc, cz, rc, 0.0, -90.0, 2.0, 32)            # 右底圆角
    bl = corner_arc(-(r - rc), cz, rc, -90.0, -180.0, 2.0, 32)      # 左底圆角
    wall_l = [(-r, cz)]
    left = corner_arc(-xc, zc, R, 0.0, 180.0 - stop, 2.0, 14)
    top = 0.8
    rx, rz = right[0]
    lx, lz = left[-1]
    assert rz > 0 and lz > 0, "弧的停止点必须在顶面之上"
    pts = [(rx, top)] + right + wall_r + br[1:] + bl[1:] + wall_l + left[1:] + [(lx, top)]
    return _dedupe(pts)


def resample_closed(pts, m):
    """闭合折线按弧长重采样为 m 个等距点（从 pts[0] 起）。
    放样要求相邻截面的第 i 点对应同一位置；原始截面的切点随 R 移动，
    直接按序号连接会在切点附近出现蝴蝶结四边形。"""
    n = len(pts)
    seg = [math.hypot(pts[(i + 1) % n][0] - pts[i][0], pts[(i + 1) % n][1] - pts[i][1]) for i in range(n)]
    total = sum(seg)
    out = []
    i, acc = 0, 0.0
    for k in range(m):
        target = total * k / m
        while acc + seg[i] < target - 1e-12:
            acc += seg[i]
            i = (i + 1) % n
        t = (target - acc) / seg[i] if seg[i] > 1e-12 else 0.0
        a, b = pts[i], pts[(i + 1) % n]
        out.append((a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t))
    return out


def make_loft(name, sections, ys, collection):
    """沿 Y 放样：sections[k] 是同点数的 (x, z) 截面，放在 y = ys[k]。两端封口。"""
    n = len(sections[0])
    verts = []
    for sec, y in zip(sections, ys):
        assert len(sec) == n
        verts += [(x, y, z) for x, z in sec]
    faces = []
    for k in range(len(sections) - 1):
        a, b = k * n, (k + 1) * n
        for i in range(n):
            j = (i + 1) % n
            faces.append([a + i, a + j, b + j, b + i])
    faces.append(list(range(n)))
    last = (len(sections) - 1) * n
    faces.append(list(range(last + n - 1, last - 1, -1)))
    mesh = bpy.data.meshes.new(name)
    mesh.from_pydata(verts, [], faces)
    mesh.validate(verbose=False)
    mesh.update()
    obj = bpy.data.objects.new(name, mesh)
    collection.objects.link(obj)
    bm = bmesh.new()
    bm.from_mesh(mesh)
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    bm.to_mesh(mesh)
    bm.free()
    return obj


def make_prism(name, profile, z_top, z_bot, collection):
    """把 2D 轮廓挤成闭合流形棱柱。Boolean Exact 要求流形输入。"""
    n = len(profile)
    verts = [(x, y, z_top) for x, y in profile]
    verts += [(x, y, z_bot) for x, y in profile]
    faces = [list(range(n)), list(range(2 * n - 1, n - 1, -1))]
    for i in range(n):
        j = (i + 1) % n
        faces.append([i, i + n, j + n, j])

    mesh = bpy.data.meshes.new(name)
    mesh.from_pydata(verts, [], faces)
    mesh.validate(verbose=False)
    mesh.update()

    obj = bpy.data.objects.new(name, mesh)
    collection.objects.link(obj)

    bm = bmesh.new()
    bm.from_mesh(mesh)
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    bm.to_mesh(mesh)
    bm.free()
    return obj


def shade_smooth(obj, angle_deg=32.0):
    """面全平滑 + 按二面角标 sharp edge。

    不用 shade_auto_smooth operator：它只作用于选中对象，脚本里没有选区时会
    静默跳过，结果是全平滑——平顶圆柱被渲染成球面。
    """
    me = obj.data
    for poly in me.polygons:
        poly.use_smooth = True
    bm = bmesh.new()
    bm.from_mesh(me)
    limit = math.radians(angle_deg)
    for e in bm.edges:
        if len(e.link_faces) == 2 and e.calc_face_angle(0.0) > limit:
            e.smooth = False
    bm.to_mesh(me)
    bm.free()
    me.update()


def g2_profile(bevel_mod, n):
    """把 Bevel 截面设成超椭圆 |x|^n + |y|^n = 1（凸向 (1,1)）。
    n=2 是圆弧（G1）；n>2 两端曲率趋零，与相邻平面 G2 相接，金属反射里
    没有"倒角起始线"。已用立方体实测：点凸向 (1,1) 即外凸圆角。"""
    bevel_mod.profile_type = "CUSTOM"
    cp = bevel_mod.custom_profile
    exp = 2.0 / n
    for i in range(1, 12):
        t = math.radians(90.0 * i / 12)
        cp.points.add(math.cos(t) ** exp, math.sin(t) ** exp)
    for pt in cp.points:
        pt.handle_type_1 = "AUTO"
        pt.handle_type_2 = "AUTO"
    cp.update()


def weighted_normals(obj):
    """Bevel 之后接 Weighted Normal：大面保持平、曲面保持顺滑。
    不用 Bevel 的 harden_normals——它把相邻的每个四边形压成平面着色，
    腔壁 192 边形在金属反射里会出现一道道竖条。"""
    m = obj.modifiers.new("Weighted Normal", "WEIGHTED_NORMAL")
    m.mode = "FACE_AREA_WITH_ANGLE"
    m.keep_sharp = True
    m.weight = 50
    return m


def mark_cutter(obj):
    """Boolean Cutter：viewport 可见（线框），render 隐藏（§3）。

    Exact boolean 的结果面继承 cutter 的 smooth 标记——cutter 不平滑，
    切出来的腔壁/豁口勺面就是一片片平面（金属反射里是竖条）。"""
    shade_smooth(obj)
    obj.display_type = "WIRE"
    obj.hide_render = True
    obj.visible_camera = False
    obj.visible_shadow = False


# ---------------------------------------------------------------- Phase A


def create_control(p, colls):
    ctrl = bpy.data.objects.new("CTRL_ICON", None)
    ctrl.empty_display_type = "PLAIN_AXES"
    ctrl.empty_display_size = 0.6
    ctrl.location = (0, 0, 0)
    colls["10_CONTROL"].objects.link(ctrl)
    for k, v in p.items():
        ctrl[k] = v
    ctrl.hide_render = True
    return ctrl


def create_camera(p, colls):
    cam_data = bpy.data.cameras.new("CAMERA_ICON")
    cam_data.type = "ORTHO"  # §21 强制正交
    cam_data.ortho_scale = p["CAMERA_ORTHO_SCALE"]
    cam_data.clip_start = 0.1
    cam_data.clip_end = 200.0

    cam = bpy.data.objects.new("CAMERA_ICON", cam_data)
    colls["60_CAMERA"].objects.link(cam)

    tilt = math.radians(p["CAMERA_TILT"])
    # rotation (0,0,0) = 纯顶视；绕 X 转 tilt 后相机退到 -Y 上方，
    # 于是能看到前缘厚度与 Notch 深度（§22）。
    direction = Vector((0.0, math.sin(tilt), -math.cos(tilt)))
    target = Vector((0.0, 0.0, p["CAMERA_TARGET_Z"]))
    cam.location = target - direction * 40.0
    cam.rotation_euler = (tilt, 0.0, 0.0)

    bpy.context.scene.camera = cam
    return cam


def setup_render(p, res=1024, samples=256, alpha=False):
    scene = bpy.context.scene
    scene.render.engine = "CYCLES"  # §30 Master 必须 Cycles
    scene.render.resolution_x = res
    scene.render.resolution_y = res
    scene.render.resolution_percentage = 100
    scene.render.film_transparent = alpha

    cy = scene.cycles
    cy.samples = samples
    cy.use_adaptive_sampling = True  # §31
    cy.adaptive_threshold = 0.01
    cy.use_denoising = True
    try:
        cy.denoiser = "OPENIMAGEDENOISE"
    except Exception:
        print("  ! OIDN 不可用，沿用默认降噪器")
    cy.max_bounces = 12
    cy.transmission_bounces = 8
    cy.caustics_reflective = False
    cy.caustics_refractive = False

    vs = scene.view_settings
    try:
        scene.display_settings.display_device = "sRGB"
        vs.view_transform = "AgX"  # §32
        vs.look = "AgX - Medium Low Contrast"
    except Exception:
        try:
            vs.look = "Medium Low Contrast"
        except Exception:
            print("  ! AgX Look 未命中，使用中性 AgX")
    vs.exposure = p["EXPOSURE"]
    vs.gamma = 1.0

    scene.render.image_settings.file_format = "PNG"
    scene.render.image_settings.color_mode = "RGBA" if alpha else "RGB"
    scene.render.image_settings.color_depth = "16"


def enable_gpu():
    """Apple Silicon 上启用 Metal，失败就静默回落 CPU。"""
    try:
        prefs = bpy.context.preferences.addons["cycles"].preferences
        for backend in ("METAL", "OPTIX", "CUDA", "HIP", "ONEAPI"):
            try:
                prefs.compute_device_type = backend
            except (TypeError, ValueError):
                continue
            prefs.get_devices()
            usable = [d for d in prefs.devices if d.type == backend]
            if not usable:
                continue
            for d in prefs.devices:
                d.use = d.type in (backend, "CPU")
            bpy.context.scene.cycles.device = "GPU"
            print(f"  Cycles 设备：GPU / {backend} ({len(usable)} 个)")
            return True
    except Exception as exc:
        print(f"  ! GPU 启用失败：{exc}")
    print("  Cycles 设备：CPU")
    return False


# ---------------------------------------------------------------- Phase B


def build_frame(p, colls):
    n = p["FRAME_SUPERELLIPSE_N"]
    samples = int(p["FRAME_SAMPLES"])

    # 外壳：Z=0 顶面向下挤到 -FRAME_DEPTH（§6）
    outer = continuous_rounded_rect(
        p["FRAME_WIDTH"], p["FRAME_HEIGHT"], p["FRAME_OUTER_RADIUS"], n, samples
    )
    frame = make_prism("FRAME_BODY", outer, 0.0, -p["FRAME_DEPTH"], colls["20_FRAME"])

    # 内腔：与外轮廓同族的圆角矩形，尺寸减去 rim 宽；圆角按实测单独给（§7）。
    rim = p["RIM_WIDTH"]
    cav = continuous_rounded_rect(
        p["FRAME_WIDTH"] - 2 * rim,
        p["FRAME_HEIGHT"] - 2 * rim,
        p["CAVITY_RADIUS"],
        n,
        samples,
    )
    cutter_cav = make_prism(
        "CUTTER_CAVITY", cav, 0.30, -p["CAVITY_DEPTH"], colls["20_FRAME"]
    )
    mark_cutter(cutter_cav)

    # 豁口（§8）：沿 Y 挤出的胶囊截面（见 notch_section），贯穿前壁、伸进腔内。
    # 槽底必须高于腔底 ≥ 2×bevel + 余量：这样它只与前立面和腔前壁（都 ⟂ Y）相交，
    # 每条棱二面角恒定。走不通的路：槽底 == 腔底（半圆底与腔底相切，Exact 退化；
    # 圆角矩形底则在壁面上交出 0° 尖角）；槽底低于腔底（台阶面与腔底线交出四价
    # 顶点）；沿 Y 放样变半径（站间棱被当倒角棱）。
    front_y = -p["FRAME_HEIGHT"] / 2.0
    prof = notch_section(p["NOTCH_WIDTH"] / 2.0, p["NOTCH_DEPTH_Z"], p["NOTCH_SHOULDER"])
    prof = [(x, -z) for x, z in prof]          # 局部 XY → 绕 X −90° 后世界 Z = −局部 y
    cutter_notch = make_prism(
        "CUTTER_NOTCH", prof, front_y + rim + 0.4, front_y - 1.5, colls["20_FRAME"]
    )
    cutter_notch.rotation_euler = (math.radians(-90), 0.0, 0.0)
    mark_cutter(cutter_notch)

    # Modifier 顺序：Boolean → Bevel。一道 Bevel 放在 Boolean 之后，外缘、腔缘、
    # 豁口肩/唇、腔底全部同一半径——参考图里 rim 内外倒角带等宽。
    cutters = bpy.data.collections.new("CUTTERS")
    colls["20_FRAME"].children.link(cutters)
    for c in (cutter_cav, cutter_notch):
        link(c, cutters)
    m = frame.modifiers.new("Boolean Cutters", "BOOLEAN")
    m.operation = "DIFFERENCE"
    m.operand_type = "COLLECTION"
    m.collection = cutters
    m.solver = "EXACT"
    m.use_self = True

    b = frame.modifiers.new("Bevel", "BEVEL")
    b.width = p["FRAME_BEVEL"]
    b.segments = int(p["FRAME_BEVEL_SEGMENTS"])
    b.limit_method = "ANGLE"
    b.angle_limit = math.radians(30)
    b.miter_outer = "MITER_ARC"
    b.vmesh_method = "CUTOFF"     # 台阶两端是四价顶点（凹凸混合 4 条倒角棱），ADJ 会翻
    b.harden_normals = False
    b.use_clamp_overlap = False   # clamp 是全局的：一处会重叠就把所有棱一起缩，外缘实测只剩 0.2
    g2_profile(b, p["BEVEL_G2_N"])
    weighted_normals(frame)

    shade_smooth(frame)
    return frame


# ---------------------------------------------------------------- Phase C


def build_pages(p, colls):
    """PAGE_TOP + PAGE_STACK 共享同一 mesh（§10 §11）。

    顶页要承载压印 glyph 的 Boolean，其余页用 Array 生成；两者共用一份
    mesh data，尺寸/圆角只有一套参数。差异只来自 Y/Z 步进（§13）。
    """
    half = p["PAGE_THICKNESS"] / 2.0
    profile = continuous_rounded_rect(
        p["PAGE_WIDTH"], p["PAGE_HEIGHT"], p["PAGE_RADIUS"], 4.0, 72
    )
    top = make_prism("PAGE_TOP", profile, half, -half, colls["30_PAGES"])
    top.location = (p["PAGE_TOP_X"], p["PAGE_TOP_Y"], p["PAGE_TOP_Z"])

    stack = bpy.data.objects.new("PAGE_STACK", top.data)
    colls["30_PAGES"].objects.link(stack)
    stack.location = (
        p["PAGE_TOP_X"],
        p["PAGE_TOP_Y"] + p["PAGE_STEP_Y"],
        p["PAGE_TOP_Z"] + p["PAGE_STEP_Z"],
    )

    for obj in (top, stack):
        b = obj.modifiers.new("Bevel", "BEVEL")
        b.width = p["PAGE_BEVEL"]
        b.segments = 6
        b.limit_method = "ANGLE"
        b.angle_limit = math.radians(30)
        b.use_clamp_overlap = True
        g2_profile(b, p["BEVEL_G2_N"])

    a = stack.modifiers.new("Array", "ARRAY")
    a.count = max(1, int(p["PAGE_COUNT"]) - 1)
    a.use_relative_offset = False
    a.use_constant_offset = True
    a.constant_offset_displace = (0.0, p["PAGE_STEP_Y"], p["PAGE_STEP_Z"])
    weighted_normals(stack)

    shade_smooth(top)
    return top, stack


# ---------------------------------------------------------------- Phase D


def glyph_profiles(p):
    """3 dot + 3 line 的 2D 轮廓（页面局部坐标），§14。"""
    gap = p["LIST_VERTICAL_GAP"]
    d = p["DOT_DIAMETER"]
    lh = p["LINE_HEIGHT"]
    out = []
    for idx, row in enumerate((1, 0, -1), start=1):
        y = row * gap + p["LIST_Y"]
        dot = continuous_rounded_rect(d, d, d / 2.0, 2.0, 48)
        out.append((f"DOT_{idx:02d}", [(x + p["DOT_X"], yy + y) for x, yy in dot]))
        line = continuous_rounded_rect(p["LINE_LENGTH"], lh, lh / 2.0, 2.0, 40)
        out.append((f"LINE_{idx:02d}", [(x + p["LINE_X"], yy + y) for x, yy in line]))
    return out


def build_glyphs(p, colls, page_top):
    """压印：顶页 Boolean 切出浅槽，槽里放略低于页面的灰色嵌件（§15，
    对应爆炸图里 2A 页面上的孔 + 3 的独立 glyph 元素）。"""
    surface = p["PAGE_THICKNESS"] / 2.0          # 页面局部坐标的顶面
    recess_floor = surface - p["GLYPH_RECESS"]
    inlay_top = surface - p["GLYPH_INLAY_DROP"]
    origin = page_top.location

    # 一个 cutter 装全部 6 个岛，挂到顶页的 Boolean 上
    cutter_mesh = bpy.data.meshes.new("CUTTER_GLYPH")
    bm = bmesh.new()
    for _, prof in glyph_profiles(p):
        vt = [bm.verts.new((x, y, surface + 0.2)) for x, y in prof]
        vb = [bm.verts.new((x, y, recess_floor)) for x, y in prof]
        bm.faces.new(vt)
        bm.faces.new(list(reversed(vb)))
        n = len(prof)
        for i in range(n):
            j = (i + 1) % n
            bm.faces.new([vt[i], vb[i], vb[j], vt[j]])
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    bm.to_mesh(cutter_mesh)
    bm.free()
    cutter = bpy.data.objects.new("CUTTER_GLYPH", cutter_mesh)
    cutter.location = origin
    colls["40_GLYPH"].objects.link(cutter)
    mark_cutter(cutter)

    m = page_top.modifiers.new("Boolean Glyph", "BOOLEAN")
    m.operation = "DIFFERENCE"
    m.object = cutter
    m.solver = "EXACT"
    weighted_normals(page_top)

    made = []
    for name, prof in glyph_profiles(p):
        g = make_prism(f"GLYPH_{name}", prof, inlay_top, recess_floor - 0.01, colls["40_GLYPH"])
        g.location = origin
        shade_smooth(g)
        made.append(g)
    return made


# ---------------------------------------------------------------- Phase E


def principled(name, base_hex, metallic, roughness, coat, coat_rough):
    mat = bpy.data.materials.new(name)
    mat.use_nodes = True
    bsdf = mat.node_tree.nodes.get("Principled BSDF")
    set_input(bsdf, "Base Color", hex_rgba(base_hex))
    set_input(bsdf, "Metallic", metallic)
    set_input(bsdf, "Roughness", roughness)
    set_input(bsdf, ["Coat Weight", "Clearcoat"], coat)
    set_input(bsdf, ["Coat Roughness", "Clearcoat Roughness"], coat_rough)
    set_input(bsdf, ["Transmission Weight", "Transmission"], 0.0)  # §18
    set_input(bsdf, ["Specular IOR Level", "Specular"], 0.5)
    return mat


def build_materials(p, frame, pages, glyphs):
    mat_frame = principled(
        "MAT_FRAME",
        COLORS["FRAME"],
        p["FRAME_METALLIC"],
        p["FRAME_ROUGHNESS"],
        p["FRAME_COAT"],
        p["FRAME_COAT_ROUGHNESS"],
    )
    mat_page = principled(
        "MAT_PAGE",
        COLORS["PAGE"],
        p["PAGE_METALLIC"],
        p["PAGE_ROUGHNESS"],
        p["PAGE_COAT"],
        0.12,
    )
    mat_glyph = principled(
        "MAT_GLYPH", COLORS["GLYPH"], 0.0, p["GLYPH_ROUGHNESS"], 0.0, 0.1
    )

    if frame:
        frame.data.materials.append(mat_frame)
    if pages:
        pages[0].data.materials.append(mat_page)  # 共享 mesh，一次即可
    for g in glyphs or []:
        g.data.materials.append(mat_glyph)
    return mat_frame, mat_page, mat_glyph


# ---------------------------------------------------------------- Phase F


def area_light(name, size, power, location, rotation, coll, shape="SQUARE"):
    data = bpy.data.lights.new(name, type="AREA")
    data.shape = shape
    data.size = size
    if shape == "RECTANGLE":
        data.size_y = size * 0.6
    data.energy = power
    data.use_shadow = True
    try:
        data.spread = math.radians(150)
    except Exception:
        pass
    obj = bpy.data.objects.new(name, data)
    obj.location = location
    obj.rotation_euler = rotation
    coll.objects.link(obj)
    return obj


def build_world(p):
    """§28 World：浅中性灰，但用垂直渐变而非纯色。

    金属的"润"来自它反射到的东西（§18）。纯色 World 让金属无处可反射，
    结果就是石膏感。这里做一个程序化的柔和穹顶：天顶最亮、地平中性、
    地面略沉，给曲面提供大尺度的连续 gradient。不引入任何 HDRI 素材。
    """
    world = bpy.data.worlds.new("ICON_WORLD")
    world.use_nodes = True
    nt = world.node_tree
    nt.nodes.clear()

    out = nt.nodes.new("ShaderNodeOutputWorld")
    bg = nt.nodes.new("ShaderNodeBackground")
    ramp = nt.nodes.new("ShaderNodeValToRGB")
    sep = nt.nodes.new("ShaderNodeSeparateXYZ")
    tex = nt.nodes.new("ShaderNodeTexCoord")

    out.location = (400, 0)
    bg.location = (200, 0)
    ramp.location = (-100, 0)
    sep.location = (-300, 0)
    tex.location = (-500, 0)

    # 环境方向的 Z 分量：-1 地面 → +1 天顶，重映射到 0..1
    map_range = nt.nodes.new("ShaderNodeMapRange")
    map_range.location = (-200, -150)
    map_range.inputs["From Min"].default_value = -1.0
    map_range.inputs["From Max"].default_value = 1.0
    map_range.inputs["To Min"].default_value = 0.0
    map_range.inputs["To Max"].default_value = 1.0

    # 影棚式穹顶：地面暗、地平中灰、中高角一条亮带（大 softbox）、天顶略收。
    # 明暗交替的反射条带是不锈钢"看起来像金属"的关键；平滑渐变只会得到塑料感。
    el = ramp.color_ramp.elements
    el[0].position = 0.0
    el[0].color = hex_rgba("EDEFF1")   # 地面：图标放在白桌面上，外倒角反射的是亮地面
    el[1].position = 1.0
    el[1].color = hex_rgba("D9DDE1")
    # 地平线必须亮：外缘倒角的反射方向几乎水平，参考图里它反射的是白影棚（229）
    for pos, hx, gain in ((0.40, "D2D6DA", 1.0), (0.52, "F0F2F4", 1.0),
                          (0.66, "FFFFFF", 1.45), (0.80, "E6EAEE", 1.0)):
        e = ramp.color_ramp.elements.new(pos)
        c = hex_rgba(hx)
        e.color = (c[0] * gain, c[1] * gain, c[2] * gain, 1.0)
    ramp.color_ramp.interpolation = "B_SPLINE"
    ramp.color_ramp.elements[0].color = hex_rgba("EDEFF1")

    nt.links.new(tex.outputs["Generated"], sep.inputs["Vector"])
    nt.links.new(sep.outputs["Z"], map_range.inputs["Value"])
    nt.links.new(map_range.outputs["Result"], ramp.inputs["Fac"])

    # 方位衰减：朝相机（−Y）一侧变暗。参考图里前立面/豁口内/腔后壁都比上方暗，
    # 这是影棚里相机侧无光源的效果；只随仰角变化的穹顶做不出来。
    az = nt.nodes.new("ShaderNodeMapRange")
    az.location = (-200, -350)
    az.inputs["From Min"].default_value = -1.0
    az.inputs["From Max"].default_value = 0.0      # 只衰减 −Y 半球；±X 两侧保持全亮（外倒角反射的是两侧地平线）
    az.inputs["To Min"].default_value = p["WORLD_FRONT_DARKEN"]
    az.inputs["To Max"].default_value = 1.0
    az.clamp = True
    nt.links.new(sep.outputs["Y"], az.inputs["Value"])
    mul = nt.nodes.new("ShaderNodeMixRGB")
    mul.blend_type = "MULTIPLY"
    mul.inputs["Fac"].default_value = 1.0
    mul.location = (50, 0)
    nt.links.new(ramp.outputs["Color"], mul.inputs["Color1"])
    nt.links.new(az.outputs["Result"], mul.inputs["Color2"])
    nt.links.new(mul.outputs["Color"], bg.inputs["Color"])
    nt.links.new(bg.outputs["Background"], out.inputs["Surface"])
    bg.inputs["Strength"].default_value = p["WORLD_STRENGTH"]

    bpy.context.scene.world = world
    return world


def build_lighting(p, colls, alpha=False):
    def aim(pos):
        """灯从 pos 指向原点略下方：返回欧拉角。"""
        d = Vector((0.0, 0.0, -0.6)) - Vector(pos)
        return d.to_track_quat("-Z", "Y").to_euler()

    key = area_light("LIGHT_KEY", p["KEY_SIZE"], p["KEY_POWER"],
                     tuple(p["KEY_POS"]), aim(p["KEY_POS"]), colls["50_LIGHTING"])
    fill = area_light("LIGHT_FILL", p["FILL_SIZE"], p["FILL_POWER"],
                      tuple(p["FILL_POS"]), aim(p["FILL_POS"]), colls["50_LIGHTING"])
    rim = area_light("LIGHT_RIM", p["RIM_SIZE"], p["RIM_POWER"],
                     tuple(p["RIM_POS"]), aim(p["RIM_POS"]), colls["50_LIGHTING"])

    build_world(p)

    # §29 Shadow Plane：接触阴影，透明底渲染时不参与
    plane_mesh = bpy.data.meshes.new("SHADOW_PLANE")
    s = 40.0
    plane_mesh.from_pydata(
        [(-s, -s, 0), (s, -s, 0), (s, s, 0), (-s, s, 0)], [], [[0, 1, 2, 3]]
    )
    plane_mesh.update()
    plane = bpy.data.objects.new("SHADOW_PLANE", plane_mesh)
    plane.location = (0, 0, -p["FRAME_DEPTH"] - 0.001)
    colls["50_LIGHTING"].objects.link(plane)
    mat = principled("MAT_SHADOW_PLANE", COLORS["SHADOW_PLANE"], 0.0, 0.6, 0.0, 0.1)
    plane.data.materials.append(mat)
    # 只承接阴影与预览背景，不进反射：这样倒角在灰底预览与 RGBA master 里
    # 反射的都是 World 地面，两种输出一致。
    plane.visible_glossy = False
    plane.visible_diffuse = False
    if alpha:
        plane.hide_render = True

    return key, fill, rim, plane


# ---------------------------------------------------------------- Reference


def load_reference(colls):
    path = os.path.join(HERE, "reference.png")
    if not os.path.exists(path):
        return None
    img = bpy.data.images.load(path)
    empty = bpy.data.objects.new("REF_CURRENT_ICON", None)
    empty.empty_display_type = "IMAGE"
    empty.data = img
    empty.empty_display_size = 13.6
    empty.location = (0, 0, -6.0)
    empty.color = (1, 1, 1, 0.4)  # §35 对照用，40% 不透明
    empty.hide_render = True      # §35 绝不进最终渲染
    colls["00_REFERENCE"].objects.link(empty)
    return empty


# ---------------------------------------------------------------- 主流程


def build(p, phase="G", res=1024, samples=256, alpha=False):
    order = "ABCDEFG"
    upto = order.index(phase)

    print(f"\n=== 构建到 Phase {phase} ===")
    clear_scene()
    colls = setup_collections()

    print("Phase A — Scene Skeleton")
    create_control(p, colls)
    create_camera(p, colls)
    setup_render(p, res=res, samples=samples, alpha=alpha)
    load_reference(colls)

    frame = None
    pages = None
    glyphs = []

    if upto >= 1:
        print("Phase B — Frame")
        frame = build_frame(p, colls)
    if upto >= 2:
        print("Phase C — Page Stack")
        pages = build_pages(p, colls)
    if upto >= 3:
        print("Phase D — Glyph")
        glyphs = build_glyphs(p, colls, pages[0])

    # 材质与灯光不属于几何阶段：Phase B 也需要它们才看得清 Silhouette /
    # Rim / Notch / Depth（§37 Phase B 的验收项）。
    print("Phase E — Material")
    build_materials(p, frame, pages, glyphs)
    print("Phase F — Lighting")
    build_lighting(p, colls, alpha=alpha)

    return colls


def print_stats():
    """输出每个可渲染对象求值后的面数与世界包围盒，用来抓 Boolean 事故。"""
    deps = bpy.context.evaluated_depsgraph_get()
    print("\n--- 几何统计（modifier 求值后）---")
    for obj in sorted(bpy.data.objects, key=lambda o: o.name):
        if obj.type != "MESH":
            continue
        ev = obj.evaluated_get(deps)
        try:
            me = ev.to_mesh()
        except Exception as exc:
            print(f"  {obj.name:16s} 求值失败：{exc}")
            continue
        nf, nv = len(me.polygons), len(me.vertices)
        if nv:
            pts = [obj.matrix_world @ v.co for v in me.vertices]
            lo = [min(pt[i] for pt in pts) for i in range(3)]
            hi = [max(pt[i] for pt in pts) for i in range(3)]
            box = " ".join(f"{a:+.2f}..{b:+.2f}" for a, b in zip(lo, hi))
        else:
            box = "(空)"
        flag = "  <<< 空几何" if nf == 0 else ""
        print(f"  {obj.name:16s} f={nf:6d} v={nv:6d}  {box}{flag}")
        ev.to_mesh_clear()


def parse_args():
    argv = sys.argv[sys.argv.index("--") + 1 :] if "--" in sys.argv else []
    ap = argparse.ArgumentParser()
    ap.add_argument("--phase", default="G", choices=list("ABCDEFG"))
    ap.add_argument("--render", action="store_true")
    ap.add_argument("--samples", type=int, default=256)
    ap.add_argument("--res", type=int, default=1024)
    ap.add_argument("--out", default=None)
    ap.add_argument("--alpha", action="store_true")
    ap.add_argument("--save", default=None)
    ap.add_argument("--set", action="append", default=[], metavar="KEY=VALUE")
    ap.add_argument("--stats", action="store_true")
    return ap.parse_args(argv)


def main():
    args = parse_args()
    p = dict(PARAMS)
    for override in args.set:
        k, _, v = override.partition("=")
        k = k.strip()
        if k not in p:
            print(f"! 未知参数 {k}，忽略")
            continue
        p[k] = float(v)
        print(f"  覆盖 {k} = {p[k]}")

    build(p, phase=args.phase, res=args.res, samples=args.samples, alpha=args.alpha)

    if args.stats:
        print_stats()

    if args.save:
        path = args.save if os.path.isabs(args.save) else os.path.join(HERE, args.save)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        bpy.ops.wm.save_as_mainfile(filepath=path)
        print(f"  已保存 {path}")

    if args.render:
        name = args.out or f"phase_{args.phase}"
        out = os.path.join(HERE, "renders", f"{name}.png")
        os.makedirs(os.path.dirname(out), exist_ok=True)
        enable_gpu()
        bpy.context.scene.render.filepath = out
        print(f"  渲染 → {out} ({args.res}px, {args.samples} spp)")
        bpy.ops.render.render(write_still=True)
        print(f"  完成 {out}")


if __name__ == "__main__":
    main()
