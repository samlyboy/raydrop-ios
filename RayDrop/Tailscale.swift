import Foundation

/// 跨 Tailscale 发现（手机↔手机纯 TS，无需同局域网 / 无需 CF 目录）：
/// ★ v47.18 起改为**固定网段直探**：tailnet 的 IPv4 固定为 100.88.88.1-255，
///   直接把这 255 个地址作为单播探测目标，不再调 Tailscale OAuth API 拉花名册。
///   好处：零密钥（仓库可公开）、零网络请求、零额度消耗；对端只要连着 TS 且开着 RayDrop，
///   就会回 announce 报文，走正常发现流程上线。
///
///   文件数据始终走 WireGuard 隧道 P2P，不经过任何 Tailscale API。
final class Tailscale {
    static let shared = Tailscale()
    private init() {}

    /// 固定 tailnet 网段前缀与范围（含首尾）
    static let netPrefix = "100.88.88."
    static let netFirst = 1
    static let netLast = 255

    /// 构造整个固定网段地址（不含本机自己的 100.x）
    private static func allPeers() -> [String] {
        let selfIPs = Set(RDIP.ips())
        return (netFirst...netLast).map { netPrefix + String($0) }
            .filter { !selfIPs.contains($0) }
    }

    /// 单播探测目标：全部固定网段地址（排除本机）
    func peerTSAddresses() -> [String] { Self.allPeers() }

    /// 兼容层：UI 用的设备结构。固定网段模式下没有真实花名册，
    /// 因此 name 用 IP、lastSeen 用「现在」表示一律纳入在线筛选；
    /// 真正在线判定仍靠「UDP 探测收到回告」(tsAlive)，不靠这里。
    struct TSDevice {
        let name: String
        let ip: String
        let lastSeen: Date?
    }
    static let onlineWindow: TimeInterval = 300
    func peerTSDevices() -> [TSDevice] {
        let now = Date()
        return Self.allPeers().map { TSDevice(name: $0, ip: $0, lastSeen: now) }
    }
}
