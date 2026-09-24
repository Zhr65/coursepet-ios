@echo off
chcp 65001 >nul
echo ========================================
echo   CoursePet iOS - 宠物帧动画部署脚本
echo ========================================
echo.

REM 获取 App Group 容器路径
for /f "tokens=2*" %%a in ('reg query "HKCU\Software\Apple Computer, Inc.\Developer\Simulator" /v "ApplicationGroupContainerPath" 2^>nul') do set SIM_PATH=%%b

if not defined SIM_PATH (
    echo [警告] 未找到模拟器 App Group 路径，尝试常见路径...
    set "SIM_PATH=C:\Users\%USERNAME%\Library\Developer\CoreSimulator\Devices"
)

if not defined SIM_PATH (
    echo [错误] 无法找到模拟器路径，请手动设置 SIM_PATH 环境变量。
    pause
    exit /b 1
)

REM 查找最新的模拟器 UDID
for /f "delims=" %%d in ('dir /b /o-d "%SIM_PATH%" 2^>nul') do (
    if exist "%SIM_PATH%\%%d\Containers\Data\Application" (
        set "DEVICE_ID=%%d"
        goto :found_device
    )
)

:found_device
if not defined DEVICE_ID (
    echo [错误] 未找到任何模拟器设备。
    pause
    exit /b 1
)

echo 检测到模拟器设备: %DEVICE_ID%
echo.

REM 复制宠物帧到 App Group
set "SOURCE_DIR=%~dp0..\..\pet_assets"
set "TARGET_DIR=%SIM_PATH%\%DEVICE_ID%\Containers\Data\Application Group\group.com.coursepet.app\Documents\PetAnimations"

echo 源目录: %SOURCE_DIR%
echo 目标目录: %TARGET_DIR%
echo.

if not exist "%SOURCE_DIR%" (
    echo [错误] 源目录不存在: %SOURCE_DIR%
    pause
    exit /b 1
)

REM 创建目标目录
if not exist "%TARGET_DIR%" (
    mkdir "%TARGET_DIR%"
    echo 已创建目录: %TARGET_DIR%
)

REM 复制所有 char 目录
for /d %%c in ("%SOURCE_DIR%\char*") do (
    set "CHAR_NAME=%%~nxc"
    set "CHAR_TARGET=%TARGET_DIR%\%%~nxc"
    if not exist "%CHAR_TARGET%" mkdir "%CHAR_TARGET%"
    xcopy "%%c\*.*" "%CHAR_TARGET\" /Y >nul
    echo 已复制: %CHAR_NAME% -> %CHAR_TARGET%
)

echo.
echo ========================================
echo   部署完成！
echo   App Group 路径: %TARGET_DIR%
echo   请在 Xcode 中重新构建并运行。
echo ========================================
pause
