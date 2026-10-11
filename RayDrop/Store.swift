import Foundation

/// 本地偏好：我的3位码、设备名、信任码集合
final class RDStore {
    static let shared = RDStore()
    private let d = UserDefaults.standard

    var myName: String {
        get { d.string(forKey: "name") ?? (UIDeviceName()) }
        set { d.set(newValue, forKey: "name") }
    }
    var myCode: String {
        get {
            if let c = d.string(forKey: "code"), c.count == 3 { return c }
            let c = String(format: "%03d", Int.random(in: 0..<1000))
            d.set(c, forKey: "code"); return c
        }
        set { d.set(newValue, forKey: "code") }
    }
    private func deviceNameDefault() -> String { "我的iPhone" }

    /// 稳定设备标识（UUID，装一次只生成一次）。
    /// 3 位码允许用户随时改，改完对端就会多出一条；用 did 去重可保证一台设备只显示一条。
    var deviceId: String {
        get {
            if let v = d.string(forKey: "did"), v.count > 8 { return v }
            let v = UUID().uuidString
            d.set(v, forKey: "did"); return v
        }
    }

    var trustedCodes: [String] {
        get { (d.stringArray(forKey: "trusted") ?? []).sorted() }
        set { d.set(newValue, forKey: "trusted") }
    }
    func isTrusted(_ code: String) -> Bool { trustedCodes.contains(code) }
    func trust(_ code: String) { var s = trustedCodes; if !s.contains(code) { s.append(code); trustedCodes = s } }
    func untrust(_ code: String) { trustedCodes = trustedCodes.filter { $0 != code } }
}

private func UIDeviceName() -> String { "我的iPhone" }

/// CF 目录：3位码 ↔ Tailscale IP（仅映射，文件不过服务器）
enum RDDirectory {
    static func register(code: String, name: String, ip: String, port: UInt16) {
        guard let url = URL(string: "\(RD.dirURL)?code=\(code)") else { return }
        var req = URLRequest(url: url); req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["name": name, "ip": ip, "port": Int(port)])
        URLSession.shared.dataTask(with: req).resume()
    }
    struct Peer { let name: String; let ip: String; let port: UInt16 }
    static func lookup(code: String, _ done: @escaping (Peer?) -> Void) {
        guard let url = URL(string: "\(RD.dirURL)?code=\(code)") else { return done(nil) }
        URLSession.shared.dataTask(with: url) { data, _, _ in
            guard let data = data,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let v = obj["value"] as? [String: Any] else { return done(nil) }
            let name = v["name"] as? String ?? "设备"
            let ip = v["ip"] as? String ?? ""
            let port = UInt16((v["port"] as? NSNumber)?.intValue ?? Int(RD.tcpPort))
            DispatchQueue.main.async { done(Peer(name: name, ip: ip, port: port)) }
        }.resume()
    }
}
