# 宠物素材加工管线：抠背景 → 保留主体 → 标准化 → 自动生成动画帧
# 用法：把图放进 pet_source/charN/ 后运行 python process_pet.py
import os, math
from collections import deque
from PIL import Image, ImageFilter, ImageEnhance, ImageChops, ImageOps
import numpy as np

SOURCE = r'D:\AI\CoursePet\pet_source'
ASSETS = r'D:\AI\CoursePet\pet_assets'
SIZE = 256          # 输出帧尺寸
TOL = 30            # 背景色容差（曼哈顿距离）——太大会吃掉角色浅色部分

ACTIONS = ('idle', 'happy', 'walk', 'excite', 'sleep', 'listen', 'nervous', 'weak', 'rain', 'charge')
FRAMES = 8


def remove_bg(im):
    """洪水填充去背景 + 保留最大连通块，返回带 alpha 的裁剪图"""
    rgb = im.convert('RGB')
    w, h = rgb.size
    # 背景色 = 四角像素的均值
    corners = [rgb.getpixel((2, 2)), rgb.getpixel((w - 3, 2)),
               rgb.getpixel((2, h - 3)), rgb.getpixel((w - 3, h - 3))]
    bg = tuple(sum(c[i] for c in corners) // 4 for i in range(3))

    arr = np.asarray(rgb, dtype=np.int16)
    dist = np.abs(arr[:, :, 0] - bg[0]) + np.abs(arr[:, :, 1] - bg[1]) + np.abs(arr[:, :, 2] - bg[2])
    is_bg = dist < TOL

    # 从边缘洪水填充（numpy 数组上的 BFS）
    from collections import deque
    visited = np.zeros((h, w), dtype=bool)
    q = deque()
    for x in range(w):
        for y in (0, h - 1):
            if is_bg[y, x] and not visited[y, x]:
                visited[y, x] = True
                q.append((y, x))
    for y in range(h):
        for x in (0, w - 1):
            if is_bg[y, x] and not visited[y, x]:
                visited[y, x] = True
                q.append((y, x))
    while q:
        y, x = q.popleft()
        for dy, dx in ((1, 0), (-1, 0), (0, 1), (0, -1)):
            ny, nx = y + dy, x + dx
            if 0 <= ny < h and 0 <= nx < w and not visited[ny, nx] and is_bg[ny, nx]:
                visited[ny, nx] = True
                q.append((ny, nx))

    alpha = np.where(visited, 0, 255).astype(np.uint8)
    alpha_im = Image.fromarray(alpha, 'L')
    # 闭运算：先膨胀再腐蚀，补回被冲掉的小洞/浅色区域
    alpha_im = alpha_im.filter(ImageFilter.MaxFilter(7))
    alpha_im = alpha_im.filter(ImageFilter.MinFilter(5))

    # 下采样找最大连通块 bbox（滤掉边缘装饰等杂物）
    ds = 4
    small = alpha_im.resize((w // ds, h // ds))
    g = np.asarray(small) > 128
    best_bb, best_n = None, 0
    seen = np.zeros_like(g)
    for sy in range(g.shape[0]):
        for sx in range(g.shape[1]):
            if g[sy, sx] and not seen[sy, sx]:
                seen[sy, sx] = True
                qq = deque([(sy, sx)])
                n, miny, maxy, minx, maxx = 1, sy, sy, sx, sx
                while qq:
                    cy, cx = qq.popleft()
                    for dy, dx in ((1, 0), (-1, 0), (0, 1), (0, -1)):
                        ny, nx = cy + dy, cx + dx
                        if 0 <= ny < g.shape[0] and 0 <= nx < g.shape[1] \
                                and g[ny, nx] and not seen[ny, nx]:
                            seen[ny, nx] = True
                            qq.append((ny, nx))
                            n += 1
                            miny, maxy = min(miny, ny), max(maxy, ny)
                            minx, maxx = min(minx, nx), max(maxx, nx)
                if n > best_n:
                    best_n, best_bb = n, (minx, maxx, miny, maxy)

    # 按 bbox 裁剪（带余量），滤掉主体外的杂物
    if best_bb:
        minx, maxx, miny, maxy = best_bb
        m = 3
        box = (max(0, minx * ds - m), max(0, miny * ds - m),
               min(w, (maxx + 1) * ds + m), min(h, (maxy + 1) * ds + m))
        alpha_im = alpha_im.crop(box)
        rgb = rgb.crop(box)
    else:
        alpha_im = Image.new('L', (w, h), 0)

    # 去白边 + 羽化
    alpha_im = alpha_im.filter(ImageFilter.MinFilter(3))
    alpha_im = alpha_im.filter(ImageFilter.GaussianBlur(0.8))

    out = rgb.convert('RGBA')
    out.putalpha(alpha_im)
    return out


def fit_canvas(im):
    """等比缩放进 256×256 画布（不超 224），底部对齐居中"""
    w, h = im.size
    s = 224 / max(w, h)
    nw, nh = max(1, int(w * s)), max(1, int(h * s))
    im = im.resize((nw, nh), Image.LANCZOS)
    canvas = Image.new('RGBA', (SIZE, SIZE), (0, 0, 0, 0))
    canvas.paste(im, ((SIZE - nw) // 2, SIZE - nh - 8), im)
    return canvas


def transform(base, sx=1.0, sy=1.0, dx=0, dy=0, angle=0.0):
    """底部锚定的缩放/位移/旋转，用于从静态图造动画帧"""
    w, h = base.size
    nw, nh = max(1, int(w * sx)), max(1, int(h * sy))
    im = base.resize((nw, nh), Image.LANCZOS)
    if angle:
        im = im.rotate(angle, resample=Image.BICUBIC, expand=True)
    canvas = Image.new('RGBA', base.size, (0, 0, 0, 0))
    canvas.paste(im, (int((base.size[0] - im.size[0]) // 2 + dx),
                      int(base.size[1] - im.size[1] + dy)), im)
    return canvas


def tint(base, brightness=1.0, rgb_scale=(1.0, 1.0, 1.0)):
    """亮度/色调调整（alpha 不变）"""
    a = base.split()[3]
    rgb = ImageEnhance.Brightness(base.convert('RGB')).enhance(brightness)
    solid = Image.new('RGB', base.size, tuple(int(255 * s) for s in rgb_scale))
    rgb = ImageChops.multiply(rgb, solid)
    out = rgb.convert('RGBA')
    out.putalpha(a)
    return out


def glow(base, strength=0.45):
    """暖色光晕（充电感），只作用在角色区域内"""
    a = base.split()[3]
    warm = ImageOps.colorize(Image.radial_gradient('L').resize(base.size),
                             black=(255, 205, 110), white=(255, 244, 214))
    warm = warm.convert('RGBA')
    warm.putalpha(a.point(lambda v: int(v * strength)))
    return Image.alpha_composite(base, warm)


def make_frames(base):
    n = FRAMES
    frames = {}
    # 待机：呼吸
    frames['idle'] = [transform(base, sx=1 - 0.03 * math.sin(2 * math.pi * i / n),
                                sy=1 + 0.06 * math.sin(2 * math.pi * i / n))
                      for i in range(n)]
    # 开心：大蹦跳（高跳 + 落地明显压扁）
    seq = []
    for i in range(n):
        t = i / n
        dy = -26 * math.sin(math.pi * t)
        if i == n // 2:
            sx, sy = 1.14, 0.80
        elif i in (n // 2 - 1, n // 2 + 1):
            sx, sy = 1.06, 0.92
        else:
            sx, sy = 1.0, 1.0
        seq.append(transform(base, sx, sy, dy))
    frames['happy'] = seq
    # 走路：左右摇摆 + 位移 + 起伏
    frames['walk'] = [transform(base,
                                dx=10 * math.sin(2 * math.pi * i / n),
                                dy=-4 * abs(math.sin(2 * math.pi * i / n)),
                                angle=-12 * math.sin(2 * math.pi * i / n))
                      for i in range(n)]
    # 兴奋：双倍速蹦跳 + 扭动
    frames['excite'] = [transform(base,
                                  dy=-20 * math.sin(4 * math.pi * i / n),
                                  angle=9 * math.sin(4 * math.pi * i / n))
                        for i in range(n)]
    # 睡觉：缩小压扁 + 变暗 + 缓慢呼吸
    sleep_base = tint(transform(base, sx=1.10, sy=0.85), 0.82)
    frames['sleep'] = [transform(sleep_base, sy=1 + 0.02 * math.sin(2 * math.pi * i / n))
                       for i in range(n)]
    # 听音乐：大幅左右摇摆（跟着节奏）
    frames['listen'] = [transform(base,
                                  angle=-14 * math.sin(2 * math.pi * i / n),
                                  dy=-6 * abs(math.sin(2 * math.pi * i / n)))
                        for i in range(n)]
    # 紧张：快速小幅度抖动
    frames['nervous'] = [transform(base,
                                   dx=4 * math.sin(6 * math.pi * i / n),
                                   dy=3 * math.sin(10 * math.pi * i / n),
                                   angle=3 * math.sin(14 * math.pi * i / n),
                                   sy=0.97)
                         for i in range(n)]
    # 虚弱：压扁 + 去饱和变暗
    weak_base = tint(transform(base, sx=1.08, sy=0.88), 0.72, (0.9, 0.88, 0.86))
    frames['weak'] = [transform(weak_base, sy=1 + 0.02 * math.sin(2 * math.pi * i / n))
                      for i in range(n)]
    # 下雨：变暗 + 偏蓝 + 微缩
    rain_base = tint(transform(base, sy=0.94), 0.78, (0.82, 0.90, 1.06))
    frames['rain'] = [transform(rain_base, sy=1 + 0.015 * math.sin(2 * math.pi * i / n))
                      for i in range(n)]
    # 充电：暖光罩 + 亮度脉冲
    charge_base = glow(base, 0.45)
    frames['charge'] = [tint(charge_base, 1.0 + 0.12 * math.sin(2 * math.pi * i / n))
                        for i in range(n)]
    return frames


def main():
    total = 0
    for ch in sorted(os.listdir(SOURCE)):
        src = os.path.join(SOURCE, ch)
        if not os.path.isdir(src):
            continue
        imgs = [f for f in os.listdir(src) if f.lower().endswith(('.jpg', '.jpeg', '.png'))]
        if not imgs:
            continue
        # 取每张图分别生成一套；同名动作多图时按序号覆盖
        out_dir = os.path.join(ASSETS, ch)
        os.makedirs(out_dir, exist_ok=True)
        for n, f in enumerate(sorted(imgs)):
            tag = '' if len(imgs) == 1 else f'_{n + 1}'
            base = fit_canvas(remove_bg(Image.open(os.path.join(src, f))))
            base.save(os.path.join(out_dir, f'pet_idle{tag}.png'))
            for action, seq in make_frames(base).items():
                for i, frame in enumerate(seq):
                    frame.save(os.path.join(out_dir, f'pet_{action}{tag}_{i}.png'))
            total += 1
            print('processed', ch, f, '->', out_dir)
    print('done,', total, 'images')


if __name__ == '__main__':
    main()
