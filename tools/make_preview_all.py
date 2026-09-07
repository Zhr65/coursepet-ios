# 生成三角色「原图 vs 处理结果」对比页（含动画帧抽样的动图预览）
import base64, io, os
from PIL import Image

ROOT = r'D:\AI\CoursePet'
SRC = r'D:\桌面\小火人\converted'
ASSETS = os.path.join(ROOT, 'pet_assets')
OUT_HTML = os.path.join(ROOT, 'prototype', 'preview.html')

CHECKER = ("background:repeating-conic-gradient(#f0f0f0 0% 25%, #ffffff 0% 50%) "
           "0 0 / 20px 20px;")

def b64(path, width=None):
    im = Image.open(path)
    if width and im.width > width:
        im = im.resize((width, int(im.height * width / im.width)), Image.LANCZOS)
    buf = io.BytesIO()
    im.save(buf, 'PNG')
    return base64.b64encode(buf.getvalue()).decode()

PAIRS = [
    ('char1', '03ffd5caf31a38100485aab72b09b8ad.png'),
    ('char2', '7151758eebc016fac2b87bc4c8b4d0a8.png'),
    ('char3', 'cb560916a761a0d47ebfe9aacb633eab.png'),
]

sections = []
for ch, orig in PAIRS:
    frames = ''
    for i in (0, 2, 4):
        frames += f'<img src="data:image/png;base64,{b64(os.path.join(ASSETS, ch, f"pet_idle_{i}.png"), 72)}" style="width:72px;border-radius:6px;">'
    sections.append(f'''
    <div style="background:#fff;border-radius:12px;padding:16px;margin-bottom:20px;box-shadow:0 2px 8px rgba(0,0,0,.1);">
      <h3 style="margin:0 0 12px">{ch}</h3>
      <div style="display:flex;gap:16px;align-items:flex-start;flex-wrap:wrap;">
        <figure style="margin:0;text-align:center;">
          <img src="data:image/png;base64,{b64(os.path.join(SRC, orig), 220)}" style="width:220px;border-radius:8px;">
          <figcaption style="font-size:12px;color:#888;margin-top:4px;">原图</figcaption>
        </figure>
        <figure style="margin:0;text-align:center;">
          <div style="{CHECKER}padding:8px;border-radius:8px;display:inline-block;">
            <img src="data:image/png;base64,{b64(os.path.join(ASSETS, ch, 'pet_idle.png'), 220)}" style="width:220px;">
          </div>
          <figcaption style="font-size:12px;color:#888;margin-top:4px;">处理结果（格子=透明）</figcaption>
        </figure>
        <figure style="margin:0;text-align:center;">
          <div style="{CHECKER}padding:6px;border-radius:8px;display:inline-block;">{frames}</div>
          <figcaption style="font-size:12px;color:#888;margin-top:4px;">待机动画帧抽样</figcaption>
        </figure>
      </div>
    </div>''')

html = f'''<!DOCTYPE html>
<html lang="zh-CN"><head><meta charset="UTF-8"><title>宠物素材对比</title></head>
<body style="font-family:-apple-system,'Microsoft YaHei',sans-serif;background:#f5f3ef;padding:24px;max-width:980px;margin:0 auto;">
<h2>三角色清理效果对比</h2>
<p style="color:#666">逐张检查：处理结果里还有没有残留的装饰物（多余的橙色/黄色/蓝色块）？角色本体有没有被误删（缺角/缺色）？有问题的在终端告诉我：哪个角色 + 什么位置 + 怎么改。</p>
{''.join(sections)}
</body></html>'''
with open(OUT_HTML, 'w', encoding='utf-8') as f:
    f.write(html)
print('written', OUT_HTML)
