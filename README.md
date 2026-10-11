# RayDrop 锐传 · iOS（原生，TrollStore 安装）

真原生 iOS App（非 WebView 壳）：收到文件**自动存进「照片」相册**、3 位连接码、局域网 UDP 广播发现 + Tailscale（CF 目录）、信任码自动接收、按顺序单线程传输。

## 出 IPA（TrollStore，免证书）

本工程用 **XcodeGen** 定义项目，靠 GitHub Actions 的 macOS runner 编译。步骤：

1. 新建 GitHub 仓库（建议名 `raydrop-ios`）。
2. 把本目录 `raydrop/ios/` 下的**全部内容**推到该仓库（`.github/`、`scripts/`、`RayDrop/`、`project.yml`）。
   - 注意 `scripts/package-ipa.sh` 需保留（Makefile 里的执行权限在 Windows 上可能丢失，若 CI 报权限错，给它加执行位或改 workflow 用 `bash scripts/package-ipa.sh`，后者已用）。
3. 仓库 → **Actions** → 选 `Build RayDrop iOS IPA (TrollStore)` → **Run workflow**。
4. 构建完成后，在该次运行的 **Artifacts** 下载 `raydrop-ipa`（内含 `raydrop.ipa`）。
5. 用 TrollStore 打开/安装 `raydrop.ipa` 到已越狱/巨魔设备。

> 复用了之前已验证的出包配方：`xcodebuild archive (CODE_SIGNING_ALLOWED=NO)` + `ldid -S` 假签名 + zip 成 IPA。

## 首次使用
- 打开 App，允许「本地网络」权限。
- 记下我的 3 位码；在「信任码」里添加对方 3 位码（对方发来的文件会自动接收并存相册）。
- 对方（安卓/PC）添加我这台设备的 3 位码即可发送；同局域网会 UDP 广播自动发现，Tailscale 用 3 位码经 CF 目录查找。

## 说明
- 存相册用 Photos 框架，**写入无需隐私权限**；读取相册选图用系统 PHPicker（多选）。
- iOS 常规会挂起后台 App，建议**保持 RayDrop 在前台**接收，或用安卓端常驻收。
