import Foundation
import Network

enum RD {
    static let app = "RayDrop"
    static let ver = 1
    static let udpPort: UInt16 = 41234
    static let tcpPort: UInt16 = 41235
    static let dirURL = "https://raydrop-dir.pages.dev/api/dir"
    static let chunkSize = 64 * 1024

    static func mime(for name: String) -> String {
        let n = name.lowercased()
        if n.hasSuffix(".jpg") || n.hasSuffix(".jpeg") { return "image/jpeg" }
        if n.hasSuffix(".png") { return "image/png" }
        if n.hasSuffix(".heic") { return "image/heic" }
        if n.hasSuffix(".webp") { return "image/webp" }
        if n.hasSuffix(".gif") { return "image/gif" }
        if n.hasSuffix(".mp4") { return "video/mp4" }
        if n.hasSuffix(".mov") { return "video/quicktime" }
        return "application/octet-stream"
    }
}

/// 基于 NWConnection 的带缓冲异步流：精确读 n 字节 / 读一行 / 读 4字节长度前缀 JSON。
final class RDStream {
    enum ReadError: Error { case closed }

    let conn: NWConnection
    private let queue = DispatchQueue(label: "raydrop.stream")
    private var buffer = Data()
    private var failed: Error?
    private var pending: (n: Int, cont: CheckedContinuation<Data, Error>)?

    /// 调用方需确保 conn 已 start()。receiver 在 newConnectionHandler 里 start，sender 在连接 ready 后创建。
    init(_ conn: NWConnection) {
        self.conn = conn
        pump()
    }

    private func pump() {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }
            self.queue.async {
                if let d = data, !d.isEmpty { self.buffer.append(d) }
                if let e = error { self.failed = e }
                if isComplete && self.failed == nil { self.failed = ReadError.closed }
                self.fulfillPending()
                if self.failed == nil { self.pump() }
            }
        }
    }

    private func fulfillPending() {
        guard let p = pending else { return }
        if let e = failed {
            pending = nil; p.cont.resume(throwing: e)
        } else if buffer.count >= p.n {
            let d = Data(buffer.prefix(p.n)); buffer.removeFirst(p.n)
            pending = nil; p.cont.resume(returning: d)
        }
    }

    /// 精确读取 n 字节（不足则挂起，直到到达或连接关闭）
    func read(_ n: Int) async throws -> Data {
        try await withCheckedThrowingContinuation { cont in
            queue.async {
                if let e = self.failed { cont.resume(throwing: e); return }
                if self.buffer.count >= n {
                    let d = Data(self.buffer.prefix(n)); self.buffer.removeFirst(n); cont.resume(returning: d); return
                }
                if let old = self.pending { old.cont.resume(throwing: ReadError.closed) }
                self.pending = (n, cont)
            }
        }
    }

    /// 读一行（\n 结尾）；握手/ACK 用（逐字节，量很小）
    func readLine() async throws -> String {
        var line = Data()
        while true {
            let d = try await read(1)
            if d[d.startIndex] == 0x0A { return String(decoding: line, as: UTF8.self) }
            line.append(d)
        }
    }

    /// 读 4 字节大端长度 + JSON（文件头）
    func readLenJSON() async throws -> [String: Any] {
        let lenData = try await read(4)
        let n = lenData.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).bigEndian }
        let body = try await read(Int(n))
        return (try? JSONSerialization.jsonObject(with: body) as? [String: Any]) ?? [:]
    }

    /// 读取 n 字节到文件（接收大文件用，分块避免占用内存）
    func readIntoFile(_ n: Int, _ handle: FileHandle) async throws {
        var left = n
        while left > 0 {
            let want = min(left, RD.chunkSize)
            let d = try await read(want)
            handle.write(d)
            left -= d.count
        }
    }

    func close() { conn.cancel() }
}

// MARK: - 写线格式
enum RDWrite {
    static func line(_ conn: NWConnection, _ obj: [String: Any]) {
        var d = (try? JSONSerialization.data(withJSONObject: obj)) ?? Data()
        d.append(0x0A)
        conn.send(content: d, completion: .idempotent)
    }
    static func lenJSON(_ conn: NWConnection, _ obj: [String: Any]) {
        let body = (try? JSONSerialization.data(withJSONObject: obj)) ?? Data()
        var len = UInt32(body.count).bigEndian
        var out = Data(bytes: &len, count: 4)
        out.append(body)
        conn.send(content: out, completion: .idempotent)
    }
}
