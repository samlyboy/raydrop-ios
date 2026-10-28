import Foundation
import Network

enum RD {
    static let app = "RayDrop"
    static let ver = 1
    static let udpPort: UInt16 = 41234
    static let tcpPort: UInt16 = 41235
    static let dirURL = "https://raydrop-dir.pages.dev/api/dir"
    static let chunkSize = 64 * 1024
    /// 单文件接收上限（8GB）。防止异常/恶意对端声明超大长度写满磁盘。
    static let maxFileSize = 8 * 1024 * 1024 * 1024
    /// 磁盘剩余可用空间（字节）
    static func freeDiskSpace() -> Int {
        let url = URL(fileURLWithPath: NSHomeDirectory())
        if let v = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
           let n = v.volumeAvailableCapacityForImportantUsage { return Int(n) }
        return Int.max   // 取不到就不拦
    }

    static func mime(for name: String) -> String {
        let n = name.lowercased()
        // ★ 覆盖 iPhone 实际会遇到的视频/图片扩展名。
        //   旧版只认 .mp4/.mov，其余视频（.m4v/.avi/.mkv/.3gp、以及慢动作/第三方导入的怪后缀）
        //   一律退化成 application/octet-stream → 接收端判不出是视频 → 不进相册（只有「下载」里一份）。
        switch (n as NSString).pathExtension {
        case "jpg", "jpeg": return "image/jpeg"
        case "png": return "image/png"
        case "heic", "heif": return "image/heic"
        case "webp": return "image/webp"
        case "gif": return "image/gif"
        case "tif", "tiff": return "image/tiff"
        case "bmp": return "image/bmp"
        case "dng": return "image/x-adobe-dng"
        case "mp4": return "video/mp4"
        case "mov": return "video/quicktime"
        case "m4v": return "video/x-m4v"
        case "avi": return "video/x-msvideo"
        case "mkv": return "video/x-matroska"
        case "webm": return "video/webm"
        case "3gp": return "video/3gpp"
        case "ts": return "video/mp2t"
        case "mpg", "mpeg": return "video/mpeg"
        case "wmv": return "video/x-ms-wmv"
        case "flv": return "video/x-flv"
        case "pdf": return "application/pdf"
        case "zip": return "application/zip"
        case "json": return "application/json"
        case "apk": return "application/vnd.android.package-archive"
        case "txt": return "text/plain"
        case "csv": return "text/csv"
        default: return "application/octet-stream"
        }
    }

    /// 这份文件是否该按「视频」处理。**不能只看 mime**：老版本对端可能把视频标成
    /// application/octet-stream，这时要用扩展名兜底，否则会被当成图片写相册而失败。
    static func isVideoFile(name: String, mime: String) -> Bool {
        if mime.lowercased().hasPrefix("video/") { return true }
        if mime.lowercased().hasPrefix("image/") { return false }
        let ext = (name as NSString).pathExtension.lowercased()
        return ["mp4", "mov", "m4v", "avi", "mkv", "webm", "3gp", "ts", "mpg", "mpeg", "wmv", "flv"].contains(ext)
    }

    static func isImageFile(name: String, mime: String) -> Bool {
        if mime.lowercased().hasPrefix("image/") { return true }
        if isVideoFile(name: name, mime: mime) { return false }
        let ext = (name as NSString).pathExtension.lowercased()
        return ["jpg", "jpeg", "png", "heic", "heif", "webp", "gif", "tif", "tiff", "bmp", "dng"].contains(ext)
    }

    /// mime → 扩展名（对端发来的文件没带扩展名时补一个，让「文件」App 能正确预览/打开）
    static func ext(forMime mime: String) -> String {
        let m = mime.lowercased()
        if m.hasPrefix("image/") {
            switch m {
            case "image/png": return "png"
            case "image/heic", "image/heif": return "heic"
            case "image/webp": return "webp"
            case "image/gif": return "gif"
            case "image/tiff": return "tiff"
            case "image/bmp": return "bmp"
            case "image/x-adobe-dng": return "dng"
            case "image/jpeg", "image/jpg": return "jpg"
            default: return "jpg"
            }
        }
        if m.hasPrefix("video/") {
            switch m {
            case "video/mp4": return "mp4"
            case "video/quicktime": return "mov"
            case "video/x-m4v": return "m4v"
            case "video/x-matroska": return "mkv"
            case "video/webm": return "webm"
            case "video/x-msvideo": return "avi"
            case "video/3gpp": return "3gp"
            case "video/mp2t": return "ts"
            case "video/mpeg": return "mpg"
            case "video/x-ms-wmv": return "wmv"
            case "video/x-flv": return "flv"
            default: return "mp4"
            }
        }
        switch m {
        case "application/pdf": return "pdf"
        case "application/zip": return "zip"
        case "application/json": return "json"
        case "application/vnd.android.package-archive": return "apk"
        case "text/plain": return "txt"
        case "text/csv": return "csv"
        default: return ""
        }
    }
}

/// 基于 NWConnection 的带缓冲异步流：精确读 n 字节 / 读一行 / 读 4字节长度前缀 JSON。
final class RDStream {
    enum ReadError: Error { case closed, stalled }

    let conn: NWConnection
    private let queue = DispatchQueue(label: "raydrop.stream")
    private var buffer = Data()
    private var failed: Error?
    private var pending: (n: Int, cont: CheckedContinuation<Data, Error>)?
    /// 暂停：停止继续读取（数据留在内核缓冲，恢复后接着读）；终止：直接 cancel 连接
    private(set) var isPaused = false
    private var pumping = false
    /// ★ 停滞看门狗：对端 Wi-Fi 掉线/走远时，NWConnection 可能长时间既不送来数据也不报错，
    ///   接收端就会在 `read(n)` 上无限等待（声明了 size、字节却永远不来）。超时即判定连接已死。
    ///   发送端等 ACK 时那边可能正在把大视频写进相册，所以要给足时间（见 doSend）。
    private let stallTimeout: TimeInterval
    private var watchdog: DispatchWorkItem?

    /// 调用方需确保 conn 已 start()。receiver 在 newConnectionHandler 里 start，sender 在连接 ready 后创建。
    init(_ conn: NWConnection, stallTimeout: TimeInterval = 60) {
        self.conn = conn
        self.stallTimeout = stallTimeout
        pump()
    }

    deinit { watchdog?.cancel() }

    /// 有等待中的读取时启动（或重置）停滞计时
    private func armWatchdog() {
        watchdog?.cancel()
        guard pending != nil else { return }
        let w = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.queue.async {
                guard let p = self.pending else { return }
                self.pending = nil
                self.failed = ReadError.stalled
                p.cont.resume(throwing: ReadError.stalled)
            }
        }
        watchdog = w
        queue.asyncAfter(deadline: .now() + stallTimeout, execute: w)
    }

    private func disarmWatchdog() {
        watchdog?.cancel()
        watchdog = nil
    }

    private func pump() {
        if pumping || failed != nil { return }
        pumping = true
        conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }
            self.queue.async {
                self.pumping = false
                if let d = data, !d.isEmpty { self.buffer.append(d) }
                if let e = error { self.failed = e }
                if isComplete && self.failed == nil { self.failed = ReadError.closed }
                self.fulfillPending()
                if self.pending != nil { self.armWatchdog() }   // 有新字节到达 → 重置停滞计时
                if self.failed == nil && !self.isPaused { self.pump() }
            }
        }
    }

    /// 暂停 / 继续
    func setPaused(_ p: Bool) {
        queue.async {
            self.isPaused = p
            if !p { self.pump() }
        }
    }

    private func fulfillPending() {
        guard let p = pending else { return }
        // ★ 顺序很重要：先看缓冲区是否已够数，再判失败。
        //   旧顺序「先看 failed」会在对端发完即关连接（isComplete → failed=closed）时，
        //   把**已完整到达缓冲区**的最后一份数据直接丢弃并抛错 → 最后一个文件（常是视频）丢。
        if buffer.count >= p.n {
            let d = Data(buffer.prefix(p.n)); buffer.removeFirst(p.n)
            pending = nil; disarmWatchdog(); p.cont.resume(returning: d)
        } else if let e = failed {
            pending = nil; disarmWatchdog(); p.cont.resume(throwing: e)
        }
    }

    /// 精确读取 n 字节（不足则挂起，直到到达或连接关闭）
    func read(_ n: Int) async throws -> Data {
        try await withCheckedThrowingContinuation { cont in
            queue.async {
                // ★ 同样的问题：缓冲够就先给数据，别因为「对端刚关连接」把已到的字节吞掉
                if self.buffer.count >= n {
                    let d = Data(self.buffer.prefix(n)); self.buffer.removeFirst(n)
                    self.disarmWatchdog(); cont.resume(returning: d); return
                }
                if let e = self.failed { self.disarmWatchdog(); cont.resume(throwing: e); return }
                if let old = self.pending { old.cont.resume(throwing: ReadError.closed) }
                self.pending = (n, cont)
                self.armWatchdog()
            }
        }
    }

    /// 读一行（\n 结尾）；握手/ACK 用（逐字节，量很小）
    /// ⚠️ 加长度上限（8KB）：对端若发来超长无换行数据，逐字节读会让内存无界增长。
    func readLine() async throws -> String {
        var line = Data()
        while true {
            let d = try await read(1)
            if d[d.startIndex] == 0x0A { return String(decoding: line, as: UTF8.self) }
            line.append(d)
            if line.count > 8192 { throw ReadError.closed }
        }
    }

    /// 读 4 字节大端长度 + JSON（文件头）
    /// ⚠️ 长度上限 64KB：文件头只是元数据，异常对端可能声明超大长度把内存吃光。
    func readLenJSON() async throws -> [String: Any] {
        let lenData = try await read(4)
        let n = lenData.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).bigEndian }
        guard n > 0, n <= 64 * 1024 else { throw ReadError.closed }
        let body = try await read(Int(n))
        return (try? JSONSerialization.jsonObject(with: body) as? [String: Any]) ?? [:]
    }

    /// 读取 n 字节到文件（接收大文件用，分块避免占用内存）；每块回调进度
    func readIntoFile(_ n: Int, _ handle: FileHandle, onProgress: ((Int) -> Void)? = nil) async throws {
        var left = n, done = 0
        while left > 0 {
            let want = min(left, RD.chunkSize)
            let d = try await read(want)
            handle.write(d)
            left -= d.count
            done += d.count
            onProgress?(done)
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
