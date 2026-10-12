#!/usr/bin/env bash
set -e
cd "$(dirname "$0")/.."

APP="build/RayDrop.xcarchive/Products/Applications/RayDrop.app"
[ -d "$APP" ] || { echo "RayDrop.app not found at $APP"; exit 1; }

# ---------- 1) 先把分享扩展嵌进 .app 的 PlugIns 目录 ----------
# xcodegen 的 app-extension target 会被 archive 成独立的 RayDropShare.appex，
# 需要手动拷进宿主 .app/PlugIns/，TrollStore 安装时才会认这个分享扩展。
APP_SHARE="$(find build -type d -name 'RayDropShare.appex' 2>/dev/null | head -1)"
if [ -n "$APP_SHARE" ]; then
  mkdir -p "$APP/PlugIns"
  rm -rf "$APP/PlugIns/RayDropShare.appex"
  cp -R "$APP_SHARE" "$APP/PlugIns/"
  echo "=== embedded share extension: $APP_SHARE ==="
else
  echo "WARN: RayDropShare.appex not found — 分享扩展不会被包含"
fi

# ---------- 2) 用 ldid 给包内所有 Mach-O 二进制打 fake 签名（免 Apple 证书，TrollStore 装时保留）----------
find "$APP" -type f -exec sh -c 'file "$1" 2>/dev/null | grep -q "Mach-O" && ldid -S "$1"' _ {} \;

# ---------- 3) 主程序与扩展各自带上对应权限 ----------
# 主程序：UDP 广播 multicast + App Group + 后台保活
ENT="RayDrop/RayDrop.entitlements"
if [ -f "$ENT" ] && [ -f "$APP/RayDrop" ]; then
  ldid -S"$ENT" "$APP/RayDrop" && echo "=== main entitlements applied ==="
  ldid -e "$APP/RayDrop" | head -20
fi

# 分享扩展：App Group（与主程序共享 inbox 目录）
SENT="ShareExtension/RayDropShare.entitlements"
if [ -f "$SENT" ] && [ -f "$APP/PlugIns/RayDropShare.appex/RayDropShare" ]; then
  ldid -S"$SENT" "$APP/PlugIns/RayDropShare.appex/RayDropShare" && echo "=== share ext entitlements applied ==="
  ldid -e "$APP/PlugIns/RayDropShare.appex/RayDropShare" | head -20
fi

# ---------- 4) 打包成 IPA ----------
rm -rf Payload raydrop.ipa
mkdir -p Payload
cp -R "$APP" Payload/
zip -r raydrop.ipa Payload >/dev/null

echo "=== built: $(du -h raydrop.ipa | cut -f1) ==="
echo "=== PlugIns: $(ls "$APP/PlugIns" 2>/dev/null || echo none) ==="
