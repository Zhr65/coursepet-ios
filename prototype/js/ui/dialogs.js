// 通用弹层 + toast
export function openDialog(title, bodyEl, opts = {}) {
  const root = document.getElementById('dialog-root');
  const overlay = document.createElement('div');
  overlay.className = 'dialog-overlay';
  const box = document.createElement('div');
  box.className = 'dialog';
  box.setAttribute('role', 'dialog');
  box.setAttribute('aria-label', title);
  const head = document.createElement('div');
  head.className = 'dialog-head';
  const h = document.createElement('h3');
  h.textContent = title;
  const close = document.createElement('button');
  close.className = 'icon-btn';
  close.textContent = '✕';
  close.setAttribute('aria-label', '关闭');
  let onCloseCb = opts.onClose || null;
  const doClose = () => { overlay.remove(); if (onCloseCb) onCloseCb(); };
  close.addEventListener('click', doClose);
  overlay.addEventListener('click', (e) => { if (e.target === overlay) doClose(); });
  head.append(h, close);
  box.append(head, bodyEl);
  overlay.append(box);
  root.append(overlay);
  return { overlay, box, close: doClose, setOnClose: (fn) => { onCloseCb = fn; } };
}

let toastTimer = null;
export function toast(text) {
  const el = document.getElementById('toast');
  el.textContent = text;
  el.classList.remove('hidden');
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => el.classList.add('hidden'), 2500);
}
