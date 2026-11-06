import Foundation
import Network
import Darwin

extension RD {
    /// 去掉发送端为排序加的 "%03d_" 序号前缀（"001_1.apk" → "1.apk"）。
    /// 要求去掉前缀后仍有扩展名，避免把真实以序号命名的文件误判。
    static func stripOrderPrefix(_ name: String) -> String {
        guard name.count > 4, let num = Int(name.prefix(3)), name.hasPrefix(String(format: "%03d_", num)) else { return name }
        let tail = String(name.dropFirst(4))
        if (tail as NSString).pathExtension.isEmpty { return name }
        return tail
    }

    /// 去掉旧版 iOS 发送端在临时文件名前拼的 UUID 前缀
    /// （"D17486E5-ED0D-45CB-8CFB-818ECD6C2A3F-raydrop-v32.ipa" → "raydrop-v32.ipa"）。
    /// 严格要求「36 位标准 UUID + '-'」且去掉后仍有扩展名，正常文件名不会被误伤。
    static func stripUUIDPrefix(_ name: String) -> String {
        guard name.count > 37 else { return name }
        let idx = name.index(name.startIndex, offsetBy: 36)
        guard name[idx] == "-" else { return name }
        let parts = String(name[..<idx]).split(separator: "-").map(String.init)
        guard parts.count == 5, parts.map({ $0.count }) == [8, 4, 4, 4, 12],
              parts.allSatisfy({ $0.allSatisfy { $0.isHexDigit } }) else { return name }
        let tail = String(name[name.index(after: idx)...])
        if (tail as NSString).pathExtension.isEmpty { return name }
        return tail
    }

    // MARK: - ★ 接收目录「下载」：收到即自动落盘，无需任何手动确认
    /// App 沙盒 `Documents/下载`。配合 Info.plist 的 `UIFileSharingEnabled` +
    /// `LSSupportsOpeningDocumentsInPlace`，该目录在系统「文件」App →
    /// 我的 iPhone → RayDrop锐传 → 下载 里直接可见，不必再手动点"存储到文件"。
    static var downloadsDir: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("下载", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    /// 「下载」目录下不重名的落盘路径：同名自动追加 " (2)"、" (3)"…
    static func downloadsURL(named name: String) -> URL {
        let dir = downloadsDir
        let base = sanitize(name)
        let ns = base as NSString
        let stem = ns.deletingPathExtension
        let ext = ns.pathExtension
        var candidate = dir.appendingPathComponent(base)
        var i = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            let n = ext.isEmpty ? "\(stem) (\(i))" : "\(stem) (\(i)).\(ext)"
            candidate = dir.appendingPathComponent(n)
            i += 1
        }
        return candidate
    }

    /// 文件名消毒：对端可构造带路径的文件名（如 `../../x`），必须去掉路径分隔符与开头的点，
    /// 否则会写到「下载」目录之外（目录穿越）。
    static func sanitize(_ name: String) -> String {
        var s = (name as NSString).lastPathComponent
        s = s.replacingOccurrences(of: "/", with: "_")
        s = s.replacingOccurrences(of: "\\", with: "_")
        s = s.replacingOccurrences(of: ":", with: "_")
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasPrefix(".") { s.removeFirst() }
        if s.isEmpty { s = "file" }
        return s
    }

    /// 对端没给扩展名时按 mime 补一个，让「文件」App 能正确预览（补不出则原样返回）
    static func ensureExt(_ name: String, mime: String) -> String {
        if !(name as NSString).pathExtension.isEmpty { return name }
        let e = ext(forMime: mime)
        return e.isEmpty ? name : name + "." + e
    }

    /// ★ 修正"视频只落在「下载」、进不了相册"的第二半：接收端写相册前若发现
    ///   mime 是 application/octet-stream（老版本对端不认识该后缀），用扩展名反推真实 mime，
    ///   让 `RDMediaSaver` 能按视频写入。返回修好的 mime。
    static func correctedMime(name: String, mime: String) -> String {
        let m = mime.lowercased()
        // 已经能判出是媒体类型 → 直接用
        if m.hasPrefix("video/") || m.hasPrefix("image/") { return mime }
        let guessed = RD.mime(for: name)
        // 扩展名推出了媒体类型 → 采用；否则保持原值（如 .zip/.pdf 仍是 octet-stream 也无所谓）
        if guessed.hasPrefix("video/") || guessed.hasPrefix("image/") { return guessed }
        return mime
    }
}

/// IPv4 位运算工具（v47.10 新增）
/// 以前「同网段」只能靠「把 IP 按 . 切开只比前 3 段」实现 —— 那等于默认所有网络都是 /24。
/// 在 /20 这类大网段里（本机 172.28.2.146/20、对端 172.28.13.159）前 3 段不同，
/// 真实到达的包会被判成「非局域网」直接丢掉：电脑能看到手机、手机看不到电脑。
/// 现在一律按真实掩码按位与，广播地址也按掩码算。
enum NetMath {
    static func toUInt32(_ ip: String) -> UInt32? {
        let p = ip.split(separator: ".")
        guard p.count == 4 else { return nil }
        var v: UInt32 = 0
        for s in p {
            guard let b = UInt8(s) else { return nil }
            v = (v << 8) | UInt32(b)
        }
        return v
    }

    static func mask(_ prefix: Int) -> UInt32 {
        if prefix <= 0 { return 0 }
        if prefix >= 32 { return ~UInt32(0) }
        return ~UInt32(0) << UInt32(32 - prefix)
    }

    /// 两个地址是否同子网
    static func sameSubnet(_ a: String, _ b: String, _ prefix: Int) -> Bool {
        guard let x = toUInt32(a), let y = toUInt32(b), prefix > 0, prefix < 32 else { return false }
        let m = mask(prefix)
        return (x & m) == (y & m)
    }

    /// 定向广播地址 = network | ~mask（/20 得 172.28.15.255，而不是 /24 的 172.28.2.255）
    static func broadcastOf(_ ip: String, _ prefix: Int) -> String? {
        guard let v = toUInt32(ip), prefix > 0, prefix < 32 else { return nil }
        let m = mask(prefix)
        let b = (v & m) | ~m
        return "\((b >> 24) & 255).\((b >> 16) & 255).\((b >> 8) & 255).\(b & 255)"
    }
}

/// 枚举本机 IP。**根治"幽灵 IP"**：只上报当前 Wi-Fi 主接口(en0)的局域网地址 + Tailscale(100.x)。
/// iOS 有多个虚拟接口（蜂窝 pdp_ip0、VPN ipsec/utun、点对点 awdl/llw、热点 bridge、隧道 gif/stf），
/// 它们的 IPv4（如蜂窝/VPN 的 10.x）不是当前局域网可达地址——一旦上报给对端，会让对端的
/// 「局域网 IP」在真实地址与幽灵地址间反复跳变，点到幽灵地址就连不通。
enum RDIP {
    /// 一个 IPv4 地址 + 所在接口 + 该接口的前缀长度（/20 → 20）
    struct LanAddr {
        let iface: String
        let ip: String
        let prefix: Int
    }

    /// 枚举所有非 lo0 的 IPv4（带接口名与前缀长度）
    /// ★ v47.10：以前只读 ifa_addr、完全没有掩码概念，这是「手机看不到电脑」的根因
    static func enumerate() -> [LanAddr] {
        var out: [LanAddr] = []
        var addr: UnsafeMutablePointer<ifaddrs>?
        if getifaddrs(&addr) == 0 {
            var p = addr
            while let cur = p {
                let ifa = cur.pointee
                if let sa = ifa.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) {
                    let name = String(cString: ifa.ifa_name)
                    if name != "lo0" {
                        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                        if getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                            out.append(LanAddr(iface: name,
                                               ip: String(cString: host),
                                               prefix: prefixLen(ifa.ifa_netmask)))
                        }
                    }
                }
                p = cur.pointee.ifa_next
            }
            freeifaddrs(addr)
        }
        return out
    }

    /// 从 sockaddr 形式的 netmask 数出前缀长度（255.255.240.0 → 20）。读不到按 24 兜底（宁可保守）
    static func prefixLen(_ sa: UnsafeMutablePointer<sockaddr>?) -> Int {
        guard let sa = sa, sa.pointee.sa_family == UInt8(AF_INET) else { return 24 }
        let sin = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
        var m = UInt32(bigEndian: sin.sin_addr.s_addr)
        var bits = 0
        while bits < 32, (m & 0x8000_0000) != 0 { bits += 1; m <<= 1 }
        return bits == 0 ? 24 : bits
    }

    /// 局域网地址 + 各自前缀（优先 Wi-Fi 主接口 en0，无 en0 时退回非虚拟接口）
    static func lans() -> [LanAddr] {
        let all = enumerate()
        let isLinkLocal = { (ip: String) in ip.hasPrefix("169.254.") }
        var lan = all.filter { $0.iface == "en0" && !isLinkLocal($0.ip) }
        if lan.isEmpty {
            let virtual: Set<String> = ["pdp_ip0","pdp_ip1","pdp_ip2","ipsec0","ipsec1",
                                        "utun0","utun1","utun2","utun3","utun4","utun5",
                                        "awdl0","llw0","gif0","stf0","bridge0","bridge1"]
            lan = all.filter { !virtual.contains($0.iface) && !isLinkLocal($0.ip) && !$0.ip.hasPrefix("100.") }
        }
        var seen = Set<String>(); var out: [LanAddr] = []
        for a in lan where seen.insert(a.ip).inserted { out.append(a) }
        return out
    }

    static func ips() -> [String] {
        var seen = Set<String>(); var out: [String] = []
        for a in enumerate() where a.ip.hasPrefix("100.") {
            if seen.insert(a.ip).inserted { out.append(a.ip) }
        }
        for a in lans() where seen.insert(a.ip).inserted { out.append(a.ip) }
        return out
    }
    static func tailscaleIP() -> String { ips().first(where: { $0.hasPrefix("100.") }) ?? ips().first ?? "" }
}

/// 局域网 UDP 发现：广播 + 单播双通道。
/// iOS 14+ 对「发送 UDP 广播/组播」有系统级限制（需 multicast 权限，未授权时 sendto 直接失败），
/// 所以这里除了 255.255.255.255 广播，还会对已知 IP 逐个发**单播**告知报文 —— 单播不受该限制，
/// 保证对面（尤其安卓）一定能发现本机。
final class RDDiscovery {
    private var sendSock: Int32 = -1
    private var recvSock: Int32 = -1
    private var running = true
    private var started = false
    /// 收到过报文的来源 IP（用于回发单播），120s 内有效
    private var learned: [String: Date] = [:]
    private let lock = NSLock()
    /// 最近一次收到任何 RayDrop 报文的时间（判断接收 socket 是否已"哑掉"）
    private var lastRecv: Date?
    /// 最近一次收到**局域网**（非 100.x）**真对端**报文的时间（决定要不要启用网段扫描兜底）
    private var lastLanPeer: Date?
    /// 回告限速表：同一 IP 最短 2s 才回一次
    private var lastReply: [String: Date] = [:]
    /// 请求重建接收 socket（由 recvLoop 在下次超时时消费）
    private var reopenRequested = false
    /// ★ v47.2：请求**立刻**做一次网段扫描（由 sweepLoop 消费）。
    ///   有些路由器会直接吞掉 UDP 广播，此时只能靠逐个单播把对端敲出来 —— 254 个包约 2s 扫完。
    private var sweepRequested = false
    /// 上层提供的额外单播目标（发现的设备 IP、CF 目录查到的 IP）
    private var extra: [String] = []
    var onDevice: ([String: Any]) -> Void = { _ in }
    /// ★ v42：本机接收服务的**当前实际端口**（由 RDReceiver 动态分配）。
    ///   旧实现公告里写死 RD.tcpPort，于是接收端只能死守 41235 —— 那是 EADDRINUSE 与
    ///   「反复重建」的总根源。现在端口由系统分配，每轮公告把真实端口带出去。
    var portProvider: () -> UInt16 = { 0 }

    func setExtraTargets(_ ips: [String]) { lock.lock(); extra = ips; lock.unlock() }

    func start() {
        // 幂等：重复调用（如回到前台、重建接收服务后）只补发一轮公告，
        // 不再新建 socket —— 否则每调一次就漏一个 fd，久了会收不到包。
        if started {
            announceAll()
            return
        }
        started = true
        running = true
        sendSock = socket(AF_INET, SOCK_DGRAM, 0)
        var yes: Int32 = 1
        setsockopt(sendSock, SOL_SOCKET, SO_BROADCAST, &yes, socklen_t(MemoryLayout<Int32>.size))
        DispatchQueue.global().async { self.broadcastLoop() }
        DispatchQueue.global().async { self.recvLoop() }
        DispatchQueue.global().async { self.sweepLoop() }
    }
    func stop() {
        running = false
        if sendSock >= 0 { close(sendSock); sendSock = -1 }
        // 接收 socket 交给 recvLoop 自己关（避免这里 close 完、loop 里再 close 造成双重关闭）
        reopenRecv()
    }

    private func announcement() -> Data? {
        // ★ v43.2：监听还没就绪（port == 0）时**一个字都不发**。
        //
        //   旧实现无条件把 portProvider() 塞进报文，未就绪时就是 "port": 0。
        //   Windows 端拿这个 0 去 connect()，系统立刻返回
        //   WSAEADDRNOTAVAIL(10049)「在其上下文中，该请求的地址无效」——
        //   表现就是「点设备立刻失败，连超时等待都没有」。
        //   iOS 15 上监听起得慢，这个窗口还更长。
        //
        //   宁可这一轮不公告（对端暂时看不到本机），也绝不广播一个不可连接的端口；
        //   监听一就绪，onListening 回调会立刻补发一轮公告，设备马上重新出现。
        let p = portProvider()
        guard p != 0 else { return nil }
        let me: [String: Any] = [
            "app": RD.app, "v": 2, "name": RDStore.shared.myName,
            "code": RDStore.shared.myCode, "did": RDStore.shared.deviceId,
            "platform": "iOS",
            "port": Int(p), "ips": RDIP.ips()
        ]
        return try? JSONSerialization.data(withJSONObject: me)
    }

    private func targets() -> [String] {
        var out: [String] = []
        lock.lock()
        let now = Date()
        for (ip, t) in learned where now.timeIntervalSince(t) < 120 { out.append(ip) }
        out.append(contentsOf: extra)
        lock.unlock()
        // 去掉自己的地址：往自己身上单播纯属浪费（广播本来就会回环到自己）
        let mine = Set(RDIP.ips())
        var seen = Set<String>()
        return out.filter { !$0.isEmpty && !mine.contains($0) && seen.insert($0).inserted }
    }

    /// 单播告知指定 IP（广播通道不通时的兜底）
    func announceTo(_ ips: [String]) { for ip in ips { send(to: ip) } }

    /// ★ 回告某个来源地址 —— **必须限速**。
    ///   旧实现是"每收到一个报文就无条件回一个"：A 回告 B、B 收到又回告 A、A 再回 B……
    ///   两边在没有任何节流的情况下互相对轰，站口被自己的报文占满，真正的周期公告反而被
    ///   接收缓冲丢掉 → 对端 10s 收不到就判离线、下一包又复现 → **表现就是设备反复掉线上线**。
    ///   现在同一 IP 2s 内只回一次，乒乓必然收敛。
    func reply(to ip: String) {
        guard !ip.isEmpty else { return }
        lock.lock()
        let last = lastReply[ip]
        let allowed = last == nil || Date().timeIntervalSince(last!) >= 2
        if allowed { lastReply[ip] = Date() }
        lock.unlock()
        if allowed { send(to: ip) }
    }

    /// ★ 立刻对全部已知目标发一轮公告（广播 + 已发现 + tailnet 目标）。
    ///   用于「接收服务重建后」和「回到前台」时，让对端马上刷新本机在线状态。
    func announceAll() {
        broadcast()
        for ip in targets() { send(to: ip) }
    }

    /// 广播：受限广播 + 每个局域网网段的**定向广播**。
    /// iOS 上 255.255.255.255 经常被路由器或系统丢掉，定向广播能补上这一路。
    /// ★ v47.10：地址按真实掩码算（network | ~mask）—— 以前硬拼 x.x.x.255 是 /24 假设，
    ///   在 /20 里 172.28.2.255 根本不是广播地址，等于往一个不存在的单播地址发包，白丢。
    private func broadcast() {
        send(to: "255.255.255.255")
        for a in RDIP.lans() {
            if let b = NetMath.broadcastOf(a.ip, a.prefix) { send(to: b) }
        }
    }

    /// 接收 socket 自愈：置标志，让 recvLoop 在下次超时（≤2s）时跳出重建。
    /// 换 Wi-Fi、休眠唤醒、被系统回收后，老 socket 可能一个包都收不到（对端却一切正常）。
    /// （不用 shutdown/close 去打断阻塞：BSD 上不保证能唤醒 recvfrom，还可能双重关闭。）
    private func reopenRecv() {
        lock.lock(); reopenRequested = true; lock.unlock()
    }

    /// 回到前台 / 网络变化后调用：重建接收 socket + 立刻公告一轮
    func resetSockets() {
        reopenRecv()
        announceAll()
    }

    /// ★ v47.2：点名要一次网段扫描（下一个 0.5s 心跳就执行）。
    ///   广播被路由器吞掉、或对端不响应广播时，这是最后手段 —— 254 个单播约 2s 扫完。
    func requestSweep() {
        lock.lock(); sweepRequested = true; lock.unlock()
    }

    private func send(to ip: String) {
        guard sendSock >= 0, let data = announcement() else { return }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = RD.udpPort.bigEndian
        addr.sin_addr.s_addr = inet_addr(ip)
        withUnsafePointer(to: &addr) { a in
            a.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                data.withUnsafeBytes { buf in
                    _ = sendto(sendSock, buf.baseAddress, buf.count, 0, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
    }

    private func broadcastLoop() {
        var tick = 0
        while running {
            broadcast()                              // 受限广播 + 定向广播
            for ip in targets() { send(to: ip) }     // 单播兜底（含跨 Tailscale 的 100.x 探测）

            // 接收侧自愈：有应该在线目标、却 45s 一个包都没收到 → 接收 socket 多半已哑（换网/休眠后常见）
            lock.lock()
            let idle = lastRecv.map { Date().timeIntervalSince($0) } ?? 0
            let hasTargets = !extra.isEmpty || !learned.isEmpty
            lock.unlock()
            if hasTargets && idle > 45 { reopenRecv() }

            tick += 1
            if tick % 300 == 0 {   // 每 10 分钟清一次限速表与过期学习记录，防长期膨胀
                lock.lock()
                let now = Date()
                lastReply = lastReply.filter { now.timeIntervalSince($0.value) < 60 }
                learned = learned.filter { now.timeIntervalSince($0.value) < 600 }
                lock.unlock()
            }
            Thread.sleep(forTimeInterval: 2)         // 2s 一轮公告
        }
    }

    /// 网段扫描（**兜底，默认不跑**）：只有在"局域网里按理该有对端、却 20s 没收到任何局域网报文"时才启用。
    /// 旧实现**无条件每 5s 对 /24 的 1..254 全量单播**：三台设备就是 150+ 包/秒，
    /// 叠加每个包都会诱发对端回告，足以把 Wi-Fi 空口占满 —— 周期公告被挤掉，设备就开始疯狂掉线上线。
    private func sweepLoop() {
        var nextAuto = Date().addingTimeInterval(20)
        while running {
            Thread.sleep(forTimeInterval: 0.5)
            if !running { break }
            lock.lock()
            let wanted = sweepRequested; sweepRequested = false
            let lanIdle = lastLanPeer.map { Date().timeIntervalSince($0) } ?? .greatestFiniteMagnitude
            lock.unlock()
            let due = Date() >= nextAuto
            if !wanted && !due { continue }
            // 自动那一轮只在「一个局域网包都收不到」时才扫；被上层点名要的（面板等不到设备）无条件扫
            if !wanted, lanIdle < 20 { nextAuto = Date().addingTimeInterval(20); continue }
            nextAuto = Date().addingTimeInterval(20)
            var list: [String] = []
            for ip in RDIP.ips() where !ip.hasPrefix("100.") {
                let parts = ip.split(separator: ".")
                guard parts.count == 4 else { continue }
                for h in 1...254 { list.append("\(parts[0]).\(parts[1]).\(parts[2]).\(h)") }
            }
            for ip in list {
                if !running { break }
                send(to: ip)
                usleep(8000)                         // 8ms 一个，避免瞬时打爆
            }
        }
    }

    private func recvLoop() {
        var buf = [UInt8](repeating: 0, count: 2048)
        while running {
            // ★ 每次进来都新建并绑定 socket：被 shutdown/出错后能自动重建
            let fd = socket(AF_INET, SOCK_DGRAM, 0)
            guard fd >= 0 else { Thread.sleep(forTimeInterval: 1); continue }
            var yes: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
            var big: Int32 = 1 << 20                 // 1MB 接收缓冲：扛住突发，避免丢公告
            setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &big, socklen_t(MemoryLayout<Int32>.size))
            // 2s 接收超时：让阻塞的 recvfrom 定期返回，好检查「是否该重建 socket / 是否该退出」。
            // 没有超时的阻塞读会让自愈和优雅退出都做不到。
            var tv = timeval(tv_sec: 2, tv_usec: 0)
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
            var addr = sockaddr_in()
            addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = RD.udpPort.bigEndian
            addr.sin_addr.s_addr = INADDR_ANY.bigEndian
            withUnsafePointer(to: &addr) { a in
                a.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    _ = bind(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            recvSock = fd

            while running {
                var src = sockaddr_in()
                var slen = socklen_t(MemoryLayout<sockaddr_in>.size)
                let n = withUnsafeMutablePointer(to: &src) { p -> Int in
                    p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                        recvfrom(fd, &buf, buf.count, 0, sa, &slen)
                    }
                }
                if n <= 0 {
                    // 区分三种情况：① 收到重建请求 ② 只是 2s 超时（正常）③ 真错误
                    lock.lock(); let want = reopenRequested; reopenRequested = false; lock.unlock()
                    if want { break }
                    if errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR { continue }
                    break                            // 真错误 → 跳出重开
                }
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                _ = withUnsafePointer(to: &src) { p in
                    p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                        getnameinfo(sa, slen, &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
                    }
                }
                let srcIP = String(cString: host)
                lock.lock()
                lastRecv = Date()
                if !srcIP.isEmpty { learned[srcIP] = Date() }
                lock.unlock()
                if let s = String(bytes: buf[0..<n], encoding: .utf8),
                   let data = s.data(using: .utf8),
                   let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let app = obj["app"] as? String, app == RD.app,
                   let code = obj["code"] as? String, code != RDStore.shared.myCode,
                   // ★ 再按设备 UUID 过滤一次自己（防止码不同步时自己出现在列表里）
                   (obj["did"] as? String).map({ $0 != RDStore.shared.deviceId }) ?? true {
                    // 只有"真对端"的局域网报文才算局域网活着（自己广播的回环不算）
                    if !srcIP.isEmpty && !srcIP.hasPrefix("100.") {
                        lock.lock(); lastLanPeer = Date(); lock.unlock()
                    }
                    var o = obj
                    o["srcIP"] = srcIP
                    DispatchQueue.main.async { self.onDevice(o) }
                }
            }
            // 内层退出：关掉本轮 socket，1s 后重建（换网/被系统回收后 socket 会彻底哑掉）
            if recvSock == fd { recvSock = -1 }
            close(fd)
            if running { Thread.sleep(forTimeInterval: 1) }
        }
    }
}

/// TCP 接收端（v42 重写）：**端口交给系统动态分配** + 单会话串行。
///
/// 旧实现把监听端口固定成 41235，随之而来的是一整串无法根治的问题：
/// `cancel()` 只是"请求关闭"，内核要到下一轮事件循环才真正释放端口，于是立刻重绑必撞
/// EADDRINUSE(POSIX 48) → NWListener 停在 .waiting → 巡检看到非 ready 又重建 → 再撞一次。
/// 为了绕过它，代码里陆续加了延迟 0.35s 重绑、A/B 两档参数轮换、0.8s 快重试、8s 启动看门狗、
/// 20s 宽限、20→300s 指数退避…… 近 400 行全在跟"自己跟自己抢端口"搏斗，
/// 而用户看到的就是「一直启动中」「反复重建」「接收服务已自动重连」刷屏。
///
/// v42 改为 `NWListener(using:)` **不指定端口**，由系统分配；ready 后取 `listener.port`
/// 通过 UDP 公告带给对端，对端连这个端口。于是：
///   · 永远不会 EADDRINUSE，重建只是一次新建，毫秒级，不需要任何退避/轮换/看门狗；
///   · 后台被系统挂起 → 回前台重建 → 端口变了 → 立刻公告，对端一个公告周期（2s）内跟上；
///   · 状态只剩「port / busy / current」三个。
final class RDReceiver {
    var onStatus: (String) -> Void = { _ in }
    var onSaved: (String, String, String) -> Void = { _, _, _ in }       // 对端名, 文件名, 落盘路径(「下载」目录内)
    var onStart: (String, Int) -> Void = { _, _ in }                    // 对端名, 文件总数
    var onProgress: (Int, Int, Int64, Int64, Double) -> Void = { _, _, _, _, _ in }
    var onEnd: (Bool, String) -> Void = { _, _ in }
    var onAlbumNote: (String) -> Void = { _ in }
    var onText: (String, String) -> Void = { _, _ in }
    /// 监听就绪（含每次重建）→ 参数是**本次实际端口**，上层据此立刻公告给对端
    var onListening: (UInt16) -> Void = { _ in }

    private let lq = DispatchQueue(label: "raydrop.listener")
    private var listener: NWListener?
    private var port: UInt16 = 0
    /// 同一时刻只服务一个传输会话（并发会让两批数据往「下载」写同名文件互相覆盖）
    private var busy = false
    private var current: RDStream?
    private var aborted = false
    /// 会话序号：给「30 分钟兜底」用，避免误杀后来的新会话
    private var sessionSeq = 0

    /// 当前监听端口（0 = 未就绪）。线程安全。
    var listeningPort: UInt16 { lq.sync { port } }
    /// 监听是否就绪（线程安全）
    var isListening: Bool { lq.sync { port != 0 } }

    func start() { lq.async { self.buildLocked() } }

    /// 不在 ready 就重建。动态端口下重建极便宜，不需要任何退避。
    func ensureUp() {
        lq.async { [weak self] in
            guard let self else { return }
            if let l = self.listener, case .ready = l.state, self.port != 0 { return }
            self.buildLocked()
        }
    }
    /// 兼容旧调用名
    func rebuildIfNeededNow() { ensureUp() }

    func pause() { current?.setPaused(true) }
    func resume() { current?.setPaused(false) }
    func abort() { aborted = true; current?.close(); current = nil }

    /// 建立监听。**只允许在 lq 上调用**。
    private func buildLocked() {
        if let old = listener {
            old.stateUpdateHandler = nil
            old.cancel()
            listener = nil
        }
        port = 0
        do {
            let tcp = NWProtocolTCP.Options()
            tcp.noDelay = true
            let params = NWParameters(tls: nil, tcp: tcp)
            params.allowLocalEndpointReuse = true
            let l = try NWListener(using: params)          // ★ 不指定端口：由系统分配
            l.newConnectionHandler = { [weak self] conn in self?.accept(conn) }
            l.stateUpdateHandler = { [weak self] st in
                guard let self else { return }
                self.lq.async {
                    guard self.listener === l else { return }   // 已被新一轮替换，别乱动
                    switch st {
                    case .ready:
                        let p = l.port?.rawValue ?? 0
                        if p != 0 {
                            self.port = p
                            self.onStatus("接收服务已开启")
                            self.onListening(p)
                        } else {
                            // 极个别情况取不到端口 → 半秒后重建
                            self.lq.asyncAfter(deadline: .now() + 0.5) { self.buildLocked() }
                        }
                    case .failed(let e):
                        self.port = 0
                        self.onStatus("接收服务失败：\(RDReceiver.describe(e))")
                        self.lq.asyncAfter(deadline: .now() + 1.5) { self.buildLocked() }
                    case .waiting(let e):
                        // 动态端口下 waiting 只可能是网络还没就绪（如刚换 Wi-Fi），等系统自愈
                        self.port = 0
                        self.onStatus("接收服务等待网络：\(RDReceiver.describe(e))")
                    default:
                        break
                    }
                }
            }
            listener = l
            l.start(queue: DispatchQueue.global())
        } catch {
            port = 0
            onStatus("接收服务创建失败：\(error.localizedDescription)")
            lq.asyncAfter(deadline: .now() + 2) { self.buildLocked() }
        }
    }

    /// 接受连接：**单会话**。传输进行中的第二个连接直接关掉。
    private func accept(_ conn: NWConnection) {
        lq.async { [weak self] in
            guard let self else { conn.cancel(); return }
            if self.busy { conn.cancel(); return }
            self.busy = true
            self.aborted = false
            conn.start(queue: DispatchQueue.global())
            // 45s：两个数据块之间最长容忍间隔。对端把大视频写相册时它在等 ACK，不读 socket，
            // 但那是**发送端**的 600s 计时；接收端只在真等数据时计时，45s 足够跨过 Wi-Fi 抖动。
            let s = RDStream(conn, stallTimeout: 45)
            self.current = s
            self.sessionSeq += 1
            let sid = self.sessionSeq
            // 会话兜底：30 分钟还没收尾就强制释放（相册保存的 completion 万一不回调，
            // busy 会永久占住 → 之后所有连接都被拒，表现就是「对方一发就被断开」）
            self.lq.asyncAfter(deadline: .now() + 1800) { [weak self] in
                guard let self else { return }
                if self.busy, self.sessionSeq == sid {
                    self.current?.close()
                    self.current = nil
                    self.busy = false
                    self.onStatus("本次会话超时，已释放接收通道")
                }
            }
            Task {
                await self.handle(s)
                self.lq.async {
                    if self.current === s { self.current = nil }
                    // 只在仍是本会话时才解锁（避免旧会话的尾随块误清掉新会话的 busy）
                    if self.sessionSeq == sid { self.busy = false }
                }
            }
        }
    }

    /// NWError 的可读描述（POSIX 码比系统那句 "The operation couldn't be completed" 有用得多）
    private static func describe(_ err: Error) -> String {
        if let nw = err as? NWError {
            switch nw {
            case .posix(let code):
                return "POSIX \(code.rawValue) \(String(cString: strerror(code.rawValue)))"
            case .dns(let code):
                return "DNS \(code)"
            case .tls(let code):
                return "TLS \(code)"
            default:
                break
            }
        }
        return err.localizedDescription
    }

    private func handle(_ s: RDStream) async {
        var total = 0
        var saveFailed = false
        /// 已落「下载」但写相册失败的媒体文件（视频居多）；结束时汇总报出，避免"以为没收到"
        var albumFailed: [String] = []
        defer { s.close() }   // current/busy 的清理统一在 accept 的尾随块里（只在 lq 上改）
        do {
            let hsLine = try await s.readLine()
            guard let hsData = hsLine.data(using: .utf8),
                  let hs = try? JSONSerialization.jsonObject(with: hsData) as? [String: Any] else {
                onStatus("收到无法识别的连接，已忽略")
                return
            }
            var fromName = hs["name"] as? String ?? "对方"
            if fromName.trimmingCharacters(in: .whitespaces).isEmpty { fromName = "对方" }
            let count = hs["count"] as? Int ?? 0

            // 不做信任码校验：使用者都是自己人，一律自动接收并存相册
            RDWrite.line(s.conn, ["ok": true])
            onStatus("\(fromName) 正在发送 \(count) 个文件")
            onStart(fromName, count)
            total = count

            for i in 0..<count {
                let fh = try await s.readLenJSON()
                // 发送端为排序加的 "%03d_" 序号前缀要去掉，接收方文件名与发送端原名保持一致
                let rawName = fh["name"] as? String ?? "file\(i)"
                let size = fh["size"] as? Int ?? 0
                let rawMime = fh["mime"] as? String ?? RD.mime(for: rawName)
                let kind = fh["kind"] as? String ?? "file"
                // 文件名：去排序前缀 → 消毒（防目录穿越）→ 缺扩展名时按 mime 补上（让「文件」App 能预览）
                let name = RD.ensureExt(RD.sanitize(RD.stripUUIDPrefix(RD.stripOrderPrefix(rawName))), mime: rawMime)
                // ★ mime 修正：老版本对端/怪后缀会把视频标成 application/octet-stream，
                //   这里按扩展名反推回 video/*，否则会被当作非媒体 → 只落「下载」不进相册。
                let mime = RD.correctedMime(name: name, mime: rawMime)

                // ★ 长度校验：单文件上限 8GB，且不超过磁盘可用空间。
                //   异常对端可声明超大 size 写满磁盘 —— 这是协议级错误，无法安全跳过
                //   （丢掉多少字节都不可信），直接终止本次会话，避免错位后连锁出错。
                if size < 0 || size > RD.maxFileSize {
                    saveFailed = true
                    onStatus("接收终止：\(name) 声明大小 \(size) 非法")
                    throw RDStream.ReadError.closed
                }
                let free = RD.freeDiskSpace()
                if size > free {
                    saveFailed = true
                    onStatus("接收终止：空间不足，\(name) 需要 \(size / 1048576)MB，可用 \(free / 1048576)MB")
                    throw RDStream.ReadError.closed
                }

                if kind == "text" {
                    // 文本消息：读 size 字节到内存，回调上层弹窗展示（不落盘）
                    var buf = Data(); var left = size
                    while left > 0 { let d = try await s.read(min(left, RD.chunkSize)); buf.append(d); left -= d.count }
                    onText(fromName, String(decoding: buf, as: UTF8.self))
                    RDWrite.line(s.conn, ["ack": i])
                    continue
                }

                if kind == "skip" {
                    // 发送端自己读不了该项（文件已失效）→ 只占位，不落盘、不计失败
                    RDWrite.line(s.conn, ["ack": i])
                    continue
                }

                let isMediaHint = RD.isImageFile(name: name, mime: mime) || RD.isVideoFile(name: name, mime: mime)
                let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("rd_\(UUID().uuidString)")
                FileManager.default.createFile(atPath: tmp.path, contents: nil)
                let handle = try FileHandle(forWritingTo: tmp)

                var lastTick = Date(), lastBytes = 0, spd = 0.0
                try await s.readIntoFile(size, handle) { done in
                    let now = Date()
                    let dt = now.timeIntervalSince(lastTick)
                    if dt >= 0.2 {
                        spd = Double(done - lastBytes) / dt
                        lastTick = now; lastBytes = done
                        self.onProgress(i + 1, total, Int64(done), Int64(size), spd)
                    }
                }
                try? handle.close()

                // ★ v43：落盘前按**文件头魔数**纠正扩展名与 mime。
                //   对端（老版本 RayDrop，或相册里原始文件名怪异的资产）可能把 mov 叫成 .jpeg，
                //   于是这里判成图片 → 写相册走 addResource(.photo) → PhotoKit 报 3302。
                //   只改文件名，不动一个字节。
                var finalName = name
                var finalMime = mime
                if let sniffed = RDMediaSaver.sniffExt(tmp) {
                    let cur = (name as NSString).pathExtension.lowercased()
                    let want = sniffed.lowercased()
                    let sameJPEG = (cur == "jpg" || cur == "jpeg") && (want == "jpg" || want == "jpeg")
                    if cur != want && !sameJPEG {
                        finalName = (name as NSString).deletingPathExtension + "." + want
                        finalMime = RD.mime(for: finalName)
                        onStatus("按真实格式更名：\(name) → \(finalName)")
                    }
                }
                let isMedia = isMediaHint
                    || RD.isImageFile(name: finalName, mime: finalMime)
                    || RD.isVideoFile(name: finalName, mime: finalMime)

                var ack: [String: Any] = ["ack": i]
                // ★ 一律自动落盘到「下载」：先让文件真正归位（这一步不弹任何界面）
                let dst = RD.downloadsURL(named: finalName)
                var saved = false
                do {
                    try FileManager.default.moveItem(at: tmp, to: dst)
                    saved = true
                } catch {
                    // 极端情况（跨卷等）退化为拷贝
                    if (try? FileManager.default.copyItem(at: tmp, to: dst)) != nil {
                        try? FileManager.default.removeItem(at: tmp)
                        saved = true
                    } else {
                        saveFailed = true
                        ack["err"] = "保存到「下载」失败：\(error.localizedDescription)"
                        onStatus("保存失败：\(name)（\(error.localizedDescription)）")
                    }
                }
                if saved && isMedia {
                    // 图片/视频：额外存一份进系统「相册」（「下载」里那份保留，不移动不删除）。
                    // 相册失败只提示、不中断——文件已在「下载」里，发送端显示成功是真实的。
                    let res: (Bool, String) = await withCheckedContinuation { cont in
                        RDMediaSaver.saveExisting(file: dst, name: finalName, mime: finalMime) { ok, err in
                            cont.resume(returning: (ok, err))
                        }
                    }
                    if res.0 {
                        onStatus("已存相册：\(finalName)")
                    } else {
                        // ★ 视频写相册失败是最容易被误认为"没收到"的：文件其实在「下载」里，
                        //   但用户在相册里找不到。必须把原因连文件名一起报出来。
                        let why = res.1.count > 200 ? String(res.1.prefix(200)) + "…" : res.1
                        albumFailed.append("\(finalName)（\(why)）")
                        onStatus("已存「下载」，但写入相册失败：\(finalName)（\(why)）")
                    }
                }
                if saved { onSaved(fromName, finalName, dst.path) }
                RDWrite.line(s.conn, ack)   // 收完才放行下一个
            }
            _ = try? await s.readLine()   // done
            RDWrite.line(s.conn, ["ok": true, "bye": true])
            if !albumFailed.isEmpty {
                // ★ 汇总：文件都在「下载」里（真收到了），只是没进相册。这句必须说清楚，
                //   否则用户看到相册没有视频，会以为传输失败。
                onStatus("接收完成：\(fromName)。\(albumFailed.count) 项已存「下载」但未进相册")
                onAlbumNote(albumFailed.joined(separator: "；"))
            } else {
                onStatus(saveFailed ? "接收结束（部分文件未保存）" : "接收完成：\(fromName)")
            }
            onEnd(!saveFailed, saveFailed ? "部分文件保存失败" : "接收完成")
        } catch {
            if aborted { onStatus("已终止"); onEnd(false, "已终止"); return }
            // ★ 停滞超时：对端断网/走远时收不到任何字节，旧实现会无限等待（界面像卡死）
            if let re = error as? RDStream.ReadError, case .stalled = re {
                onStatus("接收中断：对端长时间没有数据，连接可能已断开")
                onEnd(false, "接收超时")
                return
            }
            // 连接被对端正常关闭（它发完就断了）→ 说清楚是"连接断开"，而不是笼统的"接收中断"
            if total > 0 {
                onStatus("接收中断：连接已断开")
                onEnd(false, "连接已断开")
            } else {
                onStatus("连接已断开（未开始传输）")
                onEnd(false, "连接已断开")
            }
        }
    }
}

/// 发送项：文件(URL) 或 文本(String)
enum SendItem { case file(URL); case text(String) }

/// TCP 发送端：连接 → 握手 → 逐项发(等 ACK，单线程保序) → 结束
/// 支持暂停/继续/终止；ACK 里带 err（对方保存失败）时立刻停止并提示。
final class RDSender {
    var onStatus: (String) -> Void = { _ in }
    var onStart: (String, Int) -> Void = { _, _ in }
    var onProgress: (Int, Int, Int64, Int64, Double) -> Void = { _, _, _, _, _ in }
    var onEnd: (Bool, String) -> Void = { _, _ in }
    private var conn: NWConnection?
    private var paused = false, aborted = false, finished = false

    /// ★ v41：发送权 + 一次性回调保护 + 连接看门狗。
    ///   旧实现没有任何重入保护：用户在「点了没反应」的十几秒里连点几下，
    ///   每一下都会新建一条 NWConnection 并写进**同一个 conn 字段**；
    ///   随后两条 Task 同时用 `conn!` 往同一条连接写 → 长度前缀和数据块互相穿插 →
    ///   接收端解析错位、界面长时间不动，表现就是「不知道点到第几下才突然开始发」。
    private let stateLock = NSLock()
    private var busy = false          // 同一时刻只允许一条发送连接
    private var doneServed = false     // done 只回调一次
    private var reported = false       // onStatus/onEnd 只报一次
    private var connected = false      // 已进入 ready（看门狗据此判定是否超时）
    private var watchDog: DispatchWorkItem?
    /// 连接代际：每起一条新连接 +1。旧 Task 只要发现代际变了就立刻退出，
    /// 否则「终止后马上重发」时，旧 Task 会继续用 `conn!` 往**新连接**里写，把新一批数据写乱。
    private var gen = 0

    var isBusy: Bool { stateLock.lock(); defer { stateLock.unlock() }; return busy }

    func pause() { paused = true }
    func resume() { paused = false }
    /// 终止：递增代际（旧 Task 所有检查点立即失效 + 不释放新一代的状态），然后关连接。
    /// 因为旧 Task 已无法再碰到任何共享状态，这里可以**立刻**放开重发，用户点「终止」后可马上重试。
    func abort() {
        aborted = true; paused = false
        stateLock.lock()
        gen += 1
        busy = false
        watchDog?.cancel()
        stateLock.unlock()
        conn?.cancel()
    }

    /// 本次发送是否仍是「当前连接」（代际匹配且未被收尾）
    private func stillMine(_ g: Int) -> Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return gen == g && !reported
    }

    private func waitIfPaused() async {
        while paused && !aborted { try? await Task.sleep(nanoseconds: 120_000_000) }
    }
    private func releaseBusy() {
        stateLock.lock(); busy = false; watchDog?.cancel(); stateLock.unlock()
    }
    /// done 只回调一次（成功/失败/超时/取消可能同时到达，重复回调会让上层状态互相覆盖）
    private func serveDone(_ done: @escaping (Bool) -> Void, _ ok: Bool) {
        stateLock.lock()
        if doneServed { stateLock.unlock(); return }
        doneServed = true
        stateLock.unlock()
        done(ok)
    }
    /// 收尾（失败/超时/取消）。★ 带代际校验：过期任务一律静默返回 ——
    /// 否则「终止后马上重发」时，旧任务会把新一代的 reported/finished 置脏、把新一代的锁释放掉。
    private func stop(_ why: String, _ done: @escaping (Bool) -> Void, gen g: Int) {
        stateLock.lock()
        if g != gen { stateLock.unlock(); return }
        let first = !reported
        reported = true
        stateLock.unlock()
        finished = true
        releaseBusy()
        if first { onStatus(why); onEnd(false, why) }
        serveDone(done, false)
    }

    func send(host: String, port: UInt16, peerName: String, items: [SendItem], done: @escaping (Bool) -> Void) {
        // ---- 第一道闸：调用层重入拦截（连点几下只会真正起一条连接）----
        stateLock.lock()
        let wasBusy = busy
        if !wasBusy {
            busy = true
            doneServed = false
            reported = false
            connected = false
            aborted = false
            paused = false
            finished = false
            gen += 1
        }
        let myGen = gen
        stateLock.unlock()
        if wasBusy {
            onStatus("上一条还在发送，请稍候…")
            done(false)
            return
        }

        // ★ 发前预校验：逐项确认文件真实可读、大小 > 0。
        //   旧实现把 `try FileHandle(forReadingFrom:)` 放在循环里抛，**任意一项打不开就整批中断** ——
        //   混合发送时若某个视频取不到（临时文件被系统清理/权限问题），后面的项全发不出去，
        //   表现也像"只收到前面几张照片"。这里提前剔除坏项并告知，剩下的照常发。
        var checked: [SendItem] = []
        var skipped: [String] = []
        for it in items {
            switch it {
            case .text(let t):
                if t.isEmpty { continue }
                checked.append(it)
            case .file(let url):
                let fm = FileManager.default
                guard fm.fileExists(atPath: url.path) else { skipped.append(url.lastPathComponent); continue }
                let sz = ((try? fm.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value ?? 0
                guard sz > 0 else { skipped.append(url.lastPathComponent); continue }
                guard fm.isReadableFile(atPath: url.path) else { skipped.append(url.lastPathComponent); continue }
                checked.append(it)
            }
        }
        if !skipped.isEmpty {
            onStatus("有 \(skipped.count) 项无法读取，已跳过：\(skipped.joined(separator: "、"))")
        }
        guard !checked.isEmpty else { stop("没有可发送的内容（文件均已失效）", done, gen: myGen); return }

        // ★ 立刻让界面知道「已开始动作」——在这之前界面要到 TCP 连上并握手成功才有变化，
        //   若对端 App 被挂起、接收服务没起来，SYN 要重传十几秒以上，用户看到的就是「点了没反应」。
        onStatus("正在连接 \(peerName)…")

        let nw = NWEndpoint.Host(host)
        let p = NWEndpoint.Port(rawValue: port)!
        let c = NWConnection(host: nw, port: p, using: .tcp)
        conn = c
        c.stateUpdateHandler = { (st: NWConnection.State) in
            if case .ready = st {
                self.stateLock.lock(); self.connected = true; self.watchDog?.cancel(); self.stateLock.unlock()
                self.doSend(peer: peerName, items: checked, done: done, gen: myGen)
            }
            else if case .failed = st { if self.aborted { self.stop("已终止", done, gen: myGen) } else { self.stop("连接失败", done, gen: myGen) } }
            else if case .cancelled = st { if self.aborted && !self.finished { self.stop("已终止", done, gen: myGen) } }
        }
        c.start(queue: DispatchQueue.global())

        // ★ 12s 连接看门狗：LAN 内正常几十毫秒就 ready，迟迟不 ready 说明对端根本没接
        //   （App 被挂起 / 接收服务没起来）。旧实现靠 TCP 自身超时，最长 75s 界面一动不动，
        //   用户只能反复乱点。现在到点主动给结论，并放开重试。
        let wd = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.stateLock.lock()
            let stillWaiting = !self.connected
            self.stateLock.unlock()
            guard stillWaiting else { return }
            self.stop("连接 \(peerName) 超时（\(host)：对方可能不在线，或接收服务未就绪）", done, gen: myGen)
            self.conn?.cancel()
        }
        stateLock.lock(); watchDog = wd; stateLock.unlock()
        DispatchQueue.global().asyncAfter(deadline: .now() + 12, execute: wd)
    }

    private func doSend(peer: String, items: [SendItem], done: @escaping (Bool) -> Void, gen myGen: Int) {
        // 已被超时/取消收尾的连接，即使迟到 ready 也不再进入发送流程
        guard stillMine(myGen) else { return }
        // ★ 捕获本条连接：`conn` 字段可能被后续 send 覆盖，旧 Task 绝不能写到别人的连接上
        guard let c = conn else { return }
        Task {
            // 发送端等 ACK 时，对面可能正在把大视频写进相册（几 GB 要几十秒）→ 给足 10 分钟
            let s = RDStream(c, stallTimeout: 600)
            do {
                RDWrite.line(c, ["app": RD.app, "v": RD.ver, "name": RDStore.shared.myName,
                                 "code": RDStore.shared.myCode, "count": items.count])
                let repLine = try await s.readLine()
                guard let repData = repLine.data(using: .utf8),
                      let rep = try? JSONSerialization.jsonObject(with: repData) as? [String: Any],
                      (rep["ok"] as? Bool) == true else {
                    let reason = repLine.contains("untrusted") ? "对方未信任你的码" : "被拒绝"
                    self.stop(reason, done, gen: myGen); s.close(); return
                }
                self.onStart(peer, items.count)

                for (i, item) in items.enumerated() {
                    await self.waitIfPaused()
                    guard self.stillMine(myGen) else { s.close(); return }
                    if self.aborted { self.stop("已终止", done, gen: myGen); s.close(); return }
                    var name: String, mime: String, kind: String, size: Int
                    var handle: FileHandle? = nil
                    var textData: Data? = nil
                    switch item {
                    case .file(let url):
                        name = String(format: "%03d_", i + 1) + url.lastPathComponent
                        mime = RD.mime(for: url.lastPathComponent)
                        kind = "file"
                        // ★ 单项打不开不能中断整批（否则"照片发完了、视频和后面的全没了"）。
                        //   发一个 kind=skip 的空条目占位，协议计数保持对齐，接收端跳过不落盘。
                        guard let h = try? FileHandle(forReadingFrom: url),
                              let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
                              let sz64 = (attrs[.size] as? NSNumber)?.int64Value else {
                            self.onStatus("跳过（无法读取）：\(url.lastPathComponent)")
                            RDWrite.lenJSON(c, ["name": name, "size": 0, "mime": mime,
                                                "kind": "skip", "index": i, "total": items.count])
                            _ = try? await s.readLine()      // 等对方 ACK，保持对齐
                            continue
                        }
                        size = Int(sz64)
                        handle = h
                    case .text(let str):
                        name = String(format: "%03d_", i + 1) + "文本消息.txt"
                        mime = "text/plain;charset=utf-8"
                        kind = "text"
                        textData = Data(str.utf8)
                        size = textData!.count
                    }
                    RDWrite.lenJSON(c, ["name": name, "size": size, "mime": mime, "kind": kind, "index": i, "total": items.count])
                    var off = 0, lastTick = Date(), lastB = 0, spd = 0.0
                    var shortRead = false
                    while off < size {
                        await self.waitIfPaused()
                        guard self.stillMine(myGen) else { try? handle?.close(); s.close(); return }
                        if self.aborted { try? handle?.close(); self.stop("已终止", done, gen: myGen); s.close(); return }
                        let want = min(RD.chunkSize, size - off)
                        let chunk: Data
                        if let h = handle { chunk = h.readData(ofLength: want) }
                        else { chunk = textData!.subdata(in: off..<(off + want)) }
                        // ★ 读不到预期字节 = 文件在传输中被截断/删除。旧代码直接 `break`，
                        //   结果「声明了 N 字节、实际发了 M<N 字节」，接收端 readIntoFile 会永远
                        //   阻塞等剩下的字节（它不知道发送端已经放弃）→ 整条传输卡死、后续文件全丢。
                        //   现在必须让错误可见：关连接，让接收端读到 closed 并结束本次接收。
                        if chunk.isEmpty { shortRead = true; break }
                        try await self.sendChunk(chunk, on: c)   // 背压：等这块发完再发下一块
                        off += chunk.count
                        let now = Date(); let dt = now.timeIntervalSince(lastTick)
                        if dt >= 0.2 {
                            spd = Double(off - lastB) / dt
                            lastTick = now; lastB = off
                            self.onProgress(i + 1, items.count, Int64(off), Int64(size), spd)
                        }
                    }
                    try? handle?.close()
                    if shortRead {
                        guard self.stillMine(myGen) else { s.close(); return }
                        self.stop("发送中断：\(name) 只读到 \(off)/\(size) 字节（文件可能被系统清理或损坏）", done, gen: myGen)
                        s.close(); return
                    }
                    let ackLine = try await s.readLine()   // ACK：收完才发下一个
                    if let d = ackLine.data(using: .utf8),
                       let a = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                       let e = a["err"] as? String {
                        // ★ 对方保存失败只跳过这一项，不再整批中断（旧行为会让后续文件全丢）
                        self.onStatus("对方未能保存 \(name)：\(e)")
                        continue
                    }
                    self.onStatus("已发送 \(name)")
                }
                RDWrite.line(c, ["done": true])
                _ = try? await s.readLine()
                self.finished = true
                self.stateLock.lock(); self.reported = true; self.stateLock.unlock()
                self.releaseBusy()
                self.onStatus("发送完成：\(items.count) 项")
                self.onEnd(true, "发送完成")
                self.serveDone(done, true)
            } catch {
                // 代际已变（用户终止后重发/超时收尾）→ 这次 Task 只负责静默退出，不能去改新连接的状态
                guard self.stillMine(myGen) else { s.close(); return }
                if self.aborted { self.stop("已终止", done, gen: myGen) } else { self.stop("发送失败", done, gen: myGen) }
            }
            s.close()
        }
    }

    private func sendChunk(_ d: Data, on c: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            c.send(content: d, completion: .contentProcessed { err in
                if let err = err { cont.resume(throwing: err) } else { cont.resume() }
            })
        }
    }
}
