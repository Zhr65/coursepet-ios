# 小火人风格宠物帧生成器 v0.1 — 2.5D 立体卡通火焰团子
# 用法: python pet_gen.py  输出到 out/pet_v1_{blue,orange,green}.png
from PIL import Image, ImageDraw, ImageOps, ImageFilter
import os

SIZE = 256
OUT = os.path.join(os.path.dirname(__file__), 'out')
os.makedirs(OUT, exist_ok=True)


def bez(p0, p1, p2, n=24):
    """二次贝塞尔采样（含两端点）"""
    pts = []
    for i in range(n + 1):
        t = i / n
        x = (1 - t) ** 2 * p0[0] + 2 * (1 - t) * t * p1[0] + t ** 2 * p2[0]
        y = (1 - t) ** 2 * p0[1] + 2 * (1 - t) * t * p1[1] + t ** 2 * p2[1]
        pts.append((x, y))
    return pts


def body_outline(cx, cy):
    """火焰团子轮廓：顶部 S 形火苗尖 + 底部半圆。返回闭合点列"""
    import math
    tip = (cx + 6, cy - 84)
    right_shoulder = (cx + 62, cy - 12)
    left_shoulder = (cx - 62, cy - 12)
    # 右侧：尖 → 右肩（外扩再收拢）
    right = bez(tip, (cx + 56, cy - 58), right_shoulder)
    # 底部弧：右肩 → 底 → 左肩（椭圆下半）
    arc = []
    for a in range(0, 181, 6):
        rad = math.radians(a)
        arc.append((cx + 62 * math.cos(rad), cy - 12 + 60 * math.sin(rad)))
    # 左侧：左肩 → 尖
    left = bez(left_shoulder, (cx - 52, cy - 62), tip)
    return right[:-1] + arc + left[:-1]


def shifted_gradient(cx_light, cy_light, dark, light):
    """以 (cx_light, cy_light) 为高亮中心的径向渐变（256×256 RGB）"""
    big = Image.radial_gradient('L').resize((SIZE * 2, SIZE * 2))
    x0, y0 = 128 - cx_light, 128 - cy_light
    g = big.crop((x0, y0, x0 + SIZE, y0 + SIZE))
    return ImageOps.colorize(g, black=dark, white=light)


def draw_pet(cfg):
    """cfg: dark, light, stroke, eyes('big'|'dot'|'sunglasses'), mouth('smile'|'open'),
    blush(bool), belly(color|None), cap(color|None), feet(color), cx, cy, name"""
    cx, cy = cfg['cx'], cfg['cy']
    pts = body_outline(cx, cy)
    mask = Image.new('L', (SIZE, SIZE), 0)
    ImageDraw.Draw(mask).polygon(pts, fill=255)
    mask = mask.filter(ImageFilter.GaussianBlur(1))

    # 1) 身体渐变（高光中心偏左下 → 边缘深色）
    rgb = shifted_gradient(cx - 24, cy + 8, cfg['dark'], cfg['light'])
    d = ImageDraw.Draw(rgb)

    # 2) 内部暖光 + 脸 + 帽子/肚皮（画在 rgb 上，稍后统一按身体轮廓裁剪）
    glow = Image.new('RGBA', (SIZE, SIZE), (0, 0, 0, 0))
    ImageDraw.Draw(glow).ellipse([cx - 22, cy + 26, cx + 22, cy + 60],
                                 fill=(255, 240, 180, 70))
    glow = glow.filter(ImageFilter.GaussianBlur(10))
    rgb = Image.alpha_composite(rgb.convert('RGBA'), glow).convert('RGB')
    d = ImageDraw.Draw(rgb)

    if cfg.get('cap'):
        d.ellipse([cx - 36, cy - 44, cx + 36, cy - 6], fill=cfg['cap'])
    if cfg.get('belly'):
        d.ellipse([cx - 30, cy + 18, cx + 30, cy + 56], fill=cfg['belly'])

    # 眼睛
    eye_dy = 10
    if cfg['eyes'] == 'big':
        for sx in (-1, 1):
            ex = cx + sx * 21
            d.ellipse([ex - 10, cy + eye_dy - 12, ex + 10, cy + eye_dy + 12],
                      fill=(52, 44, 40))
            d.ellipse([ex + sx * 2 - 2, cy + eye_dy - 7, ex + sx * 2 + 3, cy + eye_dy - 2],
                      fill=(255, 255, 255))
    elif cfg['eyes'] == 'dot':
        for sx in (-1, 1):
            ex = cx + sx * 20
            d.ellipse([ex - 6, cy + eye_dy - 6, ex + 6, cy + eye_dy + 6], fill=(52, 44, 40))
            d.ellipse([ex - 2, cy + eye_dy - 4, ex + 1, cy + eye_dy - 1], fill=(255, 255, 255))
    else:  # sunglasses
        d.rounded_rectangle([cx - 36, cy + eye_dy - 9, cx + 36, cy + eye_dy + 11],
                            radius=9, fill=(45, 42, 48))
        d.rounded_rectangle([cx - 13, cy + eye_dy - 4, cx + 13, cy + eye_dy + 3],
                            radius=3, fill=(52, 48, 56))

    # 嘴巴
    if cfg['mouth'] == 'smile':
        d.arc([cx - 11, cy + 22, cx + 11, cy + 40], 20, 160,
              fill=(70, 50, 40), width=3)
    else:  # open
        d.ellipse([cx - 9, cy + 26, cx + 9, cy + 38], fill=(70, 40, 35))
        d.ellipse([cx - 6, cy + 31, cx + 6, cy + 38], fill=(240, 140, 140))

    # 腮红
    if cfg.get('blush'):
        blush = Image.new('RGBA', (SIZE, SIZE), (0, 0, 0, 0))
        bd = ImageDraw.Draw(blush)
        for sx in (-1, 1):
            bd.ellipse([cx + sx * 36 - 9, cy + 20, cx + sx * 36 + 9, cy + 30],
                       fill=(255, 150, 165, 150))
        blush = blush.filter(ImageFilter.GaussianBlur(3))
        rgb = Image.alpha_composite(rgb.convert('RGBA'), blush).convert('RGB')

    # 3) 按身体轮廓裁剪 → 透明背景
    body = Image.new('RGBA', (SIZE, SIZE), (0, 0, 0, 0))
    body.paste(rgb, (0, 0), mask)

    # 4) 描边（深色卡通边）
    d = ImageDraw.Draw(body)
    d.line(pts + [pts[0]], fill=cfg['stroke'] + (255,), width=4, joint='curve')

    # 5) 高光（光照侧白色柔光）
    spec = Image.new('RGBA', (SIZE, SIZE), (0, 0, 0, 0))
    ImageDraw.Draw(spec).ellipse([cx - 40, cy - 32, cx - 12, cy + 12],
                                 fill=(255, 255, 255, 120))
    spec = spec.filter(ImageFilter.GaussianBlur(8))
    body = Image.alpha_composite(body, spec)

    # 6) 脚（身体底部外露）
    for sx in (-1, 1):
        d.ellipse([cx + sx * 22 - 12, cy + 44, cx + sx * 22 + 12, cy + 58],
                  fill=cfg['feet'] + (255,))
        d.line([cx + sx * 22 - 12, cy + 52, cx + sx * 22 + 12, cy + 52],
               fill=cfg['stroke'] + (255,), width=3)

    # 7) 地面投影
    final = Image.new('RGBA', (SIZE, SIZE), (0, 0, 0, 0))
    shadow = Image.new('RGBA', (SIZE, SIZE), (0, 0, 0, 0))
    ImageDraw.Draw(shadow).ellipse([cx - 46, cy + 56, cx + 46, cy + 72],
                                   fill=(80, 60, 50, 90))
    shadow = shadow.filter(ImageFilter.GaussianBlur(8))
    final = Image.alpha_composite(final, shadow)
    final = Image.alpha_composite(final, body)

    final.save(os.path.join(OUT, cfg['name'] + '.png'))
    print('saved', cfg['name'])


VARIANTS = [
    dict(name='pet_v1_blue', cx=128, cy=118,
         dark=(96, 138, 168), light=(172, 210, 232), stroke=(74, 106, 132),
         eyes='dot', mouth='smile', blush=True, belly=None, cap=None,
         feet=(88, 124, 152)),
    dict(name='pet_v1_orange', cx=128, cy=118,
         dark=(232, 118, 52), light=(255, 176, 96), stroke=(198, 92, 38),
         eyes='big', mouth='open', blush=True, belly=(255, 232, 206),
         cap=None, feet=(214, 100, 42)),
    dict(name='pet_v1_green', cx=128, cy=118,
         dark=(92, 168, 92), light=(160, 224, 148), stroke=(66, 132, 78),
         eyes='sunglasses', mouth='smile', blush=False, belly=None,
         cap=(255, 252, 244), feet=(250, 202, 60)),
]

for v in VARIANTS:
    draw_pet(v)
print('all done')
