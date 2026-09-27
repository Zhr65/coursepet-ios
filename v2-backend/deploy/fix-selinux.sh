#!/usr/bin/env bash
# 修复 SELinux 拦截：venv 移到 /opt + 更新 unit + 重启
set -e
echo "--- move venv to /opt ---"
if [ -d /opt/coursepet-env ]; then
  echo "already moved"
else
  sudo mv /home/zhr/coursepet-env /opt/coursepet-env
fi
sudo chown -R zhr:zhr /opt/coursepet-env
sudo restorecon -R /opt/coursepet-env

echo "--- update unit ---"
sudo sed -i 's|/home/zhr/coursepet-env|/opt/coursepet-env|' /etc/systemd/system/coursepet-api.service
sudo systemctl daemon-reload
sudo systemctl restart coursepet-api.service
sleep 10

echo "--- verify ---"
systemctl is-active coursepet-api.service
curl -s --max-time 10 http://127.0.0.1:8000/health
echo
URL=$(journalctl -u cloudflared-coursepet.service --no-pager | grep -oE 'https://[a-z0-9-]+\.trycloudflare\.com' | tail -1)
echo "PUBLIC_URL=$URL"
