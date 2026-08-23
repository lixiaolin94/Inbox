"""像素级测量：对参考图与渲染图跑同一套边缘检测，按 BU 输出可比数字。

    python3 measure.py reference/reference.png renders/align_1250.png

框宽由水平中线上最外侧的强跳变确定，所有数字以它归一到 10 BU。
"""

import sys

import numpy as np
from PIL import Image


def load(path):
    return np.asarray(Image.open(path).convert("L")).astype(int)


def jumps(line, thr):
    d = np.diff(line)
    return [(i, int(d[i])) for i in range(len(d)) if abs(d[i]) >= thr]


def cluster(js, gap=3):
    """把相邻的跳变合并成一个边缘（取首位置）。"""
    out = []
    for i, d in js:
        if out and i - out[-1][0] <= gap:
            out[-1] = (out[-1][0], out[-1][1] + d)
        else:
            out.append((i, d))
    return out


def analyze(path, thr=14):
    im = load(path)
    H, W = im.shape
    cx = W // 2
    # 1) 框宽：在图像 45% 高度的行上，从两端向内找第一个强跳变
    y0 = int(H * 0.45)
    row = im[y0]
    js = cluster(jumps(row, 22))
    left = min(i for i, _ in js)
    right = max(i for i, _ in js)
    width = right - left
    px = width / 10.0
    cx = (left + right) / 2.0
    print(f"== {path}")
    print(f"   框宽 {width}px (x {left}..{right}), 中心 {cx:.0f}, 1 BU = {px:.1f}px")

    # 2) 顶缘与外圆角：沿列 cx 向下找第一个跳变 = 顶缘；再沿顶缘下方 2px 的行找平直段
    col = im[:, int(cx)]
    top = min(i for i, _ in cluster(jumps(col, 22)))
    mask = np.abs(im - im[5:30, 5:30].mean()) > 26
    trow = top + 3
    tl = np.argmax(mask[trow])
    print(f"   顶缘 y={top}; 外圆角(顶边平直段起点) ≈ {(tl - left) / px:.2f} BU")

    # 3) 水平中线上的结构（以 BU 计，相对中心），只列左半 + 右半
    print("   水平中线跳变 (BU, Δ亮度)：")
    for i, d in cluster(jumps(row, thr)):
        print(f"      {(i - cx) / px:+.2f}  {d:+d}")

    # 4) 垂直中线（从顶缘起，屏幕 BU）
    print("   垂直中线跳变 (从顶缘起的 BU, Δ)：")
    for i, d in cluster(jumps(col, thr)):
        if i >= top:
            print(f"      {(i - top) / px:.2f}  {d:+d}")
    return dict(width=width, px=px, cx=cx, top=top)


if __name__ == "__main__":
    for p in sys.argv[1:]:
        analyze(p)
