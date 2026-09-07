# 抠图结果预览页：静态抠图 + 三套动作帧序列（棋盘格背景显示透明）
import base64, io, os
from PIL import Image

ASSETS = r'D:\AI\CoursePet\pet_assets'
SCREEN = r'D:\AI\CoursePet\.superpowers\brainstorm\1900-1788791526\content'

CHECKER = ("background:repeating-conic-gradient(#f0f0f0 0% 25%, #ffffff 0% 50%) "
           "0 0 / 24px 24px;")

def b64(path, width=None):
    im = Image.open(path)
    if width and im.width > width:
        im = im.resize((width, int(im.height * width / im.width)), Image.LANCZOS)
    buf = io.BytesIO()
    im.save(buf, 'PNG')
    return base64.b64encode(buf.getvalue()).decode()

sections = []
for ch in sorted(os.listdir(ASSETS)):
    d = os.path.join(ASSETS, ch)
    if not os.path.isdir(d):
        continue
    static = os.path.join(d, 'pet_idle.png')
    if not os.path.exists(static):
        continue
    labels = {'idle': '待机（呼吸）', 'happy': '开心（蹦跳）', 'walk': '走路（摇摆）',
              'excite': '兴奋（快跳）', 'sleep': '睡觉（下压）', 'listen': '听音乐（摇摆）',
              'nervous': '紧张（发抖）', 'weak': '虚弱（变暗）', 'rain': '下雨（偏蓝）',
              'charge': '充电（发光）'}
    import re
    actions = sorted({m.group(1) for f in os.listdir(d)
                      if (m := re.match(r'pet_(.+)_\d+\.png', f))})
    strips = ''
    for action in actions:
        imgs = ''.join(
            f'<img src="data:image/png;base64,{b64(os.path.join(d, f"pet_{action}_{i}.png"), 64)}" '
            f'style="width:64px;border-radius:4px;">'
            for i in range(8))
        strips += (f'<div style="margin:6px 0;"><span style="display:inline-block;width:110px;'
                   f'font-size:13px;color:#666;">{labels.get(action, action)}</span>'
                   f'<span style="{CHECKER}display:inline-block;padding:2px;border-radius:6px;">{imgs}</span></div>')
    sections.append(f'''
    <div class="card" data-choice="{ch}" onclick="toggleSelect(this)">
      <div class="card-image" style="display:flex;gap:16px;align-items:center;justify-content:center;padding:8px 0;">
        <div style="{CHECKER}padding:8px;border-radius:8px;text-align:center;">
          <img src="data:image/png;base64,{b64(static, 190)}" style="width:190px;">
        </div>
        <div>{strips}</div>
      </div>
      <div class="card-body"><h3>{ch} — 抠图结果</h3>
      <p>左 = 抠好的透明 PNG（棋盘格 = 透明区域）；右 = 三套自动动画帧（8 帧循环）。</p></div>
    </div>''')

html = f'''
<h2>抠图 + 动画帧生成结果</h2>
<p class="subtitle">三张图已自动完成：抠背景 → 裁标准尺寸 → 生成 10 套 8 帧动画。请检查：①抠图干不干净（边缘有没有残留背景色/缺角）②动画幅度是否合适。有问题回终端告诉我改；没问题就点卡片标记「OK」。</p>
<div class="cards">
{''.join(sections)}
</div>
'''
with open(os.path.join(SCREEN, 'pet-cutout-1.html'), 'w', encoding='utf-8') as f:
    f.write(html)
print('html written')
