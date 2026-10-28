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

/// 枚举本机 IP。**根治"幽灵 IP"**：只上报当前 Wi-Fi 主接口(en0)的局域网地址 + Tailscale(100.x)。
/// iOS 有多个虚拟接口（蜂窝 pdp_ip0、VPN ipsec/utun、点对点 awdl/llw、热点 bridge、隧道 gif/stf），
/// 它们的 IPv4（如蜂窝/VPN 的 10.x）不是当前局域网可达地址——一旦上报给对端，会让对端的
/// 「局域网 IP」在真实地址与幽灵地址间反复跳变，点到幽灵地址就连不通。
enum RDIP {
    static func ips() -> [String] {
        // 先收集所有非 lo0 的 IPv4：(接口名, IP)
        var all: [(String, String)] = []
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
                            all.append((name, String(cString: host)))
                        }
                    }
                }
                p = cur.pointee.ifa_next
            }
            freeifaddrs(addr)
        }
        let isLinkLocal = { (ip: String) in ip.hasPrefix("169.254.") }
        // Tailscale：任何接口的 100.x 都保留（单列一组）
        var ts = all.filter { $0.1.hasPrefix("100.") }.map { $0.1 }
        // 局域网：优先 Wi-Fi 主接口 en0 的 IPv4（最权威、一定与对端同网段）
        var lan = all.filter { $0.0 == "en0" && !isLinkLocal($0.1) }.map { $0.1 }
        // 没有 en0（未连 Wi-Fi）时，退回"排除已知虚拟接口后的其它 IPv4"（如纯蜂窝/热点场景）
        if lan.isEmpty {
            let virtual: Set<String> = ["pdp_ip0","pdp_ip1","pdp_ip2","ipsec0","ipsec1",
                                        "utun0","utun1","utun2","utun3","utun4","utun5",
                                        "awdl0","llw0","gif0","stf0","bridge0","bridge1"]
            lan = all.filter { !virtual.contains($0.0) && !isLinkLocal($0.1) && !$0.1.hasPrefix("100.") }.map { $0.1 }
        }
        var seen = Set<String>(); var out: [String] = []
        for ip in ts  where seen.insert(ip).inserted { out.append(ip) }
        for ip in lan where seen.insert(ip).inserted { out.append(ip) }
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
    /// 上层提供的额外单播目标（发现的设备 IP、CF 目录查到的 IP）
    private var extra: [String] = []
    var onDevice: ([String: Any]) -> Void = { _ in }

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
        let me: [String: Any] = [
            "app": RD.app, "v": 2, "name": RDStore.shared.myName,
            "code": RDStore.shared.myCode, "did": RDStore.shared.deviceId,
            "platform": "iOS",
            "port": Int(RD.tcpPort), "ips": RDIP.ips()
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

    /// 广播：受限广播 + 每个局域网网段的定向广播（x.x.x.255）。
    /// iOS 上 255.255.255.255 经常被路由器或系统丢掉，定向广播能补上这一路。
    private func broadcast() {
        send(to: "255.255.255.255")
        for ip in RDIP.ips() where !ip.hasPrefix("100.") {
            let p = ip.split(separator: ".")
            if p.count == 4 { send(to: "\(p[0]).\(p[1]).\(p[2]).255") }
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
        while running {
            Thread.sleep(forTimeInterval: 20)
            if !running { break }
            lock.lock()
            let lanIdle = lastLanPeer.map { Date().timeIntervalSince($0) } ?? .greatestFiniteMagnitude
            lock.unlock()
            if lanIdle < 20 { continue }             // 还能收到局域网报文 → 不需要扫
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

/// TCP 接收端：握手 → 逐文件收 → **全自动落盘到「下载」文件夹** → 图片/视频再另存一份相册 → ACK（单线程保序）
/// 收到即存，**无需任何手动确认**（不再弹"存储到文件"）。只有写「下载」失败才回 err；
/// 相册保存失败仅提示、不中断传输——因为文件已经实实在在落在「下载」里了。
final class RDReceiver {
    var onStatus: (String) -> Void = { _ in }
    var onSaved: (String, String, String) -> Void = { _, _, _ in }       // 对端名, 文件名, 落盘路径(「下载」目录内)
    var onStart: (String, Int) -> Void = { _, _ in }                    // 对端名, 文件总数
    var onProgress: (Int, Int, Int64, Int64, Double) -> Void = { _, _, _, _, _ in }  // 第几个(1起), 总数, 已收字节, 文件总大小, 字节/秒
    var onEnd: (Bool, String) -> Void = { _, _ in }
    /// 有媒体文件已落「下载」但没进相册时回调（参数为汇总说明），供上层写日志提醒
    var onAlbumNote: (String) -> Void = { _ in }
    var onText: (String, String) -> Void = { _, _ in }                       // 收到文本消息(来自, 文本)
    private var listener: NWListener?
    private var current: RDStream?
    private var aborted = false;   // 用户点「终止」→ 与意外中断区分提示
    /// ★ 监听状态必须串行化：state handler 在后台队列回调，巡检在主线程调用。
    ///   旧实现两边各自读写 `isListening` 这个裸 Bool，既有数据竞争，又无法做「宽限 / 退避」——
    ///   于是每 5s 见到非 ready 就推倒重建一次，日志被「已自动重建」刷屏（见 v37 修复）。
    private let lq = DispatchQueue(label: "raydrop.listener")
    private var ready = false                 // 仅在 lq 上读写
    private var lastRebuildAt = Date.distantPast
    private var rebuildAttempts = 0
    /// 监听是否就绪（线程安全读）
    var isListening: Bool { lq.sync { ready } }
    /// 监听就绪（含重建成功）后回调：让上层立刻重新公告，对端随即刷新本机在线状态
    var onListening: () -> Void = { }

    func start() {
        aborted = false
        lq.sync { beginListeningLocked() }
    }

    /// 建立（或重建）监听。**只允许在 lq 上调用**：先废弃旧监听再新建，避免端口占用。
    private func beginListeningLocked() {
        listener?.stateUpdateHandler = nil
        listener?.cancel()
        listener = nil
        ready = false
        lastRebuildAt = Date()
        do {
            // ★ 关键：必须允许复用本地端口。
            //   iOS 把 App 挂起 / 抢占后，旧监听的内核 socket 可能还占着 41235，
            //   不允许复用时新监听会一直停在 .waiting(POSIX 48 EADDRINUSE)，
            //   永远到不了 .ready → 巡检又判定"没就绪"→ 再重建 → 无限空转、日志刷屏。
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            params.noDelay = true
            let l = try NWListener(using: params, on: NWEndpoint.Port(rawValue: RD.tcpPort)!)
            l.newConnectionHandler = { (conn: NWConnection) in
                conn.start(queue: DispatchQueue.global())
                let stream = RDStream(conn)
                self.current = stream
                Task { await self.handle(stream) }
            }
            l.stateUpdateHandler = { [weak self] st in
                guard let self else { return }
                self.lq.async {
                    switch st {
                    case .ready:
                        self.ready = true
                        self.rebuildAttempts = 0
                        self.onStatus("接收服务已开启")
                        // 就绪即公告一轮（含首次启动与每次重建）：让对端立刻刷新本机在线状态。
                        // 是否写日志由上层判断（只在「掉线→恢复」时写一条），这里不产生噪音。
                        self.onListening()
                    case .failed:
                        // failed 是终态，NWListener 不会自行恢复 → 允许下一轮巡检立刻重建
                        self.ready = false
                        self.lastRebuildAt = .distantPast
                    case .waiting, .cancelled:
                        // ★ waiting 是**可恢复**状态（换网、休眠唤醒、端口瞬时占用）：
                        //   网络回来时 NWListener 会自己回到 ready。旧实现把它当失效立刻重建，
                        //   正是"明明一直在收、却反复重建刷屏"的根源。此处只标记不就绪，交给系统。
                        self.ready = false
                    default:
                        break
                    }
                }
            }
            l.start(queue: DispatchQueue.global())
            listener = l
        } catch {
            onStatus("接收端口错误: \(error.localizedDescription)")
        }
    }

    /// 监听当前是否真的 ready（以 NWListener.state 为权威值，仅在 lq 上调用）。
    /// 不用 `==` 比较：NWListener.State 带关联值，用模式匹配最稳。
    private var listenerReady: Bool {
        guard let l = listener else { return false }
        if case .ready = l.state { return true }
        return false
    }

    /// 回到前台时调用：不在 ready 就立刻重建一次（前台重建不算失败重试，重置退避）。
    /// 后台挂起后监听常停在 waiting，靠系统自愈可能要等十几秒；前台是「马上就要能收」的时刻，
    /// 所以这里主动重建一次。但限速 3s，避免 scenePhase 短时间抖动导致连续重建。
    func rebuildIfNeededNow() {
        lq.sync {
            if listenerReady { ready = true; return }
            if Date().timeIntervalSince(lastRebuildAt) < 3 { return }
            beginListeningLocked()
            rebuildAttempts = 0
        }
    }

    /// ★ 巡检自愈。返回 true 表示本次确实重建了一次监听。
    ///   修 v36 的两个错误：
    ///   ① `waiting` 被当成失效 → 立刻重建。但 waiting 是系统会自动恢复的状态，
    ///      重建反而把正在恢复的监听打断，于是永远卡在 waiting、每 5s 重建一次。
    ///   ② 没有退避。连续重建失败会以 5s 频率无限重试，白耗电还把日志刷满。
    ///   现在：waiting 先给 20s 自愈宽限；真正重建按 20→40→80→160s 递增退避，最长 5 分钟一次。
    @discardableResult
    func ensureListening() -> Bool {
        var did = false
        lq.sync {
            // ★ 以 NWListener.state 为准（它是权威值），避免回调丢失 / 读写竞争导致「明明 ready 却判定不就绪」，
            //   否则就会每 5s 把正常工作的监听推倒重建一次。
            if listenerReady { ready = true; return }
            if ready { return }
            let now = Date()
            let sinceRebuild = now.timeIntervalSince(lastRebuildAt)
            // 刚建的监听还在建立 / 等系统恢复：给 20s 宽限，别推倒重来
            if sinceRebuild < 20 { return }
            // 连续重建失败 → 指数退避，最多 5 分钟一次，避免空转耗电
            let cap = min(300.0, 20.0 * pow(2.0, Double(max(0, rebuildAttempts - 1))))
            if rebuildAttempts > 0 && sinceRebuild < cap { return }
            beginListeningLocked()
            rebuildAttempts += 1
            did = true
        }
        return did
    }

    func pause() { current?.setPaused(true) }
    func resume() { current?.setPaused(false) }
    func abort() { aborted = true; current?.close(); current = nil }

    private func handle(_ s: RDStream) async {
        var total = 0
        var saveFailed = false
        /// 已落「下载」但写相册失败的媒体文件（视频居多）；结束时汇总报出，避免"以为没收到"
        var albumFailed: [String] = []
        defer { s.close(); if current === s { current = nil } }
        do {
            let hsLine = try await s.readLine()
            guard let hsData = hsLine.data(using: .utf8),
                  let hs = try? JSONSerialization.jsonObject(with: hsData) as? [String: Any] else { return }
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

                let isMedia = RD.isImageFile(name: name, mime: mime) || RD.isVideoFile(name: name, mime: mime)
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

                var ack: [String: Any] = ["ack": i]
                // ★ 一律自动落盘到「下载」：先让文件真正归位（这一步不弹任何界面）
                let dst = RD.downloadsURL(named: name)
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
                        RDMediaSaver.saveExisting(file: dst, name: name, mime: mime) { ok, err in
                            cont.resume(returning: (ok, err))
                        }
                    }
                    if res.0 {
                        onStatus("已存相册：\(name)")
                    } else {
                        // ★ 视频写相册失败是最容易被误认为"没收到"的：文件其实在「下载」里，
                        //   但用户在相册里找不到。必须把原因连文件名一起报出来，别只说"写入相册失败"。
                        //   多策略兜底后原因可能较长，日志里截断，完整原因靠第一步的 NSError 即可定位。
                        let why = res.1.count > 140 ? String(res.1.prefix(140)) + "…" : res.1
                        albumFailed.append("\(name)（\(why)）")
                        onStatus("已存「下载」，但写入相册失败：\(name)（\(why)）")
                    }
                }
                if saved { onSaved(fromName, name, dst.path) }
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
            onStatus("接收中断"); onEnd(false, "接收中断")
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

    func pause() { paused = true }
    func resume() { paused = false }
    func abort() { aborted = true; paused = false; conn?.cancel() }

    private func waitIfPaused() async {
        while paused && !aborted { try? await Task.sleep(nanoseconds: 120_000_000) }
    }
    private func stop(_ why: String, _ done: @escaping (Bool) -> Void) {
        finished = true
        onStatus(why); onEnd(false, why); done(false)
    }

    func send(host: String, port: UInt16, peerName: String, items: [SendItem], done: @escaping (Bool) -> Void) {
        aborted = false; paused = false; finished = false

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
        guard !checked.isEmpty else { stop("没有可发送的内容（文件均已失效）", done); return }

        let nw = NWEndpoint.Host(host)
        let p = NWEndpoint.Port(rawValue: port)!
        let c = NWConnection(host: nw, port: p, using: .tcp)
        conn = c
        c.stateUpdateHandler = { (st: NWConnection.State) in
            if case .ready = st { self.doSend(peer: peerName, items: checked, done: done) }
            else if case .failed = st { if self.aborted { self.stop("已终止", done) } else { self.stop("连接失败", done) } }
            else if case .cancelled = st { if self.aborted && !self.finished { self.stop("已终止", done) } }
        }
        c.start(queue: DispatchQueue.global())
    }

    private func doSend(peer: String, items: [SendItem], done: @escaping (Bool) -> Void) {
        Task {
            // 发送端等 ACK 时，对面可能正在把大视频写进相册（几 GB 要几十秒）→ 给足 10 分钟
            let s = RDStream(conn!, stallTimeout: 600)
            do {
                RDWrite.line(conn!, ["app": RD.app, "v": RD.ver, "name": RDStore.shared.myName,
                                      "code": RDStore.shared.myCode, "count": items.count])
                let repLine = try await s.readLine()
                guard let repData = repLine.data(using: .utf8),
                      let rep = try? JSONSerialization.jsonObject(with: repData) as? [String: Any],
                      (rep["ok"] as? Bool) == true else {
                    let reason = repLine.contains("untrusted") ? "对方未信任你的码" : "被拒绝"
                    self.stop(reason, done); s.close(); return
                }
                self.onStart(peer, items.count)

                for (i, item) in items.enumerated() {
                    await self.waitIfPaused()
                    if self.aborted { self.stop("已终止", done); s.close(); return }
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
                            RDWrite.lenJSON(conn!, ["name": name, "size": 0, "mime": mime,
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
                    RDWrite.lenJSON(conn!, ["name": name, "size": size, "mime": mime, "kind": kind, "index": i, "total": items.count])
                    var off = 0, lastTick = Date(), lastB = 0, spd = 0.0
                    var shortRead = false
                    while off < size {
                        await self.waitIfPaused()
                        if self.aborted { try? handle?.close(); self.stop("已终止", done); s.close(); return }
                        let want = min(RD.chunkSize, size - off)
                        let chunk: Data
                        if let h = handle { chunk = h.readData(ofLength: want) }
                        else { chunk = textData!.subdata(in: off..<(off + want)) }
                        // ★ 读不到预期字节 = 文件在传输中被截断/删除。旧代码直接 `break`，
                        //   结果「声明了 N 字节、实际发了 M<N 字节」，接收端 readIntoFile 会永远
                        //   阻塞等剩下的字节（它不知道发送端已经放弃）→ 整条传输卡死、后续文件全丢。
                        //   现在必须让错误可见：关连接，让接收端读到 closed 并结束本次接收。
                        if chunk.isEmpty { shortRead = true; break }
                        try await self.sendChunk(chunk)   // 背压：等这块发完再发下一块
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
                        self.stop("发送中断：\(name) 只读到 \(off)/\(size) 字节（文件可能被系统清理或损坏）", done)
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
                RDWrite.line(conn!, ["done": true])
                _ = try? await s.readLine()
                self.finished = true
                self.onStatus("发送完成：\(items.count) 项")
                self.onEnd(true, "发送完成")
                done(true)
            } catch {
                if self.aborted { self.stop("已终止", done) } else { self.stop("发送失败", done) }
            }
            s.close()
        }
    }

    private func sendChunk(_ d: Data) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            conn!.send(content: d, completion: .contentProcessed { err in
                if let err = err { cont.resume(throwing: err) } else { cont.resume() }
            })
        }
    }
}
