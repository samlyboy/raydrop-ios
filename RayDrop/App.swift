import Foundation
import SwiftUI
import PhotosUI
import Photos
import UniformTypeIdentifiers
import UIKit

final class Engine: ObservableObject {
    /// 分享扩展传来的待发送项
    struct SharedItem: Identifiable {
        let id = UUID()
        var url: URL?      // 文件/图片/视频：已复制到沙盒
        var text: String?  // 文本
        var name: String
        var size: Int64
        var kind: String   // "file" | "text"
        var isImage: Bool
        var isVideo: Bool
        var sizeText: String {
            if kind == "text" { return "\(size) 字" }
            if size >= 1048576 { return String(format: "%.1f MB", Double(size) / 1048576.0) }
            return "\(max(1, size / 1024)) KB"
        }
    }
    struct DeviceInfo: Identifiable {
        var id: String
        var code: String
        var name: String
        var platform: String     // iOS / Android / PC，驱动设备图标
        var lanHost: String
        var tsHost: String
        var port: UInt16
        var lastSeen: Date
        /// ★ 两条通道各自「最近一次真从该通道收到报文」的时刻。
        ///   某条线路断开（对方关 Tailscale / 离开局域网）→ 该通道在各自窗口超时后单独消失，不拖累另一条。
        var lanSeen: Date = .distantPast
        var tsSeen: Date = .distantPast
        /// 手机 vs 电脑图标
        var isComputer: Bool {
            let p = platform.lowercased()
            return p.contains("pc") || p.contains("mac") || p.contains("win") || p.contains("windows") || p.contains("linux")
        }
    }
    struct LogEntry: Identifiable { let id = UUID(); let text: String; let inColor: Color; let isHeader: Bool; var repeats: Int = 1 }

    @Published var status = "启动中…"
    @Published var logEntries: [LogEntry] = []
    @Published var myCode = RDStore.shared.myCode
    @Published var myName = RDStore.shared.myName
    @Published var devices: [DeviceInfo] = []
    /// ★ 通道存活窗口：公告/探测周期 2s。窗口需容忍链路抖动与丢包，否则一两次丢包就误判离线、列表反复上下线。
    ///   v36：LAN 10→25s、TS 20→45s。原窗口太紧（LAN 只容 4 次丢包），
    ///   iOS Wi-Fi 省电休眠、路由器丢广播都会让设备"闪断"，表现为一直在线的设备反复掉线上线。
    ///   正常退出走 bye 即时移除，不受此窗口影响；窗口只兜底「异常掉线」。
    static let lanTtl: TimeInterval = 25
    static let tsTtl: TimeInterval = 45
    @Published var progress = ""
    @Published var txActive = false
    @Published var paused = false
    /// ★ v41：正在发送（**含「连接中」阶段**）的目标设备 id。
    ///   旧实现只有 TCP 连上并握手成功后才进 txActive，连接那几秒到十几秒界面毫无变化，
    ///   用户以为没点中就连点几下 —— 每一下都新起一条连接。现在点下去立刻转圈并锁住该行。
    @Published var sendingToID: String? = nil
    /// 所选内容还在后台读取（视频导出/大文件复制），此时点设备要给「请稍等」而不是「没选内容」
    @Published var preparing = false
    /// 已选待发送内容的摘要，如「已选 3 项」
    @Published var pendingSummary = ""
    /// 从分享扩展收到的待发送项
    @Published var sharedItems: [SharedItem] = []
    /// 分享扩展唤起 APP 时置 true，主界面弹出选择设备
    @Published var showSharePrompt = false
    @Published var receivedFrom = ""
    @Published var receivedText = ""
    @Published var showRecvText = false
    /// ★ 最近一次收到的文件（已自动落在「下载」里）；仅用于「另存为…」这个可选出口（默认无需任何操作）
    @Published var lastReceivedFile: URL? = nil
    @Published var lastReceivedName = ""
    @Published var showSaveFile = false

    private let receiver = RDReceiver()
    private let discovery = RDDiscovery()
    private let sender = RDSender()
    private var txUp = false, txTotal = 0, txPeer = "对方"
    private var pendingItems: [SendItem] = []
    private var didStart = false
    /// 跨 Tailscale 发现：从 Tailscale API 拉到的 tailnet 设备 100.x（非本机），作为单播探测目标
    private var tsTargets: [String] = []

    static let cIn = Color(red: 0.90, green: 0.22, blue: 0.21)
    static let cOut = Color(red: 0.18, green: 0.60, blue: 0.24)
    static let cSys = Color.secondary
    private static let fmtTime: DateFormatter = { let f = DateFormatter(); f.dateFormat = "MM-dd HH:mm:ss"; return f }()

    /// 新条目插在「当前批次时间戳分隔行」之下；没有分隔行则插最顶。
    /// 不再有"批次结束就释放"的逻辑——一旦某批次插了时间戳，它就钉在该批最上方，永不被后续条目挤到下面。
    /// ★ v37：同一句话 10s 内重复出现时合并为「（×N）」，避免任何异常把日志刷满整屏。
    private var lastLogAt = Date.distantPast
    private func addEntry(_ text: String, _ color: Color, header: Bool = false) {
        DispatchQueue.main.async {
            let at: Int
            if header { at = 0 }
            else if self.logEntries.first?.isHeader == true { at = 1 }
            else { at = 0 }
            if !header, at < self.logEntries.count,
               self.logEntries[at].text == text,
               Date().timeIntervalSince(self.lastLogAt) < 10 {
                self.logEntries[at].repeats += 1
                self.lastLogAt = Date()
                return
            }
            self.logEntries.insert(LogEntry(text: text, inColor: color, isHeader: header), at: at)
            self.lastLogAt = Date()
            if self.logEntries.count > 300 { self.logEntries.removeLast(self.logEntries.count - 300) }
        }
    }
    private func addLog(_ text: String) { addEntry(text, Engine.cSys) }
    private func addHeader(_ title: String) { addEntry(Engine.fmtTime.string(from: Date()) + "  " + title, Engine.cSys, header: true) }

    static func fmtSpeed(_ bps: Double) -> String {
        if bps >= 1048576 { return String(format: "%.1f MB/s", bps / 1048576) }
        return String(format: "%.0f KB/s", bps / 1024)
    }
    /// 字节 → "x.x" MB 数字部分（传输进度显示「已传/总量」用）
    static func fmtMB(_ bytes: Int64) -> String {
        String(format: "%.1f", Double(bytes) / 1048576.0)
    }
    private func beginTx(up: Bool, peer: String, total: Int) {
        DispatchQueue.main.async {
            self.txUp = up; self.txTotal = total; self.txActive = true; self.paused = false
            // ★ v42：传输期间禁止自动锁屏。传 1~2GB 视频要好几分钟，屏幕自动锁定会让 App 挂起、
            //   socket 被系统回收 —— 表现就是「传到一半突然接收中断」。结束时恢复系统默认。
            UIApplication.shared.isIdleTimerDisabled = true
            let p = peer.isEmpty ? "对方" : peer
            self.txPeer = p
            self.progress = "(0/\(max(1, total))) " + (up ? "↑上传" : "↓下载") + " 0 KB/s"
            self.addHeader(up ? "发送 → \(p)   共 \(total) 项" : "接收 ← \(p)   共 \(total) 项")
        }
    }
    private func updateTx(cur: Int, total: Int, done: Int64, size: Int64, bps: Double) {
        DispatchQueue.main.async {
            let t = total > 0 ? total : self.txTotal
            guard t > 0 else { return }
            var s = "(\(min(max(1, cur), t))/\(t)) " + (self.txUp ? "↑上传" : "↓下载")
            // 文件大小 / 已传 MB / 完成百分比（size<=0 时退化为只显示速度）
            if size > 0 {
                let pct = min(100, Int(done * 100 / max(1, size)))
                s += " \(Engine.fmtMB(done))/\(Engine.fmtMB(size)) MB (\(pct)%)"
            }
            s += " · " + Engine.fmtSpeed(bps)
            self.progress = s
        }
    }
    private func endTx(ok: Bool, msg: String) {
        DispatchQueue.main.async {
            self.txActive = false; self.paused = false
            UIApplication.shared.isIdleTimerDisabled = false   // 恢复系统自动锁屏
            // 发送结束（成功/失败/超时）即解除设备行锁定，允许重试
            if self.txUp { self.sendingToID = nil }
            if ok && self.txTotal > 0 { self.progress = "(\(self.txTotal)/\(self.txTotal)) 完成" }
            else if msg != "接收中断" && !msg.hasPrefix("已终止") { self.progress = "" }
        }
    }
    func togglePause() {
        paused.toggle()
        if txUp { paused ? sender.pause() : sender.resume() }
        else { paused ? receiver.pause() : receiver.resume() }
    }
    func abortTx() {
        if txUp { sender.abort() } else { receiver.abort() }
        txActive = false; paused = false; progress = ""
        UIApplication.shared.isIdleTimerDisabled = false
        if txUp { sendingToID = nil }   // 终止后立刻解锁设备行，可以马上重试
    }

    /// 可选出口：把最近收到的文件另存到别处（如 iCloud 云盘）。
    /// 默认接收已全自动存入「下载」，这里只作为额外的主动导出入口。
    func exportLastReceived() {
        guard lastReceivedFile != nil else { return }
        showSaveFile = true
    }

    func start() {
        if didStart { return }; didStart = true
        // ★ v46：后台空闲自动退出。这里只注入「忙不忙」的判定，计时与退出交给 RDIdleExit。
        //   三个标记都要算：txActive（正在传）、sendingToID（点下去到握手完成之间，常几秒到十几秒）、
        //   preparing（选完素材还在导出/复制，此时被杀会白等一场）。
        RDIdleExit.shared.isBusy = { [weak self] in
            guard let self else { return false }
            return self.txActive || self.sendingToID != nil || self.preparing
        }
        receiver.onStatus = { [weak self] s in
            DispatchQueue.main.async {
                guard let self else { return }
                self.status = s
                // ★ v42：只有「失败 / 等待网络 / 创建失败」这类真问题才写日志；
                //   「接收服务已开启」由 onListening 那条带端口的日志代表，不重复。
                if s.hasPrefix("接收服务失败") || s.hasPrefix("接收服务等待")
                    || s.hasPrefix("接收服务创建失败") {
                    self.addLog(s)
                }
            }
        }
        // ★ v42：接收端口由系统动态分配，公告里带的是**当前真实端口**。
        //   这一条把「固定 41235 → EADDRINUSE → 反复重建」的死循环从根上拆掉。
        discovery.portProvider = { [weak self] in self?.receiver.listeningPort ?? 0 }
        // ★ 监听就绪（含被系统挂起后的自动重建）→ 立刻公告一轮，让对端马上刷新本机在线状态
        //   回调来自监听的串行队列，转回主线程再动 UI 状态
        receiver.onListening = { [weak self] p in DispatchQueue.main.async { self?.onReceiverReady(p) } }
        // ★ 收到文件已经自动落盘到「下载」（无需手动确认），这里只更新界面记录
        receiver.onSaved = { [weak self] from, name, path in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.lastReceivedFile = URL(fileURLWithPath: path)
                self.lastReceivedName = name
                self.addEntry("\(from) → 本机  \(name)（已存「下载」）", Engine.cIn)
            }
        }
        receiver.onText = { [weak self] from, text in
            DispatchQueue.main.async {
                self?.receivedFrom = from.isEmpty ? "对方" : from
                self?.receivedText = text
                self?.showRecvText = true
                self?.addEntry("\(from) → 本机  [文本] \(text.count) 字", Engine.cIn)
            }
        }
        receiver.onStart = { [weak self] peer, total in self?.beginTx(up: false, peer: peer, total: total) }
        receiver.onProgress = { [weak self] cur, total, done, size, bps in self?.updateTx(cur: cur, total: total, done: done, size: size, bps: bps) }
        receiver.onEnd = { [weak self] ok, msg in self?.endTx(ok: ok, msg: msg) }
        receiver.onAlbumNote = { [weak self] note in
            DispatchQueue.main.async {
                self?.addLog("以下内容已存「下载」但未进相册（可在「文件」App 里找到）：\(note)")
            }
        }
        discovery.onDevice = { [weak self] o in self?.ingest(o) }
        sender.onStatus = { [weak self] s in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.status = s
                if s.hasPrefix("已发送 ") {
                    self.addEntry("本机 → \(self.txPeer)  \(String(s.dropFirst("已发送 ".count)))", Engine.cOut)
                } else { self.addLog(s) }
            }
        }
        sender.onStart = { [weak self] peer, total in self?.beginTx(up: true, peer: peer, total: total) }
        sender.onProgress = { [weak self] cur, total, done, size, bps in self?.updateTx(cur: cur, total: total, done: done, size: size, bps: bps) }
        sender.onEnd = { [weak self] ok, msg in
            // 记下失败原因：beginSend 据此判断「端口过期」要不要自动重试一次
            DispatchQueue.main.async {
                self?.lastSendReason = msg
                self?.endTx(ok: ok, msg: msg)
            }
        }
        addLog("接收到的文件会自动存入「下载」文件夹（文件 App → 我的 iPhone → RayDrop锐传 → 下载），无需手动确认；图片/视频另存一份到相册。")
        receiver.start(); discovery.start()
        // ★ 1s 一轮巡检：通道断开（LAN 10s / TS 20s）与整机离线都能在 1s 内反映到界面；
        //   同时每 5s 做一次「接收监听健康检查」——NWListener 被系统压成 waiting/failed 后不会自愈，
        //   不重建就会「对端显示本机在线，却一发就 ECONNREFUSED」。
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.cull()
            self.healthTick += 1
            if self.healthTick % 5 == 0 { self.ensureReceiverUp() }
        }
        // 跨 Tailscale 发现（手机↔手机纯 TS）：周期拉 tailnet 设备 100.x → 单播探测目标
        refreshTailscale()
        // ★ 启动连刷两次（2s/5s 后），抵消一次网络抖动导致 tsTargets 空、靠 15s 才补齐的延迟
        Timer.scheduledTimer(withTimeInterval: 2, repeats: false) { [weak self] _ in self?.refreshTailscale() }
        Timer.scheduledTimer(withTimeInterval: 5, repeats: false) { [weak self] _ in self?.refreshTailscale() }
        Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in self?.refreshTailscale() }
    }

    private func ingest(_ o: [String: Any]) {
        guard let code = o["code"] as? String else { return }
        let name = o["name"] as? String ?? "设备"
        let platform = o["platform"] as? String ?? ""
        let ips = o["ips"] as? [String] ?? []
        // ★ v42：端口由对端动态分配后公告过来。0 = 对方接收服务还没起来（刚启动/刚回前台重建），
        //   此时**保留上一次已知端口**（大概率仍然有效），而不是把它清成 0 让设备变成点不动。
        let port = UInt16((o["port"] as? NSNumber)?.intValue ?? 0)

        let myIPs = RDIP.ips()
        let src = o["srcIP"] as? String ?? ""

        // ★ 关键判据（锐哥修正）：LAN 地址只有「包从真实局域网到达」(src 非 100.x 且与本机同 /24) 才可信。
        //   从 Tailscale 包里对端自报的局域网地址(其自己另一物理网络的 192.168.1.x)即使恰巧同 /24，
        //   也只是"假同局域网"——物理不互通、连不通，必须丢弃。
        let viaLan = !src.isEmpty && !src.hasPrefix("100.") && Engine.sameSubnet(src, myIPs)
        let viaTs  = src.hasPrefix("100.")

        // 对方载荷里自报的 100.x（仅用于判断「它还有没有 Tailscale」，不作为通道可用依据）
        var peerTS = ""
        for ip in ips where ip.hasPrefix("100.") { peerTS = ip; break }
        if viaTs { peerTS = src }

        let did = (o["did"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? ("code:" + code)
        let isNew = upsert(id: did, code: code, name: name, platform: platform,
                           src: src, viaLan: viaLan, viaTs: viaTs, peerTSAdvertised: peerTS, port: port)
        // ★ 只在「第一次看到这台设备 / 它刚从离线回来」时回告一次。
        //   旧实现是每收一个报文就无条件回告：两台设备会互相对轰到死（A→B→A→B…无节流），
        //   把自己这条链路的空口和接收缓冲全占满，周期公告反而被丢 —— 于是设备一直在掉线上线。
        //   现在回告只用于"加速首次互相发现"，稳态完全靠 2s 周期公告，流量骤降。
        if isNew { discovery.reply(to: src) }
        syncTargets()
    }

    /// 该 IP 是否与本机任一局域网 IP 同 /24 网段
    static func sameSubnet(_ ip: String, _ myIPs: [String]) -> Bool {
        let p = ip.split(separator: ".").map(String.init)
        guard p.count == 4 else { return false }
        for my in myIPs where !my.hasPrefix("100.") {
            let m = my.split(separator: ".").map(String.init)
            if m.count == 4 && m[0] == p[0] && m[1] == p[1] && m[2] == p[2] { return true }
        }
        return false
    }
    /// ★ 通道级存活（本轮核心修复）：只有「真从该通道收到报文」才刷新对应通道的时刻。
    ///   - 局域网通道：包从同网段到达（src 非 100.x 且同 /24）→ 刷新 lanSeen；
    ///   - Tailscale 通道：包真从 100.x 到达 → 刷新 tsSeen（不再只凭对方载荷里写了个 100.x 就当可用，
    ///     那样对方关了 Tailscale 仍会显示一条连不通的 Tailscale 记录）；
    ///   - 即时判「对方已关 Tailscale」：LAN 包到达、对方载荷不再带任何 100.x、且近 3s 无 TS 报文
    ///     → 立刻清空 TS 通道（≤2s 内该行消失，只留【局域网】）。
    private func upsert(id: String, code: String, name: String, platform: String,
                        src: String, viaLan: Bool, viaTs: Bool, peerTSAdvertised: String, port: UInt16) -> Bool {
        var idx = devices.firstIndex { $0.id == id }
        if idx == nil { idx = devices.firstIndex { $0.code == code } }
        if idx == nil, viaLan { idx = devices.firstIndex { $0.name == name && $0.lanHost == src } }
        let now = Date()
        if let i = idx {
            // 更新前先记下它原来是不是"活着"，用来判断这次是不是"刚回来"
            let wasAlive = lanAlive(devices[i]) || tsAlive(devices[i])
            devices[i].id = id.hasPrefix("cf:") ? devices[i].id : id
            devices[i].code = code; devices[i].name = name; devices[i].platform = platform
            if port > 0 { devices[i].port = port }   // 0 = 对方尚未分配端口，保留旧值
            devices[i].lastSeen = now
            if viaLan { devices[i].lanHost = src; devices[i].lanSeen = now }
            if viaTs  { devices[i].tsHost  = src; devices[i].tsSeen  = now }
            if viaLan && !viaTs && peerTSAdvertised.isEmpty && now.timeIntervalSince(devices[i].tsSeen) > 3 {
                devices[i].tsHost = ""; devices[i].tsSeen = .distantPast
            }
            return !wasAlive
        } else {
            // 两条通道都没被证实（来源既非同网段也非 100.x）→ 不做一条连不通的记录，直接丢弃
            if !viaLan && !viaTs { return false }
            var d = DeviceInfo(id: id, code: code, name: name, platform: platform,
                               lanHost: "", tsHost: "", port: port, lastSeen: now)
            if viaLan { d.lanHost = src; d.lanSeen = now }
            if viaTs  { d.tsHost  = src; d.tsSeen  = now }
            devices.append(d)
            return true
        }
    }

    /// 局域网通道是否在线（lanTtl 内真从局域网收到过报文）
    func lanAlive(_ d: DeviceInfo) -> Bool {
        !d.lanHost.isEmpty && Date().timeIntervalSince(d.lanSeen) <= Engine.lanTtl
    }
    /// Tailscale 通道是否在线（tsTtl 内真从 100.x 收到过报文）
    func tsAlive(_ d: DeviceInfo) -> Bool {
        !d.tsHost.isEmpty && Date().timeIntervalSince(d.tsSeen) <= Engine.tsTtl
    }
    private func syncTargets() {
        var all: [String] = []
        for d in devices { if !d.lanHost.isEmpty { all.append(d.lanHost) }; if !d.tsHost.isEmpty { all.append(d.tsHost) } }
        all.append(contentsOf: tsTargets)   // 跨 Tailscale 拉到的 tailnet 设备 100.x 也作为单播探测目标
        discovery.setExtraTargets(all)
    }

    /// 用内嵌 OAuth client 拉取 tailnet 设备的 100.x，仅刷新「单播探测目标」。
    /// （已移除「花名册」显示层：tailnet 里没开 RayDrop 的设备不进列表，列表只显示真收到报文的在线设备。）
    private func refreshTailscale() {
        DispatchQueue.global().async {
            let devs = Tailscale.shared.peerTSDevices()
            guard !devs.isEmpty else { return }   // API 失败/空：保活现有 targets，下次周期重试
            DispatchQueue.main.async {
                let addrs = devs.map { $0.ip }
                let old = Set(self.tsTargets)
                self.tsTargets = addrs
                self.syncTargets()
                // ★ 新出现的 tailnet 设备：快速连发告知，克服跨洲 DERP 丢包、加速互相发现
                let fresh = addrs.filter { !old.contains($0) }
                if !fresh.isEmpty { self.burstAnnounce(fresh) }
            }
        }
    }
    /// 新出现的 tailnet 设备：6 次 × 0.3s 连发告知，让刚上线的对端数秒内必定收到本机公告
    private func burstAnnounce(_ ips: [String]) {
        DispatchQueue.global().async {
            for _ in 0..<6 {
                self.discovery.announceTo(ips)
                Thread.sleep(forTimeInterval: 0.3)
            }
        }
    }
    // MARK: - 接收服务自愈（治「列表显示在线但发不进来」）
    /// App 是否在前台。后台不重建监听——重建也会立刻被系统压回 waiting，且白耗电。
    var appActive = true
    /// 1s 巡检计数器：每 5 次（≈5s）做一次监听健康检查
    private var healthTick = 0

    /// 监听掉线起始时刻（nil = 正常）。只用来把「一直在重建」压成一条状态，不再每 5s 刷屏。
    private var listenDownAt: Date?
    /// 上一次上报过的监听端口：只用于「首次就绪 / 端口变了」时写一条日志
    private var lastListenPort: UInt16 = 0
    /// 最近一次发送结束的原因（"连接失败"/"连接 xx 超时"/"发送完成"…），用于判断是否值得自动重试
    private var lastSendReason = ""

    /// ★ v42：监听不在 ready 就重建。
    ///   动态端口下这是**零成本**操作（新 listener 直接拿一个新端口，绝不会撞 EADDRINUSE），
    ///   所以不再需要旧版的延迟重绑 / A-B 参数轮换 / 8s 启动看门狗 / 20s 宽限 / 指数退避。
    func ensureReceiverUp() {
        guard appActive else { return }
        if receiver.isListening { return }
        receiver.ensureUp()
        if listenDownAt == nil {
            listenDownAt = Date()
            addLog("接收服务未就绪，正在重建…")
        } else if let t = listenDownAt, Date().timeIntervalSince(t) > 180 {
            listenDownAt = Date()
            addLog("接收服务持续未就绪，仍在后台重试")
        }
    }

    /// 回到前台时调用：确认监听可用 + 立刻公告一轮 + 重查 tailnet 目标
    func onForeground() {
        appActive = true
        // 前台是「马上就要能收」的时刻：不在 ready 就立刻重建（动态端口，无成本）
        receiver.rebuildIfNeededNow()
        // ★ v36：回到前台时**重建 UDP 接收 socket**。换 Wi-Fi / 休眠唤醒后，老 socket
        //   可能一个包都收不到（对端却一切正常）→ 表现为"设备明明在线却看不到"。
        discovery.resetSockets()
        refreshTailscale()
    }

    /// 监听就绪（含重建成功）→ 立刻公告，让对端第一时间刷新本机在线状态与端口
    private func onReceiverReady(_ port: UInt16) {
        if listenDownAt != nil {
            listenDownAt = nil
            addLog("接收服务已恢复（端口 \(port)）")
        } else if lastListenPort != port {
            // 首次启动或端口变了（重建）→ 写一条，方便排查"对方连不上"时确认端口
            addLog("接收服务已就绪（端口 \(port)）")
        }
        lastListenPort = port
        discovery.announceAll()
    }

    /// 定期巡检（1s 一轮，及时反映上下线）：
    ///  ① 通道级过期：某条线路断开 → 立刻清空该通道，让它在列表里单独消失（不影响另一条）；
    ///  ② 两条通道都断了 → 整台设备从列表移除。
    ///  旧实现 5s 轮询 + 12s 整机 TTL → 最多 17s 才消失，现降到「LAN 4s / TS 6s + 1s 轮询」。
    private func cull() {
        let now = Date()
        var changed = false
        for i in devices.indices {
            if !devices[i].lanHost.isEmpty && now.timeIntervalSince(devices[i].lanSeen) > Engine.lanTtl {
                devices[i].lanHost = ""; devices[i].lanSeen = .distantPast; changed = true
            }
            if !devices[i].tsHost.isEmpty && now.timeIntervalSince(devices[i].tsSeen) > Engine.tsTtl {
                devices[i].tsHost = ""; devices[i].tsSeen = .distantPast; changed = true
            }
        }
        let kept = devices.filter { !$0.lanHost.isEmpty || !$0.tsHost.isEmpty }
        if kept.count != devices.count { devices = kept; changed = true }
        if changed { syncTargets() }
    }

    func setCode(_ c: String) {
        let c = c.trimmingCharacters(in: .whitespaces)
        if c.count == 3 && c.allSatisfy(\.isNumber) {
            RDStore.shared.myCode = c; myCode = c
            discovery.announceTo(devices.flatMap { [$0.lanHost, $0.tsHost] }.filter { !$0.isEmpty })
        }
    }
    func setName(_ n: String) { RDStore.shared.myName = n; myName = n }

    // ---- 顶部选类型/内容 → 暂存 ----
    func setPending(_ items: [SendItem], summary: String) {
        pendingItems = items
        DispatchQueue.main.async { self.pendingSummary = items.isEmpty ? "" : summary }
    }

    /// 收录「文件」选择器选中的文件：解析安全作用域 → **复制进本 App 的临时槽位**。
    ///
    /// ★ v41 修「明明显示已选 1 个文件，点设备就报『没有可发送的内容（文件均已失效）』」：
    ///   `UIDocumentPickerViewController(forOpeningContentTypes:asCopy:true)` 回来的 URL 并不保证
    ///   真在沙盒内 —— iCloud Drive、其它 App 的容器、部分系统 provider 即使 asCopy 也仍是
    ///   **安全作用域 URL**。旧实现直接把这种 URL 塞进 pendingItems，发送前预校验
    ///   `isReadableFile` 必然 false（未 startAccessing 就没有读权限）→ 整批被判失效。
    ///   现在统一 startAccessing → 复制到自己的 tempSlot → 用副本，跟照片路径保持一致。
    ///   复制放后台：几十 MB 的 ipa 在主线程复制会卡住界面（用户点了没反应）。
    func prepareDocuments(_ urls: [URL], done: @escaping () -> Void) {
        guard !urls.isEmpty else { done(); return }
        preparing = true
        status = "正在读取 \(urls.count) 个文件…"
        DispatchQueue.global(qos: .userInitiated).async {
            let fm = FileManager.default
            var okURLs: [URL] = []
            var fails: [String] = []
            for src in urls {
                let name = src.lastPathComponent.isEmpty ? "未命名文件" : src.lastPathComponent
                // 安全作用域：asCopy 的真沙盒路径会返回 false，此时无需 stop
                let scoped = src.startAccessingSecurityScopedResource()
                defer { if scoped { src.stopAccessingSecurityScopedResource() } }

                guard fm.fileExists(atPath: src.path) else {
                    fails.append("\(name)（文件不存在）")
                    continue
                }
                // iCloud 里「未下载」的占位文件：先请求下载，再等它落地（最多 5s）
                if !fm.isReadableFile(atPath: src.path) {
                    try? fm.startDownloadingUbiquitousItem(at: src)
                    var tries = 0
                    while !fm.isReadableFile(atPath: src.path) && tries < 25 {
                        Thread.sleep(forTimeInterval: 0.2)
                        tries += 1
                    }
                }
                // ★ 独立 UUID 子目录、保留原名（发送时对端看到的文件名就是原名）
                let dst = Engine.makeTempSlot(for: name)
                try? fm.removeItem(at: dst)
                do {
                    try fm.copyItem(at: src, to: dst)
                    let sz = ((try? fm.attributesOfItem(atPath: dst.path))?[.size] as? NSNumber)?.int64Value ?? 0
                    guard sz > 0 else {
                        try? fm.removeItem(at: dst)
                        fails.append("\(name)（0 字节，可能是空文件或尚未下载完）")
                        continue
                    }
                    okURLs.append(Engine.alignExtension(dst))   // 扩展名与真实容器对齐（只改名）
                } catch {
                    fails.append("\(name)（\(error.localizedDescription)）")
                }
            }
            DispatchQueue.main.async {
                self.preparing = false
                if !okURLs.isEmpty {
                    self.setPending(okURLs.map { .file($0) }, summary: "已选 \(okURLs.count) 个文件")
                }
                if fails.isEmpty {
                    self.status = okURLs.isEmpty ? "没有选中任何文件" : "已选 \(okURLs.count) 个文件，点下方设备发送"
                } else {
                    // ★ 失败绝不静默：旧行为是照常显示「已选 N 项」，用户以为能发，点了才发现发不出去
                    self.status = okURLs.isEmpty
                        ? "读取失败，未加入待发"
                        : "已选 \(okURLs.count) 个文件，另有 \(fails.count) 个读取失败"
                    self.addLog("以下文件未能加入待发：\(fails.joined(separator: "、"))")
                }
                done()
            }
        }
    }
    // MARK: - 照片/视频装载
    //
    /// 「选视频+照片一起发，对方只收到照片」的排查结论（v34 修）：
    ///
    /// 视频走的路径和照片有三处本质差别，旧代码在这三处全部踩中：
    ///
    /// ① **加载阶段：错误被静默吞掉。**
    ///    `provider.loadFileRepresentation(...) { url, _ in` 把 error 直接丢进 `_`，
    ///    拿不到 url 就 `urls[idx] = nil`，最后 `compactMap` 把 nil 全过滤掉，
    ///    界面还显示「已选 N 项」—— N 只统计成功的。照片小、几乎必成功；视频要导出/转码，
    ///    失败率高得多，于是**照片进列表、视频凭空消失，且没有任何提示**。
    ///
    /// ② **类型判定太窄。**
    ///    旧代码只判 `UTType.movie`，不是视频就直接拿 `UTType.image` 去 load。
    ///    慢动作、延时摄影、第三方 App 导入、iCloud 未下载完的片子，provider 可能只注册
    ///    `UTType.video` / `audiovisualContent` / `mpeg4Movie`，这一步必然失败；iCloud 里的
    ///    大视频还常因 `preferredAssetRepresentationMode = .automatic` 触发转码而超时。
    ///
    /// ③ **保存阶段：mime 表太窄，视频被判成非媒体。**
    ///    旧 `RD.mime(for:)` 只认 `.mp4/.mov`。视频临时文件后缀若是 `.m4v/.3gp/.avi` 或没有后缀，
    ///    就退化成 `application/octet-stream` → 接收端 `isMedia == false` → **连相册都不尝试写**，
    ///    文件只静静躺在「下载」里，用户翻相册自然"一个视频都没有"。
    ///
    /// 修法：① 失败必须计数并报出来（不静默）② 类型候选链 + `registeredTypeIdentifiers` 兜底
    /// ③ mime 表补全全部常见视频/图片后缀，并在接收端按扩展名反推真实 mime
    /// ④ `preferredAssetRepresentationMode = .current` 不转码，直接取原文件 ⑤ 并发压到 2 + 视频重试一次。

    /// 解析 provider 实际可用的类型：返回 (UTType identifier, 是否视频)
    private static func resolvePickType(_ provider: NSItemProvider) -> (id: String, isVideo: Bool)? {
        // 实况照片按「照片」取静帧，避免被当成视频导出成 .mov
        if provider.hasItemConformingToTypeIdentifier(UTType.livePhoto.identifier),
           provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
            return (UTType.image.identifier, false)
        }
        // ★ 优先请求 provider 实际注册的**具体**视频类型（com.apple.quicktime-movie / public.mpeg-4…），
        //   而不是笼统的 public.movie —— 只有要具体类型，系统才直接给原文件，
        //   不会为了"符合 public.movie"去导出/转码（大视频转码慢且容易中途失败）。
        let generic: Set<String> = [UTType.movie.identifier, UTType.video.identifier,
                                    UTType.audiovisualContent.identifier, UTType.content.identifier,
                                    UTType.item.identifier, UTType.data.identifier]
        for id in provider.registeredTypeIdentifiers where !generic.contains(id) {
            guard let t = UTType(id) else { continue }
            if t.conforms(to: .movie) || t.conforms(to: .video) { return (id, true) }
        }
        let videoCandidates: [UTType] = [.movie, .video, .audiovisualContent, .quickTimeMovie, .mpeg4Movie]
        for t in videoCandidates where provider.hasItemConformingToTypeIdentifier(t.identifier) {
            return (t.identifier, true)
        }
        let imageCandidates: [UTType] = [.image, .jpeg, .png, .heic, .gif, .webP, .tiff]
        for t in imageCandidates where provider.hasItemConformingToTypeIdentifier(t.identifier) {
            return (t.identifier, false)
        }
        // 兜底：直接扫 provider 注册的类型（有些来源的 identifier 不在上面白名单里）
        for id in provider.registeredTypeIdentifiers {
            guard let t = UTType(id) else { continue }
            if t.conforms(to: .movie) || t.conforms(to: .video) || t.conforms(to: .audiovisualContent) {
                return (id, true)
            }
            if t.conforms(to: .image) { return (id, false) }
        }
        return nil
    }

    /// 只允许 resume 一次的包装（provider 回调与超时可能同时到达，二次 resume 会直接崩）
    private final class Once<T> {
        private let lock = NSLock()
        private var cont: CheckedContinuation<T, Never>?
        init(_ c: CheckedContinuation<T, Never>) { cont = c }
        func fire(_ v: T) {
            lock.lock()
            guard let c = cont else { lock.unlock(); return }
            cont = nil
            lock.unlock()
            c.resume(returning: v)
        }
    }

    // MARK: - ★ v44 取文件：先要「笼统类型」，再退具体类型，最后字节/相册资源兜底

    /// 一个 provider 的「可用类型候选」，按「最可能拿到原文件」排序。
    ///
    /// ★ v44 的教训（真机日志原文）：
    ///   `第 2 项视频 (public.mpeg-4: Cannot load representation of type public.mpeg-4; …)`
    ///   `public.mpeg-4` 是**具体编码/容器**类型 —— 要它就意味着"必须给我这个格式"，
    ///   而 picker 配的是 `preferredAssetRepresentationMode = .current`（不许转码），
    ///   系统没有办法在不转码的前提下满足 → 直接报 Cannot load representation。
    ///   笼统的 `public.movie` 不限制编码，系统把手里那份原文件交出来即可，不需要转码。
    ///   所以顺序必须是：public.movie / public.image（笼统，零转换）→ provider 自报的具体类型
    ///   → 其他编码类型 → 字节/相册资源兜底。旧顺序把具体类型放第一，等于自己踩雷。
    private static func typeCandidates(_ provider: NSItemProvider, primary: String, isVideo: Bool) -> [String] {
        var list: [String] = []
        func add(_ id: String) {
            guard !id.isEmpty, !list.contains(id) else { return }
            guard provider.hasItemConformingToTypeIdentifier(id) else { return }
            list.append(id)
        }
        if isVideo {
            add(UTType.movie.identifier)               // ★ 第一档：笼统视频类型，不要求任何具体编码
            add(UTType.audiovisualContent.identifier)
            add(UTType.quickTimeMovie.identifier)
        } else {
            add(UTType.image.identifier)               // ★ 第一档：笼统图片类型
        }
        add(primary)
        for id in provider.registeredTypeIdentifiers {
            guard let t = UTType(id) else { continue }
            if isVideo {
                if t.conforms(to: .movie) || t.conforms(to: .video) || t.conforms(to: .audiovisualContent) { add(id) }
            } else if t.conforms(to: .image) {
                add(id)
            }
        }
        if isVideo {
            for t in [UTType.mpeg4Movie, .video] { add(t.identifier) }
        } else {
            for t in [UTType.jpeg, .png, .heic, .gif, .webP, .tiff, .image] { add(t.identifier) }
        }
        return list
    }

    /// 单次 `loadFileRepresentation` + 超时。返回 (沙盒副本, 失败原因)。
    /// 不用 DispatchSemaphore 阻塞线程：旧写法一次卡 300 秒，两条并发就把工作队列占死，
    /// 后续再选一次都排不进去（表现为「点了没反应」）。
    private static func awaitFile(_ provider: NSItemProvider, typeID: String,
                                  isVideo: Bool, timeout: TimeInterval) async -> (URL?, String) {
        await withCheckedContinuation { (cont: CheckedContinuation<(URL?, String), Never>) in
            let once = Once<(URL?, String)>(cont)
            provider.loadFileRepresentation(forTypeIdentifier: typeID) { url, err in
                // ⚠️ 系统给的临时文件在回调返回后即被删除 → 必须在回调内同步复制进沙盒
                if let u = url {
                    if let copy = Engine.copyIntoSandbox(u, isVideo: isVideo, typeID: typeID) {
                        once.fire((copy, ""))
                    } else {
                        once.fire((nil, "复制进沙盒失败"))
                    }
                } else {
                    once.fire((nil, err.map { $0.localizedDescription } ?? "系统没有返回文件"))
                }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                once.fire((nil, "超过 \(Int(timeout)) 秒无响应"))
            }
        }
    }

    /// 兜底通道：有些资产/系统版本只支持 data 通道，给不出临时文件 URL
    private static func awaitData(_ provider: NSItemProvider, typeID: String,
                                  timeout: TimeInterval) async -> (Data?, String) {
        await withCheckedContinuation { (cont: CheckedContinuation<(Data?, String), Never>) in
            let once = Once<(Data?, String)>(cont)
            provider.loadDataRepresentation(forTypeIdentifier: typeID) { data, err in
                if let d = data, !d.isEmpty {
                    once.fire((d, ""))
                } else {
                    once.fire((nil, err.map { $0.localizedDescription } ?? "系统没有返回数据"))
                }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                once.fire((nil, "超过 \(Int(timeout)) 秒无响应"))
            }
        }
    }

    /// 第三条通道：`loadItem` 直接要「对象」（NSURL / NSData）。
    /// 它和 `loadFileRepresentation` 走的是不同实现，iOS 15 上前者失败、后者能出东西的情况真实存在。
    private static func awaitItem(_ provider: NSItemProvider, typeID: String,
                                  isVideo: Bool, timeout: TimeInterval) async -> (URL?, String) {
        await withCheckedContinuation { (cont: CheckedContinuation<(URL?, String), Never>) in
            let once = Once<(URL?, String)>(cont)
            provider.loadItem(forTypeIdentifier: typeID, options: nil) { item, err in
                if let u = item as? URL {
                    if let copy = Engine.copyIntoSandbox(u, isVideo: isVideo, typeID: typeID) { once.fire((copy, "")) }
                    else { once.fire((nil, "复制进沙盒失败")) }
                    return
                }
                if let d = item as? Data, !d.isEmpty {
                    if let u = Engine.writeSandbox(d, typeID: typeID, isVideo: isVideo) { once.fire((u, "")) }
                    else { once.fire((nil, "写沙盒失败")) }
                    return
                }
                once.fire((nil, err.map { $0.localizedDescription } ?? "系统没有返回可用对象"))
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                once.fire((nil, "超过 \(Int(timeout)) 秒无响应"))
            }
        }
    }

    /// 最后兜底：**已有「读相册」权限**时，直接按 assetIdentifier 取该资产的原始资源写进沙盒。
    /// `PHAssetResourceManager.writeData` 给出的是原始资源字节，不做任何转码。
    /// 没有读权限就跳过（绝不弹新权限、绝不越权读 —— 越权在 iOS 17 上会被 TCC 直接杀进程）。
    private static func awaitLibraryResource(assetID: String, isVideo: Bool,
                                             timeout: TimeInterval) async -> (URL?, String) {
        guard PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized else {
            return (nil, "没有「读取相册」权限，跳过")
        }
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: [assetID], options: nil)
        guard let asset = assets.firstObject else { return (nil, "按 id 找不到该资产") }
        let all = PHAssetResource.assetResources(for: asset)
        let wanted: [PHAssetResourceType] = isVideo ? [.fullSizeVideo, .video] : [.fullSizePhoto, .photo]
        guard let res = all.first(where: { wanted.contains($0.type) }) else {
            return (nil, "该资产没有可用资源")
        }
        var name = res.originalFilename
        if (name as NSString).pathExtension.isEmpty {
            name += "." + (UTType(res.uniformTypeIdentifier)?.preferredFilenameExtension ?? (isVideo ? "mov" : "jpg"))
        }
        let dst = makeTempSlot(for: name)
        if FileManager.default.fileExists(atPath: dst.path) { try? FileManager.default.removeItem(at: dst) }
        return await withCheckedContinuation { (cont: CheckedContinuation<(URL?, String), Never>) in
            let once = Once<(URL?, String)>(cont)
            PHAssetResourceManager.default().writeData(for: res, toFile: dst, options: nil) { err in
                if let err = err { once.fire((nil, err.localizedDescription)) }
                else { once.fire((dst, "")) }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                once.fire((nil, "写入超时"))
            }
        }
    }

    /// 把内存字节写成沙盒文件（扩展名按类型标识补，没有就按视频/图片猜）
    private static func writeSandbox(_ data: Data, typeID: String, isVideo: Bool) -> URL? {
        let ext = UTType(typeID)?.preferredFilenameExtension ?? (isVideo ? "mov" : "jpg")
        let dst = makeTempSlot(for: "picked_" + String(UUID().uuidString.prefix(8)) + "." + ext)
        do {
            try data.write(to: dst, options: .atomic)
            return dst
        } catch {
            print("[RayDrop] write bytes failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// ★ 让文件名的扩展名与**真实字节**一致（只改名，一个字节都不动）。
    ///
    /// 这是「iOS 17 → iOS 15 视频进不了相册」的源头：那段视频原名是 `106644.jpeg`
    /// （相册里这条资产的原始文件名就是 .jpeg），发送端按扩展名算出 `image/jpeg`，
    /// 接收端于是把 9.8MB 的 QuickTime 容器当图片，用 `addResource(.photo)` 去写 →
    /// PhotoKit 直接拒收 `PHPhotosErrorDomain#3302`，而真正该走的视频路径一条都没试。
    /// 文件名会撒谎，文件头魔数不会。
    static func alignExtension(_ url: URL) -> URL {
        guard let sniffed = RDMediaSaver.sniffExt(url) else { return url }
        let cur = url.pathExtension.lowercased()
        let want = sniffed.lowercased()
        if cur == want { return url }
        // jpg / jpeg 视为同一族，不做改名（避免无意义的重命名）
        if (cur == "jpg" || cur == "jpeg") && (want == "jpg" || want == "jpeg") { return url }
        let dir = url.deletingLastPathComponent()
        let stem = (url.lastPathComponent as NSString).deletingPathExtension
        let dst = dir.appendingPathComponent(stem + "." + want)
        do {
            if FileManager.default.fileExists(atPath: dst.path) { try? FileManager.default.removeItem(at: dst) }
            try FileManager.default.moveItem(at: url, to: dst)
            print("[RayDrop] 扩展名按真实容器纠正：\(url.lastPathComponent) → \(dst.lastPathComponent)")
            return dst
        } catch {
            return url
        }
    }

    /// 取一项：file 通道 → loadItem 通道 → data 通道 → 相册原始资源，逐层兜底。
    /// 失败时把**每一层的真实原因**带回去（不再只说「第 1 项视频」）。
    ///
    /// 时长控制：整项设总预算（视频 240s / 照片 90s），第一档给足 120s
    /// （iCloud 里未下载的大视频要等它落地），后续档位只给 20s ——
    /// 失败的 provider 通常立刻报错，给长超时只会白等。
    private static func loadOne(_ provider: NSItemProvider, typeID: String, isVideo: Bool,
                                assetID: String?) async -> (URL?, String) {
        var reasons: [String] = []
        let cands = typeCandidates(provider, primary: typeID, isVideo: isVideo)
        let deadline = Date().addingTimeInterval(isVideo ? 240 : 90)

        // ① 要一份本地临时文件（最通用）
        for (n, id) in cands.enumerated() {
            let left = deadline.timeIntervalSinceNow
            if left < 4 { break }
            let (u, why) = await awaitFile(provider, typeID: id, isVideo: isVideo,
                                           timeout: min(left, n == 0 ? 120 : 20))
            if let u = u { return (alignExtension(u), "") }
            reasons.append("file \(shortType(id))：\(why)")
        }
        // ② loadItem：和 ① 是两套实现，iOS 15 上常有 ① 失败 ② 成功的情况
        for id in cands.prefix(2) {
            let left = deadline.timeIntervalSinceNow
            if left < 4 { break }
            let (u, why) = await awaitItem(provider, typeID: id, isVideo: isVideo, timeout: min(left, 25))
            if let u = u { return (alignExtension(u), "") }
            reasons.append("item \(shortType(id))：\(why)")
        }
        // ③ 直接要字节
        for id in cands.prefix(2) {
            let left = deadline.timeIntervalSinceNow
            if left < 4 { break }
            let (d, why) = await awaitData(provider, typeID: id, timeout: min(left, 60))
            if let d = d, let u = writeSandbox(d, typeID: id, isVideo: isVideo) {
                return (alignExtension(u), "")
            }
            reasons.append("data \(shortType(id))：\(why)")
        }
        // ④ 相册原始资源（只在已有读权限时；不弹新权限、不越权读）
        if let aid = assetID {
            let left = deadline.timeIntervalSinceNow
            if left > 4 {
                let (u, why) = await awaitLibraryResource(assetID: aid, isVideo: isVideo, timeout: min(left, 90))
                if let u = u { return (alignExtension(u), "") }
                reasons.append("相册资源：\(why)")
            }
        }
        // 失败信息里带上对端自报的类型，下次一眼能看出它到底支持什么
        let types = provider.registeredTypeIdentifiers.prefix(6).joined(separator: ",")
        return (nil, reasons.prefix(4).joined(separator: "；") + "｜自报类型：\(types)")
    }

    /// 类型标识缩短成便于阅读的形式（public.mpeg-4 → mpeg-4），只为日志好读
    private static func shortType(_ id: String) -> String {
        id.replacingOccurrences(of: "public.", with: "")
          .replacingOccurrences(of: "com.apple.", with: "")
    }

    /// 复制进沙盒临时槽位，并**保证有扩展名**（没有扩展名对端判不出 mime、也进不了相册）。
    /// 返回 nil 表示复制失败或得到 0 字节文件 —— 绝不像旧实现那样 `try?` 吞错后照样返回路径。
    private static func copyIntoSandbox(_ src: URL, isVideo: Bool, typeID: String) -> URL? {
        let fm = FileManager.default
        var name = src.lastPathComponent
        if name.isEmpty { name = "picked_" + UUID().uuidString }
        // 目录（实况照片的 .pvt 包等）：原样拷进来也发不出去，直接判失败并说明
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: src.path, isDirectory: &isDir), isDir.boolValue {
            print("[RayDrop] skip directory provider output: \(name)")
            return nil
        }
        if (name as NSString).pathExtension.isEmpty {
            let ext = UTType(typeID)?.preferredFilenameExtension ?? (isVideo ? "mov" : "jpg")
            name += "." + ext
        }
        let dst = Engine.makeTempSlot(for: name)
        do {
            if fm.fileExists(atPath: dst.path) { try? fm.removeItem(at: dst) }
            try fm.copyItem(at: src, to: dst)
            let sz = ((try? fm.attributesOfItem(atPath: dst.path))?[.size] as? NSNumber)?.int64Value ?? 0
            guard sz > 0 else {
                try? fm.removeItem(at: dst)
                print("[RayDrop] copied 0-byte file: \(name)")
                return nil
            }
            return dst
        } catch {
            print("[RayDrop] copy failed \(src.lastPathComponent): \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - ★ v44 自建相册选择器：严格按点选顺序导出原始资源

    /// 收录自建选择器选中的 asset。
    ///
    /// 与 `preparePhotos` 的两点根本区别：
    ///  1) **顺序可信**：传入数组就是用户点选的先后（选择器按点击顺序记录），
    ///     不再受 PHPicker「按相册顺序返回」的影响；
    ///  2) **取文件方式可靠**：走 `PHAssetResourceManager` 直接写原始资源，
    ///     不经过 `NSItemProvider`，所以不会再有 `Cannot load representation of type …`、
    ///     也不会因为「请求了具体编码类型 + 不许转码」而整项失败。
    ///
    /// 并发模型与 `preparePhotos` 一致：每批 2 项，批间串行，防止两条大视频同时导出撑爆内存。
    func prepareAssets(_ assets: [PHAsset], done: @escaping () -> Void) {
        guard !assets.isEmpty else { done(); return }
        let total = assets.count
        preparing = true
        status = "正在读取 \(total) 项…"

        let snapshot = assets
        Task.detached(priority: .userInitiated) {
            var slots: [URL?] = Array(repeating: nil, count: total)
            var errs: [Int: String] = [:]
            var kindOf: [Int: String] = [:]
            for (i, a) in snapshot.enumerated() {
                kindOf[i] = a.mediaType == .video ? "视频" : "照片"
            }
            var finished = 0
            var i = 0
            while i < total {
                let end = min(i + 2, total)
                await withTaskGroup(of: (Int, URL?, String).self) { group in
                    for idx in i..<end {
                        let a = snapshot[idx]
                        group.addTask {
                            let (u, why) = await Engine.exportAsset(a)
                            return (idx, u, why)
                        }
                    }
                    for await r in group {
                        slots[r.0] = r.1
                        if r.1 == nil { errs[r.0] = r.2.isEmpty ? "未知原因" : r.2 }
                        finished += 1
                        let f = finished
                        DispatchQueue.main.async { self.status = "正在读取 \(f)/\(total) 项…" }
                    }
                }
                i = end
            }

            let ok = slots.compactMap { $0 }
            let failedList: [String] = errs.keys.sorted().map { idx in
                let why = errs[idx] ?? "未知原因"
                let short = why.count > 220 ? String(why.prefix(220)) + "…" : why
                return "第 \(idx + 1) 项\(kindOf[idx] ?? "内容")（\(short)）"
            }

            DispatchQueue.main.async {
                self.preparing = false
                if ok.isEmpty {
                    self.pendingItems = []
                    self.pendingSummary = ""
                    self.status = failedList.isEmpty ? "没有选中任何内容" : "读取失败，未加入待发"
                    if !failedList.isEmpty { self.addLog("以下内容读取失败：\(failedList.joined(separator: "、"))") }
                } else {
                    self.pendingItems = ok.map { .file($0) }
                    self.pendingSummary = "已选 \(ok.count) 项"
                    if failedList.isEmpty {
                        self.status = "已选 \(ok.count) 项，点下方设备发送"
                    } else {
                        self.status = "已选 \(ok.count) 项，另有 \(failedList.count) 项读取失败"
                        self.addLog("有 \(failedList.count) 项未能加入待发：\(failedList.joined(separator: "；"))")
                    }
                }
                done()
            }
        }
    }

    /// 从 PHAsset 导出**原始文件**到沙盒，一个字节都不转。
    ///
    /// 资源挑选顺序：当前版本（.photo / .video，所见即所得）
    ///   → 原始版本（.fullSizePhoto / .fullSizeVideo，编辑前）
    ///   → 兜底取第一个。
    /// `isNetworkAccessAllowed = true`：iCloud 里只有缩略图的资源会自动下载原文件。
    static func exportAsset(_ asset: PHAsset) async -> (URL?, String) {
        await withCheckedContinuation { (cont: CheckedContinuation<(URL?, String), Never>) in
            let once = Once<(URL?, String)>(cont)

            let all = PHAssetResource.assetResources(for: asset)
            guard !all.isEmpty else {
                once.fire((nil, "这个资源没有可取的文件")); return
            }
            let res = all.first { $0.type == .photo || $0.type == .video }
                ?? all.first { $0.type == .fullSizePhoto || $0.type == .fullSizeVideo }
                ?? all[0]

            let raw = res.originalFilename.replacingOccurrences(of: "/", with: "_")
            let name = raw.isEmpty ? "asset_\(UUID().uuidString.prefix(8))" : raw
            let dst = Engine.makeTempSlot(for: name)

            let opt = PHAssetResourceRequestOptions()
            opt.isNetworkAccessAllowed = true

            PHAssetResourceManager.default().writeData(for: res, toFile: dst, options: opt) { err in
                if let err = err {
                    once.fire((nil, err.localizedDescription)); return
                }
                let sz = ((try? FileManager.default.attributesOfItem(atPath: dst.path))?[.size] as? NSNumber)?.int64Value ?? 0
                guard sz > 0 else {
                    try? FileManager.default.removeItem(at: dst)
                    once.fire((nil, "导出的文件为空")); return
                }
                // 名字与真实容器对齐（只改名，不动字节）
                once.fire((Engine.alignExtension(dst), ""))
            }

            // 兜底：iCloud 原文件下载卡住时不能无限等
            DispatchQueue.global().asyncAfter(deadline: .now() + 900) {
                once.fire((nil, "导出超过 15 分钟未完成（可能是 iCloud 原文件未下载完）"))
            }
        }
    }

    /// `done` 在所有项读完后回调（主线程）。providers 由本方法捕获的 `results` 持有，
    /// 与 picker 是否销毁无关 —— 所以调用方可以立即关掉 sheet，加载照常进行。
    ///
    /// 并发模型：小批推进（每批 2 项），批与批之间串行。不用信号量阻塞线程池，
    /// 也不会因为两条大视频同时导出而把内存撑爆。
    func preparePhotos(_ results: [PHPickerResult], done: @escaping () -> Void) {
        guard !results.isEmpty else { done(); return }
        let total = results.count
        preparing = true
        status = "正在读取 \(total) 项…"

        // 类型解析放主线程做（纯查表，不涉 IO）
        var jobs: [(idx: Int, provider: NSItemProvider, typeID: String, isVideo: Bool, assetID: String?)] = []
        var errs: [Int: String] = [:]
        var kindOf: [Int: String] = [:]
        for (idx, r) in results.enumerated() {
            guard let pick = Engine.resolvePickType(r.itemProvider) else {
                errs[idx] = "无法识别类型"
                kindOf[idx] = "内容"
                continue
            }
            jobs.append((idx, r.itemProvider, pick.id, pick.isVideo, r.assetIdentifier))
            kindOf[idx] = pick.isVideo ? "视频" : "照片"
        }

        let snapshot = jobs
        let failedSeed = errs
        let kindSeed = kindOf
        Task.detached(priority: .userInitiated) {
            // 拷成局部变量再改：避免在并发闭包里直接改外部 var
            var errs = failedSeed
            let kindOf = kindSeed
            var slots: [URL?] = Array(repeating: nil, count: total)
            var finished = 0
            var i = 0
            while i < snapshot.count {
                let batch = Array(snapshot[i..<min(i + 2, snapshot.count)])
                await withTaskGroup(of: (Int, URL?, String).self) { group in
                    for j in batch {
                        group.addTask {
                            let (u, why) = await Engine.loadOne(j.provider, typeID: j.typeID,
                                                               isVideo: j.isVideo, assetID: j.assetID)
                            return (j.idx, u, why)
                        }
                    }
                    for await r in group {
                        slots[r.0] = r.1
                        if r.1 == nil { errs[r.0] = r.2.isEmpty ? "未知原因" : r.2 }
                        finished += 1
                        let f = finished
                        DispatchQueue.main.async { self.status = "正在读取 \(f)/\(total) 项…" }
                    }
                }
                i += batch.count
            }

            let ok = slots.compactMap { $0 }
            let failedList: [String] = errs.keys.sorted().map { idx in
                let why = errs[idx] ?? "未知原因"
                let short = why.count > 220 ? String(why.prefix(220)) + "…" : why
                return "第 \(idx + 1) 项\(kindOf[idx] ?? "内容")（\(short)）"
            }

            DispatchQueue.main.async {
                self.preparing = false
                if ok.isEmpty {
                    self.pendingItems = []
                    self.pendingSummary = ""
                    self.status = failedList.isEmpty ? "没有选中任何内容" : "读取失败，未加入待发"
                    if !failedList.isEmpty { self.addLog("以下内容读取失败：\(failedList.joined(separator: "、"))") }
                } else {
                    self.pendingItems = ok.map { .file($0) }
                    self.pendingSummary = "已选 \(ok.count) 项"
                    if failedList.isEmpty {
                        self.status = "已选 \(ok.count) 项，点下方设备发送"
                    } else {
                        // ★ 失败绝不静默：给出是哪一项、什么原因（不再只有「第 1 项视频」）
                        self.status = "已选 \(ok.count) 项，另有 \(failedList.count) 项读取失败"
                        self.addLog("有 \(failedList.count) 项未能加入待发：\(failedList.joined(separator: "；"))")
                    }
                }
                done()
            }
        }
    }

    /// 点设备 → 发送暂存内容（先选类型内容，再点设备发出）
    ///
    /// ★ v41 修「点设备没反应，连点几下才突然开始发」：
    ///   旧实现的可视反馈全靠 `sender.onStart`（TCP ready + 握手 ACK 之后才亮），
    ///   连接/超时那十几秒里界面完全静止；而且没有重入保护，每点一下都新建一条连接，
    ///   全部写进同一个 conn 字段互相踩。现在：点下即置「连接中」+ 设备行转圈禁点，
    ///   并在调用层就把重复点击挡掉（`sendingToID`/`txActive` 非空直接提示）。
    func sendPending(to dev: DeviceInfo, host: String) {
        if sendingToID != nil || txActive {
            status = "正在发送，请稍候…"
            addLog("上一条还没结束，等它完成再点设备")
            return
        }
        if preparing {
            status = "正在读取所选内容，请稍等…"
            addLog("所选内容还在读取（大视频导出较慢），顶部显示「已选 N 项」后再点设备")
            return
        }
        // ★ v42：端口 0 = 对方接收服务还没起来（刚启动 / 刚回前台重建）
        guard dev.port != 0 else {
            status = "\(dev.name) 的接收服务还没就绪，请稍等再试"
            addLog("\(dev.name) 尚未上报接收端口，等它公告后（约 2 秒）再点")
            return
        }
        guard !pendingItems.isEmpty else {
            status = "请先在顶部选择要发送的内容（照片/文件/文本）"
            addLog("还没有待发内容：先点「照片 / 文件 / 文本」选好，再点设备")
            return
        }
        let items = pendingItems
        beginSend(to: dev, host: host, items: items) { ok in
            // ★ 成功才清空暂存 + 清理临时副本；失败保留，用户可直接重试，不用重新选一遍
            if ok {
                self.pendingItems = []
                self.pendingSummary = ""
                self.clearPendingTempFiles()
            } else {
                self.status = "发送未完成，已选内容仍保留，可重试"
            }
        }
    }

    /// 统一的「点设备 → 发送」入口：**立刻**给出连接中反馈 + 锁设备行 + 防重入。
    private func beginSend(to dev: DeviceInfo, host: String, items: [SendItem], done: @escaping (Bool) -> Void) {
        startSend(to: dev, host: host, items: items, retryLeft: 1, done: done)
    }

    /// ★ v42：允许**自动重试一次**。端口是动态的，对端刚从后台回来重建过监听时，
    ///   我们手上的端口就是旧的 → TCP 直接 RST。这种失败重试一次（并请求对端重播公告）就能成，
    ///   不该让用户自己去猜"是不是没点上"。
    private func startSend(to dev: DeviceInfo, host: String, items: [SendItem],
                           retryLeft: Int, done: @escaping (Bool) -> Void) {
        sendingToID = dev.id
        txActive = true; txUp = true; txTotal = items.count; paused = false
        status = "正在连接 \(dev.name)…"
        progress = "连接中…"
        addLog("准备发送 \(items.count) 项 → \(dev.name)（\(host):\(dev.port)），正在连接…")
        sender.send(host: host, port: dev.port, peerName: dev.name, items: items) { ok in
            DispatchQueue.main.async {
                self.sendingToID = nil
                let why = self.lastSendReason
                let portStale = why.contains("连接失败") || why.contains("超时（")
                if !ok && retryLeft > 0 && portStale {
                    // 让对端立刻重播一轮公告（把最新端口带回来），1 秒后用新端口再试
                    self.discovery.reply(to: host)
                    self.status = "连接失败，正在用最新端口重试…"
                    self.addLog("连接 \(dev.name) 失败（\(why)），1 秒后用最新端口自动重试")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                        let fresh = self.devices.first { $0.id == dev.id } ?? dev
                        self.startSend(to: fresh, host: host, items: items,
                                       retryLeft: retryLeft - 1, done: done)
                    }
                    return
                }
                done(ok)
            }
        }
    }

    // ---- 分享扩展：读取 App Group 共享容器里暂存的文件 ----
    static let appGroupID = "group.com.raydrop.ios"
    static var sharedDir: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID)
    }

    /// 主 APP 启动/回到前台时消费分享扩展写入的文件
    ///
    /// ⚠️ 关键：取走的内容必须**立即从 inbox 删除**，否则每次启动都会把上一批又读一遍，
    /// 表现就是「关掉重开还在，第二次分享变成两个，越积越多」。这里读完即删，并顺带清理过期残留。
    func consumeSharedItems() {
        guard let dir = Engine.sharedDir else { return }
        let inbox = dir.appendingPathComponent("inbox")

        // ★ v47：读走分享扩展留下的跳转诊断（它用哪条路把 App 拉起来的），读完即删。
        //   这条信息是排障唯一线索 —— 万一某台手机上「自动跳转」失效，日志里能直接看出来。
        var jumpNote = ""
        let diagURL = dir.appendingPathComponent("last_share_diag.txt")
        if let t = try? String(contentsOf: diagURL, encoding: .utf8) {
            jumpNote = t.trimmingCharacters(in: .whitespacesAndNewlines)
            try? FileManager.default.removeItem(at: diagURL)
        }

        // 1) 清理超过 1 小时的残留（上次崩溃/被杀进程留下的），避免历史文件再冒出来
        if let olds = try? FileManager.default.contentsOfDirectory(at: inbox, includingPropertiesForKeys: [.contentModificationDateKey]) {
            for old in olds {
                let age = (try? FileManager.default.attributesOfItem(atPath: old.path)[.modificationDate] as? Date)
                    .map { Date().timeIntervalSince($0) } ?? 0
                if age > 3600 { try? FileManager.default.removeItem(at: old) }
            }
        }

        let files = (try? FileManager.default.contentsOfDirectory(at: inbox, includingPropertiesForKeys: nil)) ?? []
        guard !files.isEmpty else { return }
        var got: [SharedItem] = []
        for f in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let name = f.lastPathComponent
            // 分享扩展用 "t_" 开头表示文本
            if name.hasPrefix("t_") {
                let t = (try? String(contentsOf: f, encoding: .utf8)) ?? ""
                if !t.isEmpty {
                    got.append(SharedItem(url: nil, text: t, name: "共享文本", size: Int64(t.count), kind: "text", isImage: false, isVideo: false))
                }
                try? FileManager.default.removeItem(at: f)   // 取走即删
            } else {
                // 文件名格式 "f_<原名>"，还原成发送端的真实名字
                let real = name.hasPrefix("f_") ? String(name.dropFirst(2)) : name
                let attrs = (try? FileManager.default.attributesOfItem(atPath: f.path)) ?? [:]
                let sz = (attrs[.size] as? NSNumber)?.int64Value ?? 0
                // 移到临时目录（App Group 容器文件不能长期引用），同时从 inbox 移除。
                // ★ 放进独立 UUID 子目录、保留原名——绝不能在文件名前拼 UUID（那串会跟着发给对端）
                let tmp = tempSlot(for: real)
                try? FileManager.default.removeItem(at: tmp)
                do {
                    try FileManager.default.moveItem(at: f, to: tmp)   // move 而非 copy：inbox 里的原件随之消失
                } catch {
                    try? FileManager.default.copyItem(at: f, to: tmp)
                    try? FileManager.default.removeItem(at: f)
                }
                // ★ v43：扩展名按真实容器纠正（分享进来的 .jpeg 也可能是个 mov）
                let aligned = Engine.alignExtension(tmp)
                let finalName = aligned.lastPathComponent
                let fext = (finalName as NSString).pathExtension.lowercased()
                let fIsImg = ["jpg", "jpeg", "png", "heic", "heif", "webp", "gif", "bmp"].contains(fext)
                let fIsVid = ["mp4", "mov", "m4v", "mkv", "avi", "3gp", "ts"].contains(fext)
                got.append(SharedItem(url: aligned, text: nil, name: finalName, size: sz, kind: "file",
                                      isImage: fIsImg, isVideo: fIsVid))
            }
        }
        DispatchQueue.main.async {
            guard !got.isEmpty else { return }
            self.sharedItems = got
            self.showSharePrompt = true
            self.addLog("收到分享内容 \(got.count) 项，请选择设备发送")
            if !jumpNote.isEmpty { self.addLog("（\(jumpNote)）") }
        }
    }

    func clearShared() { sharedItems = [] }

    /// 关闭分享面板：本次分享即结束，清空暂存（下次启动不会再次出现）
    func dismissShareInbox() {
        sharedItems = []
        showSharePrompt = false
    }

    /// 把分享来的内容发给指定设备（发送后自动清空本次分享）
    func sendShared(to dev: DeviceInfo, host: String) {
        guard !sharedItems.isEmpty else { return }
        if sendingToID != nil || txActive {
            addLog("上一条还没结束，等它完成再点设备")
            return
        }
        var items: [SendItem] = []
        for it in sharedItems {
            if it.kind == "text", let t = it.text { items.append(.text(t)) }
            else if let u = it.url { items.append(.file(u)) }
        }
        guard !items.isEmpty else { dismissShareInbox(); return }
        // 先清空：无论发送成功与否，这次分享都已经结束
        dismissShareInbox()
        beginSend(to: dev, host: host, items: items) { ok in
            self.addLog(ok ? "分享内容已全部发送" : "分享内容发送失败")
            if ok { self.clearPendingTempFiles() }
        }
    }

    /// 清理本轮分享复制到临时目录的内容（连同各自的 rdshare_ 子目录），避免长期占用空间。
    /// ★ 只删自己建的 rdshare_ 前缀目录，别误删保活音频 rd_keepalive.wav。
    /// ⚠️ 发送失败时不要调它 —— 暂存内容还在用，删了就没法重试。
    func clearPendingTempFiles() {
        let tmp = FileManager.default.temporaryDirectory
        guard let fs = try? FileManager.default.contentsOfDirectory(at: tmp, includingPropertiesForKeys: nil) else { return }
        for f in fs where f.lastPathComponent.hasPrefix("rdshare_") {
            try? FileManager.default.removeItem(at: f)
        }
    }

    /// ★ 把外部文件放进临时目录的「独占槽位」，**保持原文件名**。
    ///   历史 bug：以前是 `UUID()-原名`，发送时直接用 `lastPathComponent`，于是对端收到的文件名
    ///   变成 `D17486E5-…-raydrop-v32`。改为放进独立 UUID 子目录，末段仍是原名，且不同项互不撞名。
    private func tempSlot(for name: String) -> URL { Engine.makeTempSlot(for: name) }

    /// 静态版（供 `preparePhotos` 的后台队列调用）：放进独立 UUID 子目录、保留原名。
    static func makeTempSlot(for name: String) -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("rdshare_" + UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(name)
    }
}

// MARK: - 主界面（发送类型 → 设备 → 状态）
struct ContentView: View {
    @StateObject var engine = Engine()
    @State var showPhoto = false
    @State var showPicker = false
    @State var showDoc = false
    @State var showText = false
    @State var textDraft = ""
    @State var editName = false
    @State var editNameDraft = ""
    @State var showShareInbox = false
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                header
                Divider()
                kindBar
                if !engine.pendingSummary.isEmpty { pendingHint }
                Divider()
                deviceList
                Divider()
                transferBar
                Divider()
                logView
            }
            .navigationTitle("RayDrop锐传")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    // ★ 单击直达：一下点开系统「文件」App（不再折叠成菜单，少一次点击）。
                    //   必须显式给足点按区域（frame + contentShape）：新版 iOS 把工具栏按钮的可点区域
                    //   缩到图标字形本身，导致「看着在那儿、却要找准点才能点开」——这里撑成 44×44。
                    Button(action: openFiles) {
                        Image(systemName: "folder")
                            .font(.system(size: 17, weight: .semibold))
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("打开文件浏览器")
                }
            }
        }
        // ★ v44：自建全屏选择器（最新在右下、往上拉看更早、编号 = 发送顺序）
        //   用 fullScreenCover 而不是 sheet：sheet 下拉就会关掉，用户要的是独立整页。
        .fullScreenCover(isPresented: $showPicker) {
            AssetPickerView(
                onCancel: { showPicker = false },
                onFallback: {
                    // 没有相册权限 → 退回系统选择器（那个不需要授权）
                    showPicker = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { showPhoto = true }
                },
                onDone: { assets in
                    showPicker = false
                    engine.prepareAssets(assets) { }
                }
            )
        }
        .sheet(isPresented: $showPhoto) {
            // 关掉 sheet 不影响加载：providers 由 preparePhotos 捕获持有。
            // picker 里也不再调 dismiss()，只由这里统一关闭（两处同时关会互相干扰）。
            PhotoPicker { results in
                guard !results.isEmpty else { showPhoto = false; return }
                showPhoto = false
                engine.preparePhotos(results) { }
            }
        }
        .sheet(isPresented: $showDoc) {
            // ★ 先关 sheet 再收录：复制放到后台，大文件（几十 MB）不卡界面；
            //   直接 setPending(urls) 用 picker 给的 URL 会因安全作用域读不了，详见 prepareDocuments。
            DocPicker { urls in
                showDoc = false
                engine.prepareDocuments(urls) { }
            }
        }
        .sheet(isPresented: $showText) {
            TextInputSheet(text: $textDraft) { txt in
                engine.setPending([.text(txt)], summary: "已选 1 段文本"); showText = false; textDraft = ""
            }
        }
        .alert("文本来自 \(engine.receivedFrom)", isPresented: $engine.showRecvText) {
            Button("复制") { UIPasteboard.general.string = engine.receivedText }
            Button("关闭", role: .cancel) {}
        } message: { Text(engine.receivedText) }
        .sheet(isPresented: $engine.showSaveFile) {
            if let u = engine.lastReceivedFile { DocExportPicker(url: u) }
        }
        // 改名只用 sheet：iOS 15 的 .alert 无法承载 TextField（会只弹按钮没有输入框），
        // 且同一个 Bool 同时驱动 alert 与 sheet 时 alert 会抢先弹出把 sheet 挡住。
        .sheet(isPresented: $editName) {
            NameEditSheet(name: $editNameDraft) { txt in
                if !txt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { engine.setName(txt) }
                editName = false
            } onCancel: { editName = false }
        }
        .sheet(isPresented: $engine.showSharePrompt) { ShareInboxSheet(engine: engine) }
        .onReceive(NotificationCenter.default.publisher(for: .rdAppShouldScanInbox)) { _ in engine.consumeSharedItems() }
        .onAppear { engine.appActive = (scenePhase == .active); engine.start(); engine.consumeSharedItems() }
        .onChange(of: scenePhase) { phase in
            // ★ 回到前台：确认接收监听可用 + 立刻公告一轮，修正「对端显示在线却发不进来」
            engine.appActive = (phase == .active)
            if phase == .active { engine.onForeground() }
        }
    }

    /// 只保留设备名称：前缀加粗大字体，点一下直接编辑（不再显示 3 位码与铅笔图标）
    private var header: some View {
        Button {
            editNameDraft = engine.myName
            editName = true
        } label: {            HStack(spacing: 4) {
                Text("设备名称：").font(.headline)
                Text(engine.myName).font(.title3.weight(.bold))
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal).padding(.top, 4)
    }
    /// 快速打开系统「文件」App：shareddocuments 能直达「我的 iPhone」；失败依次回退
    private func openFiles() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let candidates: [URL] = [
            URL(string: "shareddocuments://")!,
            docs,
            URL(fileURLWithPath: NSHomeDirectory()),
            URL(string: "file://")!
        ]
        for u in candidates where UIApplication.shared.canOpenURL(u) {
            UIApplication.shared.open(u, options: [:], completionHandler: nil)
            return
        }
    }

    private var kindBar: some View {
        HStack(spacing: 0) {
            KindButton(icon: "photo", title: "照片", tint: .blue) { showPicker = true }
            KindButton(icon: "folder", title: "文件", tint: .green) { showDoc = true }
            KindButton(icon: "textformat", title: "文本", tint: .orange) { showText = true }
        }
        .padding(.vertical, 8)
    }
    private var pendingHint: some View {
        HStack(spacing: 4) { Image(systemName: "checkmark.circle.fill").foregroundColor(.green); Text(engine.pendingSummary).font(.caption) }
            .padding(.horizontal).padding(.bottom, 4)
    }

    private var deviceList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                // ★ 列表只显示「真从对应通道收到过报文」的设备（各自窗口内）；两条都断就整台消失。
                //   已移除「Tailscale · 离线」灰显组：离线设备不再进列表。
                let lan = engine.devices.filter { engine.lanAlive($0) }
                let ts = engine.devices.filter { engine.tsAlive($0) }
                if lan.isEmpty && ts.isEmpty {
                    Text("未发现设备，等待广播/探测…").foregroundColor(.gray).font(.footnote).padding(.horizontal)
                } else {
                    if !lan.isEmpty {
                        Text("【局域网】").font(.caption2).foregroundColor(.secondary).padding(.horizontal)
                        ForEach(lan) { devRow($0, $0.lanHost) }
                    }
                    if !ts.isEmpty {
                        Text("【Tailscale】").font(.caption2).foregroundColor(.secondary).padding(.horizontal).padding(.top, 4)
                        ForEach(ts) { devRow($0, $0.tsHost) }
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }
    private func devRow(_ d: Engine.DeviceInfo, _ host: String) -> some View {
        // ★ 该行正在发送（含「连接中」）：立刻显示转圈并禁用，点下去马上有视觉回应，
        //   也不会被连点成多条并发连接。
        let busy = engine.sendingToID == d.id
        return Button { engine.sendPending(to: d, host: host) } label: {
            HStack(spacing: 10) {
                Image(systemName: d.isComputer ? "desktopcomputer" : "iphone")
                    .font(.title3).frame(width: 28)
                VStack(alignment: .leading, spacing: 1) {
                    Text("\(d.name)").font(.subheadline.weight(.medium))
                    Text(busy ? "正在连接/发送…" : host).font(.caption2).foregroundColor(.secondary)
                }
                Spacer()
                if busy {
                    ProgressView().scaleEffect(0.8)
                } else {
                    Image(systemName: "arrow.up.circle.fill").foregroundColor(.accentColor)
                }
            }
            .padding(.horizontal).padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(busy)
    }

    private var transferBar: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(engine.status).font(.caption).lineLimit(1)
                Spacer()
                if !engine.progress.isEmpty { Text(engine.progress).font(.caption).foregroundColor(.secondary) }
            }
            .padding(.top, 18)      // ★ 状态区整体下移，与上方设备列表拉开距离
            if engine.txActive {
                HStack(spacing: 10) {
                    Button(engine.paused ? "继续" : "暂停") { engine.togglePause() }.buttonStyle(.bordered).controlSize(.small)
                    Button("终止", role: .destructive) { engine.abortTx() }.buttonStyle(.bordered).controlSize(.small)
                }
            }
        }
        .padding(.horizontal).padding(.vertical, 5)
    }

    private var logView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(engine.logEntries) { e in
                    if e.isHeader {
                        Rectangle().fill(Color.secondary.opacity(0.35)).frame(height: 1)
                        Text(e.text).font(.caption2).foregroundColor(.secondary)
                        Rectangle().fill(Color.secondary.opacity(0.35)).frame(height: 1)
                    } else {
                        Text(e.text + (e.repeats > 1 ? "（×\(e.repeats)）" : "")).font(.caption2).foregroundColor(e.inColor)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal).padding(.vertical, 4)
        }
    }
}

/// 发送类型按钮（图标 + 文字）
struct KindButton: View {
    let icon: String; let title: String; let tint: Color; let action: () -> Void
    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 26, weight: .semibold)).foregroundColor(tint)
                Text(title).font(.caption)
            }
            .frame(maxWidth: .infinity).padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// 文本输入面板（多行，避免 alert 不支持输入控件）
struct TextInputSheet: View {
    @Binding var text: String
    let onSend: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationView {
            TextEditor(text: $text).padding(6).frame(maxWidth: .infinity, maxHeight: .infinity)
                .navigationTitle("输入要发送的文本").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("确定") {
                            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { onSend(text) } else { dismiss() }
                        }
                    }
                }
        }
    }
}

/// 设备名称编辑弹窗（用 sheet 而非 alert —— iOS 15 的 alert 不渲染 TextField）
struct NameEditSheet: View {
    @Binding var name: String
    let onSave: (String) -> Void
    let onCancel: () -> Void
    @FocusState var focused: Bool

    var body: some View {
        NavigationView {
            TextField("设备名称", text: $name)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .padding(14)
                .navigationTitle("修改设备名称")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("取消", action: onCancel) }
                    ToolbarItem(placement: .confirmationAction) { Button("保存") { onSave(name) } }
                }
        }
        .navigationViewStyle(.stack)
        .onAppear { focused = true }
    }
}

/// 分享进来的文件：App 被唤起时列出，选设备即可发送
struct ShareInboxSheet: View {
    @ObservedObject var engine: Engine
    @Environment(\.dismiss) private var dismiss

    /// ★ v47：只有一台设备在线时返回它（连同可用的主机地址）；0 台或多台返回 nil。
    ///   多台时不给大按钮 —— 猜错对象就把私密照片发错人了。
    private var onlyAliveDevice: (Engine.DeviceInfo, String)? {
        let alive = engine.devices.filter { engine.lanAlive($0) || engine.tsAlive($0) }
        guard alive.count == 1, let d = alive.first else { return nil }
        return (d, engine.lanAlive(d) ? d.lanHost : d.tsHost)
    }

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                if engine.sharedItems.isEmpty {
                    Text("没有收到分享内容").foregroundColor(.gray).padding(20)
                } else {
                    List {
                        Section(header: Text("共 \(engine.sharedItems.count) 项，点击设备即可发送")) {
                            ForEach(Array(engine.sharedItems.enumerated()), id: \.offset) { idx, item in
                                HStack {
                                    Image(systemName: item.kind == "text" ? "textformat" : (item.isImage ? "photo" : (item.isVideo ? "film" : "doc")))
                                        .foregroundColor(.blue).frame(width: 26)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(item.name).font(.subheadline).lineLimit(1)
                                        Text(item.sizeText).font(.caption2).foregroundColor(.secondary)
                                    }
                                }
                            }
                            .onDelete { engine.sharedItems.remove(atOffsets: $0) }
                        }
                    }
                }
                Divider()
                // ★ v47：只发现一台设备时给一个大按钮，省得在列表里找
                if let one = onlyAliveDevice {
                    Button {
                        engine.sendShared(to: one.0, host: one.1)
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: one.0.isComputer ? "desktopcomputer" : "iphone")
                            Text("发给 \(one.0.name)").fontWeight(.semibold)
                            Spacer()
                            Image(systemName: "arrow.up.circle.fill")
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .padding(.horizontal).padding(.top, 10)
                }
                if engine.devices.isEmpty {
                    Text("未发现设备…").foregroundColor(.gray).padding(12)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(engine.devices.filter { engine.lanAlive($0) }) { d in devBtn(d, d.lanHost) }
                            ForEach(engine.devices.filter { engine.tsAlive($0) }) { d in devBtn(d, d.tsHost) }
                        }
                        .padding(.horizontal).padding(.vertical, 6)
                    }
                    .frame(maxHeight: 210)
                }
                HStack {
                    Button("清空") { engine.clearShared() }.padding(.horizontal, 6)
                    Spacer()
                    // 关闭即视为本次分享结束：清空暂存，下次启动不会再次出现
                    Button("关闭") { engine.dismissShareInbox() }.buttonStyle(.borderedProminent)
                }
                .padding(10)
            }
            .navigationTitle("分享到 RayDrop").navigationBarTitleDisplayMode(.inline)
        }
        .navigationViewStyle(.stack)
    }

    private func devBtn(_ d: Engine.DeviceInfo, _ host: String) -> some View {
        Button {
            engine.sendShared(to: d, host: host)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: d.isComputer ? "desktopcomputer" : "iphone").font(.title3).frame(width: 28)
                VStack(alignment: .leading, spacing: 1) {
                    Text("\(d.name)").font(.subheadline.weight(.medium))
                    Text(host).font(.caption2).foregroundColor(.secondary)
                }
                Spacer()
                Image(systemName: "arrow.up.circle.fill").foregroundColor(.accentColor)
            }
            .padding(.vertical, 6).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct PhotoPicker: UIViewControllerRepresentable {
    let onPick: ([PHPickerResult]) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }
    func makeUIViewController(context: Context) -> PHPickerViewController {
        // ★ 用 photoLibrary 初始化：这样 PHPickerResult.assetIdentifier 才有值，
        //   最后兜底（无读权限时用不到的相册原始资源路径）才有 id 可用。
        //   PHPicker 本身不需要相册权限，这里也不会多弹任何授权框。
        var cfg = PHPickerConfiguration(photoLibrary: .shared())
        cfg.selectionLimit = 0; cfg.filter = .any(of: [.images, .videos])
        // ★ preferredAssetRepresentationMode = .current：不强制转码，直接用原始文件，
        //   视频能秒取（旧默认 .automatic 会对部分片子走转码，慢且易中途失败）
        cfg.preferredAssetRepresentationMode = .current
        let pc = PHPickerViewController(configuration: cfg); pc.delegate = context.coordinator; return pc
    }
    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}
    class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let onPick: ([PHPickerResult]) -> Void
        init(onPick: @escaping ([PHPickerResult]) -> Void) { self.onPick = onPick }
        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            // 只把结果交给上层；关闭统一由上层 sheet 绑定控制（这里再 dismiss 一次会重复）。
            // providers 被上层捕获持有，之后异步加载不受 picker 销毁影响。
            onPick(results)
        }
    }
}
struct DocPicker: UIViewControllerRepresentable {
    let onPick: ([URL]) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let pc = UIDocumentPickerViewController(forOpeningContentTypes: [UTType.item], asCopy: true)
        pc.allowsMultipleSelection = true; pc.delegate = context.coordinator; return pc
    }
    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}
    class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: ([URL]) -> Void
        init(onPick: @escaping ([URL]) -> Void) { self.onPick = onPick }
        func documentPicker(_ c: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) { onPick(urls) }
        func documentPickerWasCancelled(_ c: UIDocumentPickerViewController) {}
    }
}
struct DocExportPicker: UIViewControllerRepresentable {
    let url: URL
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let pc = UIDocumentPickerViewController(forExporting: [url], asCopy: true); pc.delegate = context.coordinator; return pc
    }
    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}
    class Coordinator: NSObject, UIDocumentPickerDelegate {
        func documentPicker(_ c: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {}
        func documentPickerWasCancelled(_ c: UIDocumentPickerViewController) {}
    }
}

@main
struct RayDropApp: App {
    @UIApplicationDelegateAdaptor(RDAppDelegate.self) var appDelegate
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView()
                .onChange(of: scenePhase) { phase in
                    // 回前台时检查分享扩展是否放了新文件
                    if phase == .active { NotificationCenter.default.post(name: .rdAppShouldScanInbox, object: nil) }
                }
        }
    }
}

extension Notification.Name { static let rdAppShouldScanInbox = Notification.Name("rdAppShouldScanInbox") }
