#!/bin/bash
# CoursePet /health 自愈监控（cron 每 2 分钟）
#   探活 → 失败自动重启服务 → 30s 后复探 → 仍失败发 Bark 告警（按小时桶防重）
#   下一轮探活成功时若此前告警过，补发一条"已恢复"
# 设计原则：探活成功时零写盘零网络；告警走 app.notifications（没配 Bark Key 自动跳过）
set -u
OPS_DIR=/root/coursepet-api/ops
LOG="$OPS_DIR/health_monitor.log"
STATE=/tmp/coursepet_health_down   # 标记"上一轮是挂的"
PY=/opt/coursepet-env/bin/python

if curl -fsS -m 5 http://localhost:8000/health >/dev/null 2>&1; then
    if [ -f "$STATE" ]; then
        rm -f "$STATE"
        echo "$(date '+%F %T') recovered" >> "$LOG"
        "$PY" "$OPS_DIR/bark_alert.py" recovered >> "$LOG" 2>&1 &
    fi
    exit 0
fi

echo "$(date '+%F %T') health check failed, restarting coursepet-api" >> "$LOG"
systemctl restart coursepet-api
touch "$STATE"
sleep 30

if curl -fsS -m 5 http://localhost:8000/health >/dev/null 2>&1; then
    echo "$(date '+%F %T') recovered after restart" >> "$LOG"
    rm -f "$STATE"
    "$PY" "$OPS_DIR/bark_alert.py" recovered >> "$LOG" 2>&1 &
else
    echo "$(date '+%F %T') STILL DOWN after restart, sending Bark alert" >> "$LOG"
    "$PY" "$OPS_DIR/bark_alert.py" down >> "$LOG" 2>&1
fi
