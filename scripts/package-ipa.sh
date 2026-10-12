#!/usr/bin/env bash
set -e
cd "$(dirname "$0")/.."

APP="build/RayDrop.xcarchive/Products/Applications/RayDrop.app"
[ -d "$APP" ] || { echo "RayDrop.app not found at $APP"; exit 1; }

# ---------- 1) 先把分享扩展嵌进 .app 的 PlugIns 目录 ----------
# CI 用独立 scheme 构建 RayDropShare.appex（主 app 的 archive 不会自动带上它）
APP_SHARE=""
for cand in $(find build -type d -name 'RayDropShare.appex' 2>/dev/null); do
  APP_SHARE="$cand"; break
done
if [ -n "$APP_SHARE" ]; then
  mkdir -p "$APP/PlugIns"
  rm -rf "$APP/PlugIns/RayDropShare.appex"
  cp -R "$APP_SHARE" "$APP/PlugIns/"

  # 校验：扩展 Info.plist 必须有 CFBundleExecutable / CFBundleIdentifier，
  # 否则 TrollStore 递归签名时 ldid 报 "Cannot find key CFBundleExecutable"，
  # 整个安装失败并返回 175。这里提前发现并给出明确报错。
  SE_PLIST="$APP/PlugIns/RayDropShare.appex/Info.plist"
  for key in CFBundleExecutable CFBundleIdentifier CFBundlePackageType NSExtension; do
    if ! /usr/libexec/PlistBuddy -c "Print :$key" "$SE_PLIST" >/dev/null 2>&1; then
      echo "ERROR: 分享扩展 Info.plist 缺少必需键 $key —— 会导致 TrollStore 安装失败(175)"
      exit 1
    fi
  done
  EXE=$(/usr/libexec/PlistBuddy -c "Print :CFBundleExecutable" "$SE_PLIST")
  if [ ! -f "$APP/PlugIns/RayDropShare.appex/$EXE" ]; then
    echo "ERROR: 扩展可执行文件不存在：$APP/PlugIns/RayDropShare.appex/$EXE"
    exit 1
  fi
  echo "=== embedded share extension from: $APP_SHARE (exe=$EXE, plist keys OK) ==="
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
