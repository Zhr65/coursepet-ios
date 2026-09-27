#!/usr/bin/env bash
# 注册 systemd 服务：停手动进程 → 装 unit → 启用自启 → 验证
set -e
echo "--- 1. 确认 cloudflared 路径 ---"
CFD=$(command -v cloudflared)
echo "cloudflared: $CFD"

echo "--- 2. 停掉手动 nohup 进程 ---"
pkill -f "uvicorn app.main" 2>/dev/null || true
pkill -f "cloudflared tunnel" 2>/dev/null || true
sleep 1

echo "--- 3. 安装 unit 文件 ---"
sudo mkdir -p ~/deploy 2>/dev/null || true
sudo cp ~/coursepet-api.service /etc/systemd/system/
if [ "$CFD" != "/usr/bin/cloudflared" ]; then
  # 路径不是 /usr/bin 时改写 unit 里的 ExecStart
  sed "s|ExecStart=/usr/bin/cloudflared|ExecStart=$CFD|" ~/cloudflared-coursepet.service > /tmp/cf.service
  sudo cp /tmp/cf.service /etc/systemd/system/cloudflared-coursepet.service
else
  sudo cp ~/cloudflared-coursepet.service /etc/systemd/system/
fi
sudo systemctl daemon-reload

echo "--- 4. PostgreSQL 确保自启 ---"
sudo systemctl enable postgresql 2>/dev/null || true

echo "--- 5. 启用并启动两个服务 ---"
sudo systemctl enable --now coursepet-api.service
sudo systemctl enable --now cloudflared-coursepet.service
sleep 14

echo "--- 6. 验证 ---"
echo "api: $(systemctl is-active coursepet-api.service)"
echo "tunnel: $(systemctl is-active cloudflared-coursepet.service)"
curl -s --max-time 10 http://127.0.0.1:8000/health
echo
URL=$(journalctl -u cloudflared-coursepet.service --no-pager | grep -oE 'https://[a-z0-9-]+\.trycloudflare\.com' | tail -1)
echo "PUBLIC_URL=$URL"

# 顺手给用户留一个"查 URL"快捷脚本
cat > ~/myurl.sh <<'EOF'
#!/usr/bin/env bash
journalctl -u cloudflared-coursepet.service --no-pager | grep -oE 'https://[a-z0-9-]+\.trycloudflare\.com' | tail -1
EOF
chmod +x ~/myurl.sh
echo "myurl.sh ready"
