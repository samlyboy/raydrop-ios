import Foundation
import Network
import Darwin

/// 枚举本机 IP（Tailscale 100.x 优先）
enum RDIP {
    static func ips() -> [String] {
        var out: [String] = []
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
                            out.append(String(cString: host))
                        }
                    }
                }
                p = cur.pointee.ifa_next
            }
            freeifaddrs(addr)
        }
        out.sort { a, b in
            let aT = a.hasPrefix("100."), bT = b.hasPrefix("100.")
            if aT != bT { return aT }
            return false
        }
        return out
    }
    static func tailscaleIP() -> String { ips().first(where: { $0.hasPrefix("100.") }) ?? "" }
}

/// 局域网 UDP 广播发现（尽力而为；Tailscale 走 CF 目录）
final class RDDiscovery {
    private var sendSock: Int32 = -1
    private var recvSock: Int32 = -1
    private var running = true
    var onDevice: ([String: Any]) -> Void = { _ in }

    func start() {
        running = true
        DispatchQueue.global().async { self.broadcastLoop() }
        DispatchQueue.global().async { self.recvLoop() }
    }
    func stop() { running = false; if sendSock >= 0 { close(sendSock) }; if recvSock >= 0 { close(recvSock) } }

    private func broadcastLoop() {
        sendSock = socket(AF_INET, SOCK_DGRAM, 0)
        var yes: Int32 = 1
        setsockopt(sendSock, SOL_SOCKET, SO_BROADCAST, &yes, socklen_t(MemoryLayout<Int32>.size))
        while running {
            let me: [String: Any] = [
                "app": RD.app, "v": RD.ver, "name": RDStore.shared.myName,
                "code": RDStore.shared.myCode, "port": Int(RD.tcpPort), "ips": RDIP.ips()
            ]
            if let data = try? JSONSerialization.data(withJSONObject: me) {
                var addr = sockaddr_in()
                addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
                addr.sin_family = sa_family_t(AF_INET)
                addr.sin_port = RD.udpPort.bigEndian
                addr.sin_addr.s_addr = INADDR_BROADCAST.bigEndian  // 255.255.255.255
                withUnsafePointer(to: &addr) { a in
                    a.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                        data.withUnsafeBytes { buf in
                            _ = sendto(sendSock, buf.baseAddress, buf.count, 0, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
                        }
                    }
                }
            }
            Thread.sleep(forTimeInterval: 3)
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
            let n = recvfrom(recvSock, &buf, buf.count, 0, nil, nil)
            guard n > 0 else { continue }
            if let s = String(bytes: buf[0..<n], encoding: .utf8),
               let data = s.data(using: .utf8),
               let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let app = o["app"] as? String, app == RD.app,
               let code = o["code"] as? String, code != RDStore.shared.myCode {
                DispatchQueue.main.async { self.onDevice(o) }
            }
        }
    }
}

/// TCP 接收端：握手鉴权(信任码) → 逐文件收 → 落相册 → ACK（单线程保序）
final class RDReceiver {
    var onStatus: (String) -> Void = { _ in }
    var onSaved: (String, String) -> Void = { _, _ in }
    private var listener: NWListener?
    func start() {
        do {
            let l = try NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: RD.tcpPort))
            l.newConnectionHandler = { (conn: NWConnection) in
                conn.start(queue: DispatchQueue.global())
                let stream = RDStream(conn)
                Task { await self.handle(stream) }
            }
            l.start(queue: DispatchQueue.global())
            listener = l
            onStatus("接收端口已开启 :\(RD.tcpPort) · 码 \(RDStore.shared.myCode)")
        } catch {
            onStatus("接收端口错误: \(error.localizedDescription)")
        }
    }

    private func handle(_ s: RDStream) async {
        do {
            let hsLine = try await s.readLine()
            guard let hsData = hsLine.data(using: .utf8),
                  let hs = try? JSONSerialization.jsonObject(with: hsData) as? [String: Any] else { s.close(); return }
            let fromCode = hs["code"] as? String ?? ""
            let fromName = hs["name"] as? String ?? "对方"
            let count = hs["count"] as? Int ?? 0

            guard RDStore.shared.isTrusted(fromCode) else {
                RDWrite.line(s.conn, ["ok": false, "reason": "untrusted"])
                onStatus("已拦截未信任的 \(fromName)(\(fromCode))")
                s.close(); return
            }
            RDWrite.line(s.conn, ["ok": true])
            onStatus("\(fromName) 正在发送 \(count) 个文件")

            for i in 0..<count {
                let fh = try await s.readLenJSON()
                let name = fh["name"] as? String ?? "file\(i)"
                let size = fh["size"] as? Int ?? 0
                let mime = fh["mime"] as? String ?? RD.mime(for: name)
                let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("rd_\(UUID().uuidString)")
                FileManager.default.createFile(atPath: tmp.path, contents: nil)
                let handle = try FileHandle(forWritingTo: tmp)
                try await s.readIntoFile(size, handle)
                try? handle.close()
                RDMediaSaver.save(tempFile: tmp, mime: mime) { ok in
                    if ok { self.onSaved(fromName, name) }
                }
                RDWrite.line(s.conn, ["ack": i])   // 收完才放行下一个
            }
            _ = try? await s.readLine()   // done
            RDWrite.line(s.conn, ["ok": true, "bye": true])
            onStatus("接收完成：\(fromName)")
        } catch {
            onStatus("接收中断")
        }
        s.close()
    }
}

/// TCP 发送端：连接 → 握手 → 逐文件发(等 ACK，单线程保序) → 结束
final class RDSender {
    var onStatus: (String) -> Void = { _ in }
    private var conn: NWConnection?

    func send(host: String, port: UInt16, files: [URL], done: @escaping (Bool) -> Void) {
        let nw = NWEndpoint.Host(host)
        let p = NWEndpoint.Port(rawValue: port)
        let c = NWConnection(host: nw, port: p, using: .tcp)
        conn = c
        c.stateUpdateHandler = { st in
            if case .ready = st { self.doSend(files: files, done: done) }
            else if case .failed = st { self.onStatus("连接失败"); done(false) }
        }
        c.start(queue: DispatchQueue.global())
    }

    private func doSend(files: [URL], done: @escaping (Bool) -> Void) {
        Task {
            let s = RDStream(conn!)
            do {
                RDWrite.line(conn!, ["app": RD.app, "v": RD.ver, "name": RDStore.shared.myName,
                                      "code": RDStore.shared.myCode, "count": files.count])
                let repLine = try await s.readLine()
                guard let repData = repLine.data(using: .utf8),
                      let rep = try? JSONSerialization.jsonObject(with: repData) as? [String: Any],
                      (rep["ok"] as? Bool) == true else {
                    let reason = repLine.contains("untrusted") ? "对方未信任你的码(请让对方添加你的3位码)" : "被拒绝"
                    self.onStatus(reason); done(false); s.close(); return
                }
                for (i, url) in files.enumerated() {
                    let name = String(format: "%03d_", i + 1) + url.lastPathComponent
                    let mime = RD.mime(for: url.lastPathComponent)
                    let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
                    let size = (attrs[.size] as? Int) ?? 0
                    RDWrite.lenJSON(conn!, ["name": name, "size": size, "mime": mime, "index": i, "total": files.count])
                    let handle = try FileHandle(forReadingFrom: url)
                    var off = 0
                    while off < size {
                        let chunk = handle.readData(ofLength: RD.chunkSize)
                        if chunk.isEmpty { break }
                        try await sendChunk(chunk)   // 背压：等这块发完再发下一块
                        off += chunk.count
                    }
                    try? handle.close()
                    _ = try await s.readLine()   // ACK：收完才发下一个
                    self.onStatus("已发送 \(name)")
                }
                RDWrite.line(conn!, ["done": true])
                _ = try? await s.readLine()
                self.onStatus("发送完成：\(files.count) 个文件")
                done(true)
            } catch {
                self.onStatus("发送失败"); done(false)
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
