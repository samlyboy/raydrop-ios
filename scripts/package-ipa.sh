#!/usr/bin/env bash
set -e
cd "$(dirname "$0")/.."

APP="build/RayDrop.xcarchive/Products/Applications/RayDrop.app"
[ -d "$APP" ] || { echo "RayDrop.app not found at $APP"; exit 1; }

# 用 ldid 给包内所有 Mach-O 二进制打 fake 签名（免 Apple 证书，TrollStore 装时保留）
# 真机 arm64 包必须经过此步，否则零签名无法安装
find "$APP" -type f -exec sh -c 'file "$1" 2>/dev/null | grep -q "Mach-O" && ldid -S "$1"' _ {} \;

# 主程序额外带上权限（UDP 广播需要 com.apple.developer.networking.multicast）
ENT="RayDrop/RayDrop.entitlements"
if [ -f "$ENT" ] && [ -f "$APP/RayDrop" ]; then
  ldid -S"$ENT" "$APP/RayDrop" && echo "=== entitlements applied ==="
  ldid -e "$APP/RayDrop" | head -20
fi

# 打包成 IPA
rm -rf Payload raydrop.ipa
mkdir -p Payload
cp -R "$APP" Payload/
zip -r raydrop.ipa Payload >/dev/null

echo "=== built: $(du -h raydrop.ipa | cut -f1) ==="
