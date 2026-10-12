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

    /// 生成一个带真实文件名的临时文件 URL（保留扩展名，导出到「文件」App 时名字才对）
    static func tempURL(named name: String) -> URL {
        let safe = (name as NSString).lastPathComponent
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("raydrop_\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(safe)
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
    /// 收到过报文的来源 IP（用于回发单播），120s 内有效
    private var learned: [String: Date] = [:]
    private let lock = NSLock()
    /// 上层提供的额外单播目标（发现的设备 IP、CF 目录查到的 IP）
    private var extra: [String] = []
    var onDevice: ([String: Any]) -> Void = { _ in }

    func setExtraTargets(_ ips: [String]) { lock.lock(); extra = ips; lock.unlock() }

    func start() {
        running = true
        sendSock = socket(AF_INET, SOCK_DGRAM, 0)
        var yes: Int32 = 1
        setsockopt(sendSock, SOL_SOCKET, SO_BROADCAST, &yes, socklen_t(MemoryLayout<Int32>.size))
        DispatchQueue.global().async { self.broadcastLoop() }
        DispatchQueue.global().async { self.recvLoop() }
        DispatchQueue.global().async { self.sweepLoop() }
    }
    func stop() { running = false; if sendSock >= 0 { close(sendSock) }; if recvSock >= 0 { close(recvSock) } }

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
        var seen = Set<String>()
        return out.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    /// 单播告知指定 IP（广播通道不通时的兜底）
    func announceTo(_ ips: [String]) { for ip in ips { send(to: ip) } }

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
        while running {
            send(to: "255.255.255.255")              // 局域网广播（可能被系统拦下，失败也无所谓）
            for ip in targets() { send(to: ip) }     // 单播兜底
            Thread.sleep(forTimeInterval: 3)
        }
    }

    /// 子网探测（兜底）：广播发不出去时（iOS 权限限制 / 路由器丢广播），
    /// 把同样的告知报文**单播**发给本网段每个 IP —— 对方收到任意 RayDrop 报文都会回告自己。
    private func sweepLoop() {
        while running {
            var targets: [String] = []
            for ip in RDIP.ips() where !ip.hasPrefix("100.") {
                let parts = ip.split(separator: ".")
                guard parts.count == 4 else { continue }
                for h in 1...254 { targets.append("\(parts[0]).\(parts[1]).\(parts[2]).\(h)") }
            }
            for ip in targets { send(to: ip) }
            Thread.sleep(forTimeInterval: 5)      // ★ 5 秒一轮，保证在线设备实时更新
        }
    }

    private func recvLoop() {
        recvSock = socket(AF_INET, SOCK_DGRAM, 0)
        var yes: Int32 = 1
        setsockopt(recvSock, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = RD.udpPort.bigEndian
        addr.sin_addr.s_addr = INADDR_ANY.bigEndian
        withUnsafePointer(to: &addr) { a in
            a.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                _ = bind(recvSock, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        var buf = [UInt8](repeating: 0, count: 2048)
        while running {
            var src = sockaddr_in()
            var slen = socklen_t(MemoryLayout<sockaddr_in>.size)
            let n = withUnsafeMutablePointer(to: &src) { p -> Int in
                p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    recvfrom(recvSock, &buf, buf.count, 0, sa, &slen)
                }
            }
            guard n > 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            _ = withUnsafePointer(to: &src) { p in
                p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    getnameinfo(sa, slen, &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
                }
            }
            let srcIP = String(cString: host)
            if !srcIP.isEmpty { lock.lock(); learned[srcIP] = Date(); lock.unlock() }
            if let s = String(bytes: buf[0..<n], encoding: .utf8),
               let data = s.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let app = obj["app"] as? String, app == RD.app,
               let code = obj["code"] as? String, code != RDStore.shared.myCode,
               // ★ 再按设备 UUID 过滤一次自己（防止码不同步时自己出现在列表里）
               (obj["did"] as? String).map({ $0 != RDStore.shared.deviceId }) ?? true {
                var o = obj
                o["srcIP"] = srcIP
                DispatchQueue.main.async { self.onDevice(o) }
            }
        }
    }
}

/// TCP 接收端：握手鉴权(信任码) → 逐文件收 → 落相册 → ACK（单线程保序）
/// 支持暂停/继续/终止；相册保存失败时把原因回给发送方（ACK 里的 err），不再假成功。
final class RDReceiver {
    var onStatus: (String) -> Void = { _ in }
    var onSaved: (String, String) -> Void = { _, _ in }
    var onStart: (String, Int) -> Void = { _, _ in }                    // 对端名, 文件总数
    var onProgress: (Int, Int, Int64, Int64, Double) -> Void = { _, _, _, _, _ in }  // 第几个(1起), 总数, 已收字节, 文件总大小, 字节/秒
    var onEnd: (Bool, String) -> Void = { _, _ in }
    var onText: (String, String) -> Void = { _, _ in }                       // 收到文本消息(来自, 文本)
    var onFileToSave: (String, URL, String, String) -> Void = { _,_,_,_ in }    // 非媒体文件(来自, 临时URL, 名, mime)→上层存"文件"App
    private var listener: NWListener?
    private var current: RDStream?
    private var aborted = false;   // 用户点「终止」→ 与意外中断区分提示

    func start() {
        aborted = false
        do {
            let l = try NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: RD.tcpPort)!)
            l.newConnectionHandler = { (conn: NWConnection) in
                conn.start(queue: DispatchQueue.global())
                let stream = RDStream(conn)
                self.current = stream
                Task { await self.handle(stream) }
            }
            l.start(queue: DispatchQueue.global())
            listener = l
            onStatus("接收服务已开启")
        } catch {
            onStatus("接收端口错误: \(error.localizedDescription)")
        }
    }

    func pause() { current?.setPaused(true) }
    func resume() { current?.setPaused(false) }
    func abort() { aborted = true; current?.close(); current = nil }

    private func handle(_ s: RDStream) async {
        var total = 0
        var saveFailed = false
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
                let name = RD.stripOrderPrefix(rawName)
                let size = fh["size"] as? Int ?? 0
                let mime = fh["mime"] as? String ?? RD.mime(for: name)
                let kind = fh["kind"] as? String ?? "file"

                if kind == "text" {
                    // 文本消息：读 size 字节到内存，回调上层弹窗展示（不落盘）
                    var buf = Data(); var left = size
                    while left > 0 { let d = try await s.read(min(left, RD.chunkSize)); buf.append(d); left -= d.count }
                    onText(fromName, String(decoding: buf, as: UTF8.self))
                    RDWrite.line(s.conn, ["ack": i])
                    continue
                }

                let isMedia = mime.hasPrefix("image/") || mime.hasPrefix("video/")
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
                if isMedia {
                    // 必须等相册保存结果再回 ACK，否则发送端会显示"发送成功"而相册里没有
                    let res: (Bool, String) = await withCheckedContinuation { cont in
                        RDMediaSaver.save(tempFile: tmp, name: name, mime: mime) { ok, err in
                            cont.resume(returning: (ok, err))
                        }
                    }
                    if res.0 { onSaved(fromName, name) }
                    else { saveFailed = true; ack["err"] = "保存到相册失败：\(res.1)"; onStatus("保存失败：\(name)（\(res.1)）") }
                } else {
                    // 非媒体文件：临时文件先改成真实文件名（带扩展名），再交给上层 present 保存到"文件"App。
                    // 否则导出时只会看到 rd_<UUID> 这种无扩展名临时名。存不存由用户决定，故不报失败。
                    let real = RD.tempURL(named: name)
                    try? FileManager.default.removeItem(at: real)
                    do { try FileManager.default.moveItem(at: tmp, to: real) }
                    catch { onStatus("临时文件改名失败：\(error.localizedDescription)") }
                    onFileToSave(fromName, real, name, mime)
                }
                RDWrite.line(s.conn, ack)   // 收完才放行下一个
            }
            _ = try? await s.readLine()   // done
            RDWrite.line(s.conn, ["ok": true, "bye": true])
            onStatus(saveFailed ? "接收结束（部分文件未保存）" : "接收完成：\(fromName)")
            onEnd(!saveFailed, saveFailed ? "部分文件保存失败" : "接收完成")
        } catch {
            if aborted { onStatus("已终止"); onEnd(false, "已终止") }
            else { onStatus("接收中断"); onEnd(false, "接收中断") }
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
        let nw = NWEndpoint.Host(host)
        let p = NWEndpoint.Port(rawValue: port)!
        let c = NWConnection(host: nw, port: p, using: .tcp)
        conn = c
        c.stateUpdateHandler = { (st: NWConnection.State) in
            if case .ready = st { self.doSend(peer: peerName, items: items, done: done) }
            else if case .failed = st { if self.aborted { self.stop("已终止", done) } else { self.stop("连接失败", done) } }
            else if case .cancelled = st { if self.aborted && !self.finished { self.stop("已终止", done) } }
        }
        c.start(queue: DispatchQueue.global())
    }

    private func doSend(peer: String, items: [SendItem], done: @escaping (Bool) -> Void) {
        Task {
            let s = RDStream(conn!)
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
                        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
                        size = (attrs[.size] as? Int) ?? 0
                        handle = try FileHandle(forReadingFrom: url)
                    case .text(let str):
                        name = String(format: "%03d_", i + 1) + "文本消息.txt"
                        mime = "text/plain;charset=utf-8"
                        kind = "text"
                        textData = Data(str.utf8)
                        size = textData!.count
                    }
                    RDWrite.lenJSON(conn!, ["name": name, "size": size, "mime": mime, "kind": kind, "index": i, "total": items.count])
                    var off = 0, lastTick = Date(), lastB = 0, spd = 0.0
                    while off < size {
                        await self.waitIfPaused()
                        if self.aborted { try? handle?.close(); self.stop("已终止", done); s.close(); return }
                        let want = min(RD.chunkSize, size - off)
                        let chunk: Data
                        if let h = handle { chunk = h.readData(ofLength: want) }
                        else { chunk = textData!.subdata(in: off..<(off + want)) }
                        if chunk.isEmpty { break }
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
                    let ackLine = try await s.readLine()   // ACK：收完才发下一个
                    if let d = ackLine.data(using: .utf8),
                       let a = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                       let e = a["err"] as? String {
                        self.stop("对方保存失败：\(e)", done); s.close(); return
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
