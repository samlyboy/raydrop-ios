import Foundation

/// 跨 Tailscale 发现（手机↔手机纯 TS，无需同局域网 / 无需 CF 目录）：
/// 用内嵌的 OAuth client 凭据自动换取 access token，再拉取 tailnet 内所有设备的
/// 100.x 地址，交给 Engine 加入单播探测目标。文件数据始终走 WireGuard 隧道 P2P，不过 Tailscale API。
///
/// 注意：Tailscale v2 devices API 不返回 online 布尔，只有 lastSeen；
/// 离线设备不会回应我们的 UDP 探测，自然不会进列表，故此处直接返回全部非本机 100.x。
final class Tailscale {
    static let shared = Tailscale()
    private var accessToken: String?
    private var tokenExpiry: Date = .distantPast

    private init() {}

    private func token() throws -> String {
        if let t = accessToken, Date().addingTimeInterval(60) < tokenExpiry { return t }
        let basic = Data((Config.TS_CLIENT_ID + ":" + Config.TS_CLIENT_SECRET).utf8).base64EncodedString()
        var req = URLRequest(url: URL(string: "https://api.tailscale.com/api/v2/oauth/token")!)
        req.httpMethod = "POST"
        req.setValue("Basic " + basic, forHTTPHeaderField: "Authorization")
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = "grant_type=client_credentials".data(using: .utf8)
        req.timeoutInterval = 8
        let (data, resp) = try URLSession.shared.rd_syncData(for: req)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tok = obj["access_token"] as? String else {
            throw NSError(domain: "ts", code: 1, userInfo: [NSLocalizedDescriptionKey: "oauth failed rc=\((resp as? HTTPURLResponse)?.statusCode ?? -1)"])
        }
        accessToken = tok
        let exp = (obj["expires_in"] as? NSNumber)?.intValue ?? 3600
        tokenExpiry = Date().addingTimeInterval(TimeInterval(exp))
        return tok
    }

    /// 拉取 tailnet 设备，返回非本机的 100.x 地址列表（探测目标）。
    func peerTSAddresses() -> [String] {
        peerTSDevices().map { $0.ip }
    }

    /// ★ 两层模型 · 第一层「花名册」：tailnet 内全部已知设备（名字 + 100.x），
    /// 无论对方 RayDrop 是否在线都返回，供 UI 常显（离线设备灰显）。
    struct TSDevice { let name: String; let ip: String }
    func peerTSDevices() -> [TSDevice] {
        do {
            let tok = try token()
            var req = URLRequest(url: URL(string: "https://api.tailscale.com/api/v2/tailnet/-/devices")!)
            req.httpMethod = "GET"
            req.setValue("Bearer " + tok, forHTTPHeaderField: "Authorization")
            req.timeoutInterval = 8
            let (data, resp) = try URLSession.shared.rd_syncData(for: req)
            guard let http = resp as? HTTPURLResponse, http.statusCode == 200,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let devs = obj["devices"] as? [[String: Any]] else {
                print("[RayDrop] ts devices failed: \(String(data: data, encoding: .utf8) ?? "")")
                return []
            }
            let selfIPs = Set(RDIP.ips())
            var out: [TSDevice] = []
            for d in devs {
                let name = (d["name"] as? String) ?? "设备"
                guard let addrs = d["addresses"] as? [String] else { continue }
                for ip in addrs where ip.hasPrefix("100.") {
                    if !selfIPs.contains(ip) { out.append(TSDevice(name: name, ip: ip)) }
                }
            }
            return out
        } catch {
            print("[RayDrop] ts refresh failed: \(error.localizedDescription)")
            return []
        }
    }
}

extension URLSession {
    /// 同步请求（简单够用，调用方在后台线程）
    func rd_syncData(for request: URLRequest) throws -> (Data, URLResponse) {
        var result: (Data, URLResponse)?
        var err: Error?
        let sem = DispatchSemaphore(value: 0)
        let task = dataTask(with: request) { data, resp, error in
            if let error = error { err = error }
            else if let data = data, let resp = resp { result = (data, resp) }
            sem.signal()
        }
        task.resume()
        sem.wait()
        if let err = err { throw err }
        guard let result = result else { throw NSError(domain: "ts", code: 2, userInfo: [NSLocalizedDescriptionKey: "no data"]) }
        return result
    }
}
