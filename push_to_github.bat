@echo off
chcp 65001 >nul
cd /d d:\AI\CoursePet
echo ========================================
echo   CoursePet iOS - 推送代码到 GitHub
echo ========================================
echo.
echo 正在推送 main 分支...
echo.
git push -u origin main
echo.
if %errorlevel% equ 0 (
    echo.
    echo [OK] 推送成功！
    echo 请访问 https://github.com/Zhr65/coursepet-ios 确认
) else (
    echo.
    echo [失败] 推送失败，请检查网络或账号权限
)
pause
