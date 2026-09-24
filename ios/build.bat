@echo off
chcp 65001 >nul
rem CoursePet iOS 构建脚本（Windows）
rem 使用方法：
rem   build.bat         - 一键生成 + 部署宠物帧
rem   build.bat generate - 仅生成 Xcode 工程
rem   build.bat assets  - 仅部署宠物帧到模拟器
rem   build.bat codemagic - 为 Codemagic 准备构建配置

set SCRIPT_DIR=%~dp0
cd /d "%SCRIPT_DIR%"

if "%~1"=="generate" (
    echo 🔧 生成 Xcode 工程...
    where xcodegen >nul 2>&1
    if %errorlevel% equ 0 (
        xcodegen generate
        echo ✅ 已生成 CoursePet.xcodeproj
    ) else (
        echo ⚠️  xcodegen 未安装，手动创建 Xcode 项目
        echo    安装：brew install xcodegen
        echo    然后运行：build.bat generate
        exit /b 1
    )
) else if "%~1"=="assets" (
    goto :setup_assets
) else if "%~1"=="codemagic" (
    echo 📦 准备 Codemagic 配置...
    echo ✅ 已就绪，可在 Codemagic 中直接构建
) else (
    echo ========================================
    echo   CoursePet iOS 构建工具
    echo ========================================
    echo.
    echo [1/2] 生成 Xcode 工程...
    where xcodegen >nul 2>&1
    if %errorlevel% equ 0 (
        xcodegen generate
        echo ✅ 已生成 CoursePet.xcodeproj
    ) else (
        echo ⚠️  xcodegen 未安装，请手动在 Xcode 中创建项目
        echo    brew install xcodegen
    )
    echo.
    echo [2/2] 部署宠物帧动画...
    call "%SCRIPT_DIR%setup_pet_assets.bat"
    echo.
    echo ========================================
    echo   完成！下一步：
    echo     1. 用 Xcode 打开 CoursePet.xcodeproj
    echo     2. 设置 DEVELOPMENT_TEAM（你的 Apple ID Team ID）
    echo     3. 确保 Capabilities → App Groups 启用 group.com.coursepet.app
    echo     4. 连接到 iPhone 运行
    echo ========================================
    pause
    exit /b 0
)

goto :eof

:setup_assets
echo ========================================
echo   部署宠物帧动画到模拟器
echo ========================================
call "%SCRIPT_DIR%setup_pet_assets.bat"
exit /b 0
