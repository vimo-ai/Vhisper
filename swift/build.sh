#!/bin/bash
# Vhisper 构建脚本 - 编译并部署到 /Applications

set -e

cd "$(dirname "$0")"

echo "🔨 编译 vhisper..."
xcodebuild -scheme vhisper -destination 'platform=macOS' build 2>&1 | grep -E "(error:|warning:.*swift|BUILD)" || true

# 查找编译产物
APP_PATH=$(find ~/Library/Developer/Xcode/DerivedData/vhisper-*/Build/Products/Debug -name "vhisper.app" -type d 2>/dev/null | head -1)

if [ -z "$APP_PATH" ]; then
    echo "❌ 找不到编译产物"
    exit 1
fi

echo "📦 复制到 /Applications..."

# 关闭旧进程
pkill -f "vhisper" 2>/dev/null || true
sleep 0.5

# 复制
rm -rf /Applications/vhisper.app
cp -R "$APP_PATH" /Applications/

echo "✅ 部署完成: /Applications/vhisper.app"

# 询问是否启动
read -p "🚀 是否启动? (y/n) " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    open /Applications/vhisper.app
    echo "✅ 已启动"
fi
