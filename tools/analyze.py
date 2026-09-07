# 分析小火人参考图：主色调 + 前景轮廓的颜色栅格（供无法直接看图时"阅读"图片）
from PIL import Image
import os, colorsys

SRC = r'D:\桌面\小火人\converted'

def classify(r, g, b):
    h, l, s = colorsys.rgb_to_hls(r / 255, g / 255, b / 255)
    h *= 360
    if l > 0.88 and s < 0.25: return '.'      # 近白（背景/眼白）
    if l < 0.18: return '#'                    # 近黑（眼睛/描边）
    if l > 0.62 and s < 0.30: return 'g'       # 浅灰
    if s < 0.25: return 'g'                    # 灰
    if 15 <= h < 45: return 'O' if l > 0.35 else 'B'   # 橙 / 深棕
    if h < 15 or h >= 345: return 'R'          # 红
    if 45 <= h < 70: return 'Y'                # 黄
    if 320 <= h < 345: return 'P'              # 粉
    if 70 <= h < 170: return 'G'               # 绿
    return '?'

for f in sorted(os.listdir(SRC)):
    if not f.endswith('.png'): continue
    im = Image.open(os.path.join(SRC, f)).convert('RGB')
    W, H = im.size
    corners = [im.getpixel((2, 2)), im.getpixel((W - 3, 2)),
               im.getpixel((2, H - 3)), im.getpixel((W - 3, H - 3))]
    bg = tuple(sum(c[i] for c in corners) // 4 for i in range(3))
    print('=' * 64)
    print(f, im.size, 'bg', bg)

    # 主色调（8 色量化）
    small = im.quantize(8).convert('RGB')
    cols = sorted(small.getcolors(maxcolors=256), reverse=True)[:8]
    print('palette:', [(c, rgb) for c, rgb in cols])

    # 前景（非背景）包围盒
    px = im.load()
    mask = Image.new('L', (W, H))
    mp = mask.load()
    for y in range(H):
        for x in range(W):
            p = px[x, y]
            d = abs(p[0]-bg[0]) + abs(p[1]-bg[1]) + abs(p[2]-bg[2])
            mp[x, y] = 255 if d > 60 else 0
    bb = mask.getbbox()
    print('bbox', bb)
    if bb:
        crop = im.crop(bb)
        gw, gh = 40, 26
        for y in range(gh):
            row = ''
            for x in range(gw):
                row += classify(*crop.resize((gw, gh)).getpixel((x, y)))
            print(row)
