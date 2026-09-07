# 生成主屏图标：柔和渐变圆底 + char1 宠物居中（180×180）
import os
from PIL import Image, ImageDraw, ImageFilter, ImageOps

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, 'prototype', 'icons')
os.makedirs(OUT, exist_ok=True)

SIZE = 180
img = Image.new('RGBA', (SIZE, SIZE), (0, 0, 0, 0))
d = ImageDraw.Draw(img)
# 渐变圆底（日落橙→粉）
grad = Image.radial_gradient('L').resize((SIZE, SIZE))
base = ImageOps.colorize(grad, black=(255, 145, 110), white=(255, 214, 170))
mask = Image.new('L', (SIZE, SIZE), 0)
ImageDraw.Draw(mask).rounded_rectangle([4, 4, SIZE - 4, SIZE - 4], radius=40, fill=255)
img.paste(base, (0, 0), mask)
# 宠物居中（取 char1 待机第 0 帧，缩到 120px）
pet = Image.open(os.path.join(ROOT, 'pet_assets', 'char1', 'pet_idle_0.png'))
pet = pet.resize((120, 120), Image.LANCZOS)
img.alpha_composite(pet, ((SIZE - 120) // 2, (SIZE - 120) // 2))
img.save(os.path.join(OUT, 'icon-180.png'), 'PNG')
print('written', os.path.join(OUT, 'icon-180.png'))
