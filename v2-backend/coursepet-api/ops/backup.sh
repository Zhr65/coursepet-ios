#!/bin/bash
# CoursePet 数据库每日备份（cron 每天 04:00）
#   pg_dump → gzip → /root/coursepet-backups/，保留最近 14 份
# 恢复方法：gunzip -c coursepet-<时间戳>.sql.gz | sudo -u postgres psql coursepet
set -u -o pipefail
BACKUP_DIR=/root/coursepet-backups
KEEP=14
STAMP=$(date +%Y%m%d-%H%M%S)
ERRFILE=/var/tmp/pg_dump_err.txt

mkdir -p "$BACKUP_DIR"
if sudo -u postgres pg_dump coursepet 2>"$ERRFILE" | gzip > "$BACKUP_DIR/coursepet-$STAMP.sql.gz"; then
    SIZE=$(stat -c%s "$BACKUP_DIR/coursepet-$STAMP.sql.gz" 2>/dev/null || echo 0)
    if [ "$SIZE" -lt 500 ]; then
        # 过小 = 大概率空壳 dump，不能算成功
        mv "$BACKUP_DIR/coursepet-$STAMP.sql.gz" "$BACKUP_DIR/coursepet-$STAMP.suspect"
        echo "$(date '+%F %T') FAILED: dump only ${SIZE} bytes, kept as .suspect: $(head -3 "$ERRFILE")" >&2
        exit 1
    fi
    # 只留最近 KEEP 份
    ls -1t "$BACKUP_DIR"/coursepet-*.sql.gz | tail -n +$((KEEP + 1)) | xargs -r rm -f
    echo "$(date '+%F %T') ok: coursepet-$STAMP.sql.gz ($(du -h "$BACKUP_DIR/coursepet-$STAMP.sql.gz" | cut -f1))"
else
    rm -f "$BACKUP_DIR/coursepet-$STAMP.sql.gz"
    echo "$(date '+%F %T') FAILED: $(head -3 "$ERRFILE")" >&2
    exit 1
fi
