#!/usr/bin/env python3
"""沁音 Qinyin logo: 黄绿渐变底 + 白色八分音符(气泡符头) + 上升气泡。PIL 超采样绘制。"""
from PIL import Image, ImageDraw, ImageFilter
import math, os

SS = 4096  # 超采样画布

def gradient(size, top=(184, 230, 46), bottom=(61, 190, 100)):
    """竖向渐变, 带轻微幂曲线让过渡更顺。"""
    img = Image.new('RGB', (size, size))
    px = img.load()
    col = []
    for y in range(size):
        t = y / (size - 1)
        t = t ** 1.08
        col.append(tuple(round(top[i] + (bottom[i] - top[i]) * t) for i in range(3)))
    for y in range(size):
        for x in range(0, size, 64):
            pass
    # 用逐行 paste 更快
    img = Image.new('RGB', (1, size))
    img.putdata(col)
    img = img.resize((size, size))
    # 顶部左上轻微高光, 增加汽水通透感
    glow = Image.new('L', (size, size), 0)
    gd = ImageDraw.Draw(glow)
    gd.ellipse([-size * 0.35, -size * 0.45, size * 0.75, size * 0.55], fill=70)
    glow = glow.filter(ImageFilter.GaussianBlur(size * 0.12))
    white = Image.new('RGB', (size, size), (255, 255, 255))
    img = Image.composite(white, img, glow.point(lambda v: v // 3))
    return img

def rot_ellipse(layer, cx, cy, rx, ry, angle_deg, fill):
    """在独立层画椭圆并旋转后贴回。"""
    pad = int(max(rx, ry) * 2 + 8)
    tmp = Image.new('RGBA', (pad * 2, pad * 2), (0, 0, 0, 0))
    d = ImageDraw.Draw(tmp)
    d.ellipse([pad - rx, pad - ry, pad + rx, pad + ry], fill=fill)
    tmp = tmp.rotate(angle_deg, resample=Image.BICUBIC, center=(pad, pad))
    layer.alpha_composite(tmp, (int(cx - pad), int(cy - pad)))

def draw_glyph(size):
    """白色音符+气泡字形层 (RGBA, 透明底)。坐标以画布分数定义。"""
    img = Image.new('RGBA', (size, size), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    W = (255, 255, 255, 255)
    u = size

    def P(x, y):
        return (x * u, y * u)

    # ---- 气泡 (白色描边圆环 + 小实心点), 在音符后层先画 ----
    rings = [
        (0.238, 0.292, 0.046),   # 左上大泡
        (0.168, 0.415, 0.027),   # 左中小泡
        (0.806, 0.352, 0.035),   # 右上泡
        (0.840, 0.468, 0.021),   # 右小泡
    ]
    lw = max(4, int(0.0135 * u))
    for cx, cy, r in rings:
        d.ellipse([P(cx - r, cy - r), P(cx + r, cy + r)], outline=W, width=lw)
        if r >= 0.030:
            # 气泡高光小点 (小泡省略, 免成甜甜圈)
            hx, hy, hr = cx - r * 0.34, cy - r * 0.38, r * 0.20
            d.ellipse([P(hx - hr, hy - hr), P(hx + hr, hy + hr)], fill=W)
    for cx, cy, r in [(0.300, 0.185, 0.0135), (0.720, 0.130, 0.011), (0.145, 0.560, 0.010)]:
        d.ellipse([P(cx - r, cy - r), P(cx + r, cy + r)], fill=W)

    # ---- 八分音符 (双符头连梁), 绕锚点整体放大 1.09 ----
    def S(pt, anchor=(0.510, 0.470), k=1.09):
        return (anchor[0] + (pt[0] - anchor[0]) * k, anchor[1] + (pt[1] - anchor[1]) * k)
    headL = S((0.358, 0.700))
    headR = S((0.662, 0.652))
    rx, ry, ang = 0.0895 * 1.09, 0.0685 * 1.09, -20
    stem_w = 0.037 * 1.09
    stemL_x = headL[0] + rx * 0.90 - stem_w        # 左符干左缘
    stemR_x = headR[0] + rx * 0.90 - stem_w
    beam_top_l = (stemL_x, S((0, 0.238))[1])
    beam_top_r = (stemR_x + stem_w, S((0, 0.190))[1])
    beam_th = 0.078 * 1.09

    # 梁 (斜四边形)
    beam = [P(*beam_top_l), P(*beam_top_r),
            P(beam_top_r[0], beam_top_r[1] + beam_th),
            P(beam_top_l[0], beam_top_l[1] + beam_th)]
    d.polygon(beam, fill=W)
    # 符干
    d.rectangle([P(stemL_x, beam_top_l[1] + beam_th * 0.4), P(stemL_x + stem_w, headL[1])], fill=W)
    d.rectangle([P(stemR_x, beam_top_r[1] + beam_th * 0.4), P(stemR_x + stem_w, headR[1])], fill=W)
    # 符头 (圆润气泡形椭圆)
    rot_ellipse(img, headL[0] * u, headL[1] * u, rx * u, ry * u, ang, W)
    rot_ellipse(img, headR[0] * u, headR[1] * u, rx * u, ry * u, ang, W)
    return img

def downscale(img, out):
    """逐级降采样抗锯齿。"""
    while img.size[0] > out * 2:
        img = img.resize((img.size[0] // 2, img.size[1] // 2), Image.LANCZOS)
    return img.resize((out, out), Image.LANCZOS)

def main():
    outdir = os.path.expanduser('~/workspace/qinyin/assets/icon')
    os.makedirs(outdir, exist_ok=True)
    bg_big = gradient(SS)
    glyph_big = draw_glyph(SS)

    comp = bg_big.convert('RGBA')
    comp.alpha_composite(glyph_big)

    # 1024 产物
    bg = downscale(bg_big.convert('RGBA'), 1024)
    fg = downscale(glyph_big, 1024)
    comp1024 = downscale(comp, 1024)
    comp1024.convert('RGB').save(f'{outdir}/app_icon.png')            # 与旧占位一致: RGB
    comp1024.convert('RGB').save(f'{outdir}/icon_background_check.png') if False else None
    bg.convert('RGB').save(f'{outdir}/icon_background.png')
    fg.save(f'{outdir}/icon_foreground.png')
    fg.save(f'{outdir}/icon_monochrome.png')                          # 白色字形即单色层
    downscale(comp, 2048).convert('RGB').save(f'{outdir}/source.png')  # 母版
    comp1024.convert('RGB').save(os.path.expanduser('~/workspace/qinyin/assets/icon.png'))

    # ---- 预览图: 圆角 / 圆形遮罩 / 前景层 / 单色层 四格 ----
    pv = Image.new('RGB', (1600, 460), (245, 245, 247))
    pd = ImageDraw.Draw(pv)
    cell = comp1024.resize((400, 400), Image.LANCZOS)
    # 圆角版
    mask = Image.new('L', (400, 400), 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, 400, 400], radius=88, fill=255)
    pv.paste(cell, (30, 30), mask)
    # 圆形版
    mask2 = Image.new('L', (400, 400), 0)
    ImageDraw.Draw(mask2).ellipse([0, 0, 400, 400], fill=255)
    pv.paste(cell, (430, 30), mask2)
    # 前景层 (放深绿底看白字形)
    fgc = Image.new('RGB', (400, 400), (38, 120, 66))
    fgc.paste(fg.resize((400, 400), Image.LANCZOS), (0, 0), fg.resize((400, 400), Image.LANCZOS))
    pv.paste(fgc, (830, 30))
    # 单色层 (黑底)
    moc = Image.new('RGB', (400, 400), (20, 20, 20))
    mo = fg.resize((400, 400), Image.LANCZOS)
    moc.paste(mo, (0, 0), mo)
    pv.paste(moc, (1230, 30))
    pv.save(f'{outdir}/preview.png')

    # ---- Android 自适应三层 (mipmap 五档, 与 ic_launcher.xml 的 @mipmap 引用对齐) ----
    # 注意: 不要用 flutter_launcher_icons 的 adaptive 配置重跑, 0.14.4 会改成
    # drawable + inset 结构, 与本仓 mipmap 结构不一致; 工具只负责其余平台。
    res = os.path.expanduser('~/workspace/qinyin/android/app/src/main/res')
    for d, s in [('mdpi', 108), ('hdpi', 162), ('xhdpi', 216), ('xxhdpi', 324), ('xxxhdpi', 432)]:
        downscale(bg_big.convert('RGB'), s).save(f'{res}/mipmap-{d}/ic_launcher_background.png')
        downscale(glyph_big, s).save(f'{res}/mipmap-{d}/ic_launcher_foreground.png')
        downscale(glyph_big, s).save(f'{res}/mipmap-{d}/ic_launcher_monochrome.png')
    print('done')

if __name__ == '__main__':
    main()
