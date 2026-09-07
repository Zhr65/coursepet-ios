// 导入流程：选文件 → SheetJS 解析 → 字段映射 → 预览 → 入库
import { guessMapping, mapRows } from '../mapping.js';
import { openDialog, toast } from './dialogs.js';
import { escapeHtml } from './week-view.js';

const FIELDS = [
  ['name', '课程名称（必填）'],
  ['teacher', '教师（可选）'],
  ['location', '地点（可选）'],
  ['dayOfWeek', '星期几（必填）'],
  ['startTime', '开始时间（必填）'],
  ['endTime', '结束时间（必填）'],
  ['startWeek', '起始周（可选，默认1）'],
  ['endWeek', '结束周（可选，默认20）'],
  ['weekParity', '单双周（可选，默认每周）'],
];

async function parseFile(file) {
  const buf = await file.arrayBuffer();
  const wb = XLSX.read(buf, { type: 'array' });   // SheetJS 由 index.html 的 CDN script 提供
  const ws = wb.Sheets[wb.SheetNames[0]];
  if (!ws) throw new Error('Excel 里没有工作表');
  return XLSX.utils.sheet_to_json(ws, { header: 1, defval: '' });
}

export function initImport({ onImport }) {
  document.getElementById('btn-import').addEventListener('click', () => {
    const body = document.createElement('div');
    body.className = 'dialog-body';
    body.innerHTML = `
      <p style="margin-top:0;font-size:14px">支持 .xlsx / .xls。单双周分开两个文件时：导入单周文件选「单周」、双周文件选「双周」；只有一个通用文件选「自动」。</p>
      <div class="form-row"><label for="import-file">课表文件</label>
        <input id="import-file" type="file" accept=".xlsx,.xls"></div>
      <div class="form-row"><label for="import-parity">单双周归属</label>
        <select id="import-parity">
          <option value="">自动（按文件里的单双周列）</option>
          <option value="single">这是单周课表</option>
          <option value="double">这是双周课表</option>
        </select></div>
      <div id="import-mapping" class="hidden"></div>
      <div id="import-preview" class="hidden"></div>
      <div class="btn-row">
        <button id="import-cancel" class="btn">取消</button>
        <button id="import-confirm" class="btn primary" disabled>确认导入</button>
      </div>`;
    const dlg = openDialog('导入课表', body);
    const fileInput = body.querySelector('#import-file');
    const paritySel = body.querySelector('#import-parity');
    const mappingBox = body.querySelector('#import-mapping');
    const previewBox = body.querySelector('#import-preview');
    const confirmBtn = body.querySelector('#import-confirm');
    body.querySelector('#import-cancel').addEventListener('click', dlg.close);

    let fm = null, rows = null, parsed = null;

    fileInput.addEventListener('change', async () => {
      const file = fileInput.files[0];
      if (!file) return;
      try {
        rows = await parseFile(file);
      } catch (e) {
        toast('文件解析失败：' + e.message);
        return;
      }
      if (!rows.length) { toast('文件是空的'); return; }
      fm = guessMapping(rows[0]);
      mappingBox.innerHTML = '<h4 style="margin:12px 0 8px">字段映射（对不上的列手动选）</h4>';
      mappingBox.classList.remove('hidden');
      const selects = {};
      for (const [field, label] of FIELDS) {
        const row = document.createElement('div');
        row.className = 'form-row';
        const lab = document.createElement('label');
        lab.textContent = label;
        const sel = document.createElement('select');
        sel.dataset.field = field;
        sel.innerHTML = '<option value="-1">— 不导入 —</option>' +
          rows[0].map((h, i) => `<option value="${i}">第 ${i + 1} 列：${escapeHtml(String(h).slice(0, 12))}</option>`).join('');
        sel.value = String(fm[field] ?? -1);
        selects[field] = sel;
        row.append(lab, sel);
        mappingBox.append(row);
      }
      const apply = () => {
        for (const [field, sel] of Object.entries(selects)) fm[field] = Number(sel.value);
        parsed = mapRows(rows, fm);
        const parity = paritySel.value;
        if (parity) parsed.courses.forEach((c) => { c.weekParity = parity; });
        previewBox.innerHTML = `
          <h4 style="margin:12px 0 8px">预览（共 ${parsed.courses.length} 条课程）</h4>
          <div style="max-height:180px;overflow:auto;font-size:13px;border:1px solid #ddd;border-radius:8px;">
            <table style="width:100%;border-collapse:collapse">
              <tr><th style="padding:6px;text-align:left">课程</th><th>星期</th><th>时间</th><th>周次</th></tr>
              ${parsed.courses.slice(0, 10).map((c) => `<tr><td style="padding:6px">${escapeHtml(c.name)}</td><td>${c.dayOfWeek}</td><td>${c.startTime}–${c.endTime}</td><td>${c.startWeek}-${c.endWeek}周</td></tr>`).join('')}
            </table>
          </div>
          ${parsed.errors.length ? `<p style="color:var(--danger);font-size:13px">⚠ ${parsed.errors.length} 行无法导入：${parsed.errors.slice(0, 3).map((e) => `第${e.row}行 ${e.reason}`).join('；')}</p>` : ''}`;
        previewBox.classList.remove('hidden');
        confirmBtn.disabled = parsed.courses.length === 0;
      };
      mappingBox.addEventListener('change', apply);
      paritySel.addEventListener('change', apply);
      apply();
    });

    confirmBtn.addEventListener('click', () => {
      if (!parsed) return;
      onImport(parsed.courses);
      toast(`已导入 ${parsed.courses.length} 条课程`);
      dlg.close();
    });
  });
}
