#!/usr/bin/env bash
# CoursePet V2 后端启动脚本
# 用法：./run.sh  （开发模式：--reload 监听代码变化）
cd "$(dirname "$0")"
exec ~/coursepet-env/bin/uvicorn app.main:app \
    --host 0.0.0.0 --port 8000 \
    --reload
