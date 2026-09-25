# -*- coding: utf-8 -*-
# 生成宠物帧动画素材：
# 1. 黑驴 JPG 原图抠图（背景为浅色渐变、主体纯黑 → 从图像边缘 BFS 泛洪填充标记背景）
# 2. 五张新形象图统一缩放贴到 256x256 透明画布居中
# 3. 每只生成 10 动作 x 8 帧 = 80 张帧图（静态形象，动作差异由程序化叠加表现）
# 输出：pet_assets/charN/ 与 ios/AppPetAssets/charN/ 两份
import os
from collections import deque
from PIL import Image, ImageFilter

ROOT = r"d:\AI\CoursePet"
SRC_DIR = os.path.join(ROOT, "pet_assets", "src")
OUT_DIRS = [
    os.path.join(ROOT, "pet_assets"),
    os.path.join(ROOT, "ios", "AppPetAssets"),
]
ACTIONS = ["idle", "happy", "walk", "excite", "sleep", "weak", "nervous", "listen", "rain", "charge"]
FRAMES = 8
SIZE = 256

# 新形象：charId -> 源图文件名（源图统一放 pet_assets/src/ 下）
NEW_CHARS = {
    "char5": "char5_explosion_cat.png",      # 爆炸头猫
    "char6": "char6_fringe_dog.png",         # 刘海狗
    "char7": "char7_eggshell_chick.png",     # 蛋壳鸡
    "char8": "char8_durian_hedgehog.png",    # 榴莲刺猬
    "char9": "char9_donkey.png",             # 小黑驴（需抠图）
}


def cutout_bright_bg(src_path, dst_path, bright_threshold=200):
    """抠掉浅色背景：从图像边缘的亮像素 BFS 泛洪，把连通亮区设为透明（保留主体内部亮区）。"""
    im = Image.open(src_path).convert("RGBA")
    w, h = im.size
    px = im.load()

    def is_bright(x, y):
        r, g, b, a = px[x, y]
        return (r + g + b) / 3 >= bright_threshold

    visited = [[False] * w for _ in range(h)]
    q = deque()
    # 种子：四条边上所有亮像素
    for x in range(w):
        for y in (0, h - 1):
            if is_bright(x, y) and not visited[y][x]:
                visited[y][x] = True
                q.append((x, y))
    for y in range(h):
        for x in (0, w - 1):
            if is_bright(x, y) and not visited[y][x]:
                visited[y][x] = True
                q.append((x, y))
    # BFS 泛洪：只向相邻亮像素扩散
    while q:
        x, y = q.popleft()
        for nx, ny in ((x+1, y), (x-1, y), (x, y+1), (x, y-1)):
            if 0 <= nx < w and 0 <= ny < h and not visited[ny][nx] and is_bright(nx, ny):
                visited[ny][nx] = True
                q.append((nx, ny))
    # 标记背景为透明
    for y in range(h):
        for x in range(w):
            if visited[y][x]:
                r, g, b, a = px[x, y]
                px[x, y] = (r, g, b, 0)

    # 边缘羽化：对 alpha 通道做轻微模糊，弱化锯齿
    alpha = im.getchannel("A").filter(ImageFilter.GaussianBlur(1.2))
    im.putalpha(alpha)
    im.save(dst_path)
    print(f"抠图完成 -> {dst_path}")


def normalize_256(src_path):
    """等比缩放并居中贴到 256x256 透明画布，返回画布图。"""
    im = Image.open(src_path).convert("RGBA")
    im.thumbnail((SIZE - 12, SIZE - 12), Image.LANCZOS)  # 留 6px 边距防裁切
    canvas = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    canvas.paste(im, ((SIZE - im.width) // 2, (SIZE - im.height) // 2), im)
    return canvas


def main():
    # 第 0 步：黑驴原图抠图（若目标不存在才抠，避免重复处理；阈值 150 彻底吃掉腿部阴影，
    # 主体纯黑亮度远低于此、白眼珠在内部不连通边缘，均不受影响）
    donkey_src = os.path.join(SRC_DIR, "char9_donkey_raw.jpg")
    donkey_dst = os.path.join(SRC_DIR, "char9_donkey.png")
    if not os.path.exists(donkey_dst):
        cutout_bright_bg(donkey_src, donkey_dst, bright_threshold=150)

    # 逐只生成帧
    for char_id, src_name in NEW_CHARS.items():
        src_path = os.path.join(SRC_DIR, src_name)
        if not os.path.exists(src_path):
            print(f"!! 缺少源图 {src_path}，跳过 {char_id}")
            continue
        base = normalize_256(src_path)
        for out_root in OUT_DIRS:
            out_dir = os.path.join(out_root, char_id)
            os.makedirs(out_dir, exist_ok=True)
            for action in ACTIONS:
                for f in range(FRAMES):
                    base.save(os.path.join(out_dir, f"pet_{action}_{f}.png"))
        print(f"{char_id} 完成：80 帧 x 2 目录")

    print("全部完成")


if __name__ == "__main__":
    main()
