# 生成全角色「原图 vs 处理结果」对比页（自动发现 pet_assets 下所有角色）
import base64, io, os, re
from PIL import Image

ROOT = r'D:\AI\CoursePet'
ASSETS = os.path.join(ROOT, 'pet_assets')
SRC = r'D:\桌面\小火人\converted'
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

def find_original(ch):
    """原图 = pet_assets 里的原始文件，或 pet_source 里的截图"""
    adir = os.path.join(ASSETS, ch)
    for f in sorted(os.listdir(adir)):
        if re.match(r'^pet_.*\.png$', f, re.I):
            continue
        if f.lower().endswith(('.jpg', '.jpeg', '.png')):
            return os.path.join(adir, f)
    sdir = os.path.join(ROOT, 'pet_source', ch)
    if os.path.isdir(sdir):
        for f in sorted(os.listdir(sdir)):
            if f.lower().endswith(('.jpg', '.jpeg', '.png')):
                return os.path.join(sdir, f)
    return None

sections = []
for ch in sorted(os.listdir(ASSETS)):
    if not os.path.isdir(os.path.join(ASSETS, ch)):
        continue
    static = os.path.join(ASSETS, ch, 'pet_idle.png')
    if not os.path.exists(static):
        continue
    orig = find_original(ch)
    frames = ''
    for i in (0, 2, 4):
        frames += f'<img src="data:image/png;base64,{b64(os.path.join(ASSETS, ch, f"pet_idle_{i}.png"), 72)}" style="width:72px;border-radius:6px;">'
    orig_html = ''
    if orig:
        orig_html = f'''<figure style="margin:0;text-align:center;">
          <div style="{CHECKER}padding:8px;border-radius:8px;display:inline-block;">
            <img src="data:image/png;base64,{b64(orig, 220)}" style="width:220px;">
          </div>
          <figcaption style="font-size:12px;color:#888;margin-top:4px;">原图（格子=透明）</figcaption>
        </figure>'''
    sections.append(f'''
    <div style="background:#fff;border-radius:12px;padding:16px;margin-bottom:20px;box-shadow:0 2px 8px rgba(0,0,0,.1);">
      <h3 style="margin:0 0 12px">{ch}</h3>
      <div style="display:flex;gap:16px;align-items:flex-start;flex-wrap:wrap;">
        {orig_html}
        <figure style="margin:0;text-align:center;">
          <div style="{CHECKER}padding:8px;border-radius:8px;display:inline-block;">
            <img src="data:image/png;base64,{b64(static, 220)}" style="width:220px;">
          </div>
          <figcaption style="font-size:12px;color:#888;margin-top:4px;">处理结果</figcaption>
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
<h2>角色素材对比</h2>
<p style="color:#666">逐张检查：处理结果里有没有残留装饰物？角色本体有没有被误删？有问题的在终端告诉我：哪个角色 + 什么位置 + 怎么改。</p>
{''.join(sections)}
</body></html>'''
with open(OUT_HTML, 'w', encoding='utf-8') as f:
    f.write(html)
print('written', OUT_HTML)
