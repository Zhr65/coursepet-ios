#!/bin/bash
# CoursePet 运维套件安装：备份 + 健康监控 一次性装好（幂等，可重复执行）
# 用法：在服务器上 bash /root/coursepet-api/ops/install.sh
set -e
OPS_DIR=/root/coursepet-api/ops

chmod +x "$OPS_DIR/backup.sh" "$OPS_DIR/health_monitor.sh" "$OPS_DIR/bark_alert.py"

# 写 cron：保留既有条目，去掉旧的 coursepet 运维条目后再追加（防重复）
(
    crontab -l 2>/dev/null | grep -v "coursepet-api/ops" || true
    echo "0 4 * * * $OPS_DIR/backup.sh >> $OPS_DIR/backup.log 2>&1"
    echo "*/2 * * * * $OPS_DIR/health_monitor.sh"
) | crontab -

echo "=== 已安装的 crontab ==="
crontab -l
