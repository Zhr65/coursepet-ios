#!/usr/bin/env bash
# venv 不能搬迁（shebang 硬编码出生路径）→ 在 /opt 重建
set -e
echo "--- rebuild venv at /opt ---"
sudo rm -rf /opt/coursepet-env
sudo python3 -m venv /opt/coursepet-env
sudo /opt/coursepet-env/bin/pip install --quiet --upgrade pip -i https://pypi.tuna.tsinghua.edu.cn/simple
sudo /opt/coursepet-env/bin/pip install --quiet -r /home/zhr/coursepet-api/requirements.txt -i https://pypi.tuna.tsinghua.edu.cn/simple
sudo chown -R zhr:zhr /opt/coursepet-env
sudo restorecon -R /opt/coursepet-env

echo "--- restart api ---"
sudo systemctl restart coursepet-api.service
sleep 8
systemctl is-active coursepet-api.service
curl -s --max-time 10 http://127.0.0.1:8000/health
echo
URL=$(journalctl -u cloudflared-coursepet.service --no-pager | grep -oE 'https://[a-z0-9-]+\.trycloudflare\.com' | tail -1)
echo "PUBLIC_URL=$URL"
