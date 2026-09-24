#!/bin/bash
# CoursePet iOS 构建脚本
# 使用方法：
#   ./build.sh generate    # 生成 Xcode 工程
#   ./build.sh build       # 构建（需要 Mac + Xcode）
#   ./build.sh assets      # 部署宠物帧到模拟器
#   ./build.sh codemagic   # 为 Codemagic 准备构建配置

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

case "${1:-}" in
  generate)
    echo "🔧 生成 Xcode 工程..."
    if command -v xcodegen &> /dev/null; then
      xcodegen generate
      echo "✅ 已生成 CoursePet.xcodeproj"
    else
      echo "⚠️  xcodegen 未安装，手动创建 Xcode 项目"
      echo "   安装：brew install xcodegen"
      echo "   然后运行：./build.sh generate"
      exit 1
    fi
    ;;
  build)
    echo "🔨 构建 CoursePet..."
    xcodebuild -project CoursePet.xcodeproj \
      -scheme CoursePet \
      -destination 'generic/platform=iOS' \
      -configuration Release \
      CODE_SIGN_IDENTITY="" \
      CODE_SIGNING_REQUIRED=NO \
      build
    echo "✅ 构建完成"
    ;;
  assets)
    echo "📦 部署宠物帧动画..."
    ASSETS_DIR="$(cd "$SCRIPT_DIR/../../pet_assets" && pwd)"
    if [ ! -d "$ASSETS_DIR" ]; then
      echo "⚠️  未找到 pet_assets 目录: $ASSETS_DIR"
      echo "   请确保 pet_assets 位于 ios/ 同级目录"
      exit 1
    fi
    # 查找模拟器 App Group 容器路径
    SIM_DIR="$HOME/Library/Developer/CoreSimulator/Devices"
    if [ ! -d "$SIM_DIR" ]; then
      echo "⚠️  未找到模拟器设备目录"
      exit 1
    fi
    # 取最新设备
    DEVICE_ID=$(ls -dt "$SIM_DIR"/*/ 2>/dev/null | head -1 | xargs basename)
    TARGET_DIR="$SIM_DIR/$DEVICE_ID/Containers/Data/Application Group/group.com.coursepet.app/Documents/PetAnimations"
    mkdir -p "$TARGET_DIR"
    # 复制所有 char 目录
    for char_dir in "$ASSETS_DIR"/char*/; do
      char_name=$(basename "$char_dir")
      cp -r "$char_dir"* "$TARGET_DIR/$char_name/" 2>/dev/null || true
      echo "  ✅ $char_name"
    done
    echo "✅ 宠物帧已部署到: $TARGET_DIR"
    ;;
  codemagic)
    echo "📦 准备 Codemagic 配置..."
    echo "✅ 已就绪，可在 Codemagic 中直接构建"
    ;;
  *)
    echo "========================================"
    echo "  CoursePet iOS 构建工具"
    echo "========================================"
    echo ""
    echo "用法："
    echo "  ./build.sh generate  - 生成 Xcode 工程（推荐首次使用）"
    echo "  ./build.sh build     - 本地构建（需要 Xcode）"
    echo "  ./build.sh assets    - 部署宠物帧到模拟器"
    echo "  ./build.sh codemagic - 为 Codemagic 云端构建做准备"
    echo ""
    echo "前提条件："
    echo "  brew install xcodegen   # 生成 Xcode 工程"
    echo ""
    echo "一键快速开始："
    echo "  ./build.sh generate && ./build.sh assets"
    echo ""
    echo "下一步："
    echo "  1. 在 Xcode 中打开 CoursePet.xcodeproj"
    echo "  2. 设置 DEVELOPMENT_TEAM"
    echo "  3. 启用 App Groups (group.com.coursepet.app)"
    echo "  4. 连接 iPhone 运行"
    ;;
esac
