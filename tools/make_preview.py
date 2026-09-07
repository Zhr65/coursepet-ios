# 生成浏览器对比页：原图 + 草稿 并排（base64 内嵌）
import base64, io, os
from PIL import Image

SRC = r'D:\桌面\小火人\converted'
DRAFT = r'D:\CoursePet\tools\out'
SCREEN = r'D:\CoursePet\.superpowers\brainstorm\1773-1788788424\content'
os.makedirs(SCREEN, exist_ok=True)

pairs = [
    ('03ffd5caf31a38100485aab72b09b8ad.png', 'pet_v1_blue.png', '第 1 张（蓝色系）'),
    ('7151758eebc016fac2b87bc4c8b4d0a8.png', 'pet_v1_orange.png', '第 2 张（橙色系）'),
    ('cb560916a761a0d47ebfe9aacb633eab.png', 'pet_v1_green.png', '第 3 张（绿色系）'),
]

def b64(path, width=None):
    im = Image.open(path)
    if width and im.width > width:
        im = im.resize((width, int(im.height * width / im.width)), Image.LANCZOS)
    buf = io.BytesIO()
    im.save(buf, 'PNG')
    return base64.b64encode(buf.getvalue()).decode()

cards = []
for i, (orig, draft, label) in enumerate(pairs):
    cards.append(f'''
    <div class="card" data-choice="v{i+1}" onclick="toggleSelect(this)">
      <div class="card-image" style="display:flex;gap:12px;align-items:flex-end;justify-content:center;padding:8px 0;">
        <figure style="margin:0;text-align:center;">
          <img src="data:image/png;base64,{b64(os.path.join(SRC, orig), 250)}" style="width:250px;border-radius:8px;">
          <figcaption style="font-size:12px;color:#888;margin-top:4px;">原图（你的截图）</figcaption>
        </figure>
        <figure style="margin:0;text-align:center;">
          <img src="data:image/png;base64,{b64(os.path.join(DRAFT, draft), 250)}" style="width:250px;border-radius:8px;background:#f7f4ee;">
          <figcaption style="font-size:12px;color:#888;margin-top:4px;">我的草稿</figcaption>
        </figure>
      </div>
      <div class="card-body"><h3>{label}</h3>
      <p>点卡片可标记「这张方向对了」。哪里不像（颜色/形状/五官/配件）请到终端告诉我。</p></div>
    </div>''')

html = f'''
<h2>第一版草稿：并排对比</h2>
<p class="subtitle">左边是你的原图截图，右边是我按程序分析 + 小火人风格画的草稿。三张都看一下，然后回终端告诉我每张哪里不像，越具体越好（比如「眼睛要大两倍」「身体更圆」「火苗尖太长」）。</p>
<div class="cards">
{''.join(cards)}
</div>
'''
with open(os.path.join(SCREEN, 'pet-draft-1.html'), 'w', encoding='utf-8') as f:
    f.write(html)
print('html written to', os.path.join(SCREEN, 'pet-draft-1.html'))
