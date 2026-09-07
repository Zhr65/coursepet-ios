// 课程表单弹层：新增 / 编辑 / 删除
// 事件用委托绑定在弹层容器上（closest 匹配按钮），避免逐元素绑定
import { openDialog, toast } from './dialogs.js';
import { createCourse, COURSE_COLORS, timeToMinutes } from '../schedule.js';

const DAY_NAMES = ['', '周一', '周二', '周三', '周四', '周五', '周六', '周日'];

export function openCourseForm({ course, dayOfWeek, onSave, onDelete }) {
  const isEdit = !!course;
  const c = course || {};
  const body = document.createElement('div');
  body.className = 'dialog-body';
  body.innerHTML = `
    <div class="form-row"><label>课程名称（必填）</label><input id="cf-name" value="${c.name || ''}"></div>
    <div class="form-row"><label>教师</label><input id="cf-teacher" value="${c.teacher || ''}"></div>
    <div class="form-row"><label>地点</label><input id="cf-location" value="${c.location || ''}"></div>
    <div class="form-row" style="display:flex;gap:8px">
      <div style="flex:1"><label>星期</label>
        <select id="cf-day">${[1, 2, 3, 4, 5, 6, 7].map((d) => `<option value="${d}" ${(c.dayOfWeek ?? dayOfWeek ?? 1) === d ? 'selected' : ''}>${DAY_NAMES[d]}</option>`).join('')}</select></div>
      <div style="flex:1"><label>开始</label><input id="cf-start" type="time" value="${c.startTime || '08:00'}"></div>
      <div style="flex:1"><label>结束</label><input id="cf-end" type="time" value="${c.endTime || '09:40'}"></div>
    </div>
    <div class="form-row" style="display:flex;gap:8px">
      <div style="flex:1"><label>起始周</label><input id="cf-sw" type="number" min="1" value="${c.startWeek ?? 1}"></div>
      <div style="flex:1"><label>结束周</label><input id="cf-ew" type="number" min="1" value="${c.endWeek ?? 20}"></div>
      <div style="flex:1"><label>单双周</label>
        <select id="cf-parity">
          <option value="both" ${(c.weekParity ?? 'both') === 'both' ? 'selected' : ''}>每周</option>
          <option value="single" ${c.weekParity === 'single' ? 'selected' : ''}>单周</option>
          <option value="double" ${c.weekParity === 'double' ? 'selected' : ''}>双周</option>
        </select></div>
    </div>
    <div class="form-row"><label>颜色</label>
      <select id="cf-color">${COURSE_COLORS.map((col, i) => `<option value="${col}" ${(c.color || COURSE_COLORS[0]) === col ? 'selected' : ''}>颜色 ${i + 1}</option>`).join('')}</select></div>
    <div class="btn-row">
      ${isEdit ? '<button id="cf-delete" class="btn" style="color:var(--danger)">删除</button>' : ''}
      <button id="cf-cancel" class="btn">取消</button>
      <button id="cf-save" class="btn primary">保存</button>
    </div>`;
  const dlg = openDialog(isEdit ? '编辑课程' : '添加课程', body);

  // 事件委托：一个监听器处理全部按钮（对元素身份变化免疫）
  dlg.box.addEventListener('click', (e) => {
    const btn = e.target.closest('#cf-save, #cf-cancel, #cf-delete');
    if (!btn) return;
    if (btn.id === 'cf-cancel') { dlg.close(); return; }
    if (btn.id === 'cf-delete') {
      if (confirm(`确定删除「${c.name}」吗？`)) { onDelete(c.id); dlg.close(); }
      return;
    }
    // 保存
    const name = body.querySelector('#cf-name').value.trim();
    const startTime = body.querySelector('#cf-start').value;
    const endTime = body.querySelector('#cf-end').value;
    if (!name) { toast('课程名称不能为空'); return; }
    if (timeToMinutes(startTime) == null || timeToMinutes(endTime) == null) { toast('时间格式不对'); return; }
    const sw = parseInt(body.querySelector('#cf-sw').value, 10) || 1;
    const ew = parseInt(body.querySelector('#cf-ew').value, 10) || 20;
    if (ew < sw) { toast('结束周不能小于起始周'); return; }
    const data = {
      name,
      teacher: body.querySelector('#cf-teacher').value.trim(),
      location: body.querySelector('#cf-location').value.trim(),
      dayOfWeek: Number(body.querySelector('#cf-day').value),
      startTime, endTime,
      startWeek: sw, endWeek: ew,
      weekParity: body.querySelector('#cf-parity').value,
      color: body.querySelector('#cf-color').value,
    };
    // 编辑时保留原 id；新增时 createCourse 自动生成 id
    onSave(createCourse(isEdit ? { ...c, ...data } : data));
    dlg.close();
  });
}
