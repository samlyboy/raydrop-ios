import Foundation

/// 内嵌的 Tailscale OAuth client 凭据（scope: devices:core:read，只读设备列表）。
/// 构建时由本地文件提供（已 gitignore，不入库）；CI 通过 GitHub Secrets 注入同名文件。
/// ⚠️ 此文件含只读凭据，请勿手动提交到公开仓库。
struct Config {
    static let TS_CLIENT_ID = "ko41LY8K3y11CNTRL"
    static let TS_CLIENT_SECRET = "tskey-client-ko41LY8K3y11CNTRL-bn34FHMbsZAno1ZzcKStZAZ3tu1mdjQK"
}
