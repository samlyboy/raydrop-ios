import Foundation
import SwiftUI
import PhotosUI
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
    struct LogEntry: Identifiable { let id = UUID(); let text: String; let inColor: Color; let isHeader: Bool }

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
    private func addEntry(_ text: String, _ color: Color, header: Bool = false) {
        DispatchQueue.main.async {
            let at: Int
            if header { at = 0 }
            else if self.logEntries.first?.isHeader == true { at = 1 }
            else { at = 0 }
            self.logEntries.insert(LogEntry(text: text, inColor: color, isHeader: header), at: at)
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
    }

    /// 可选出口：把最近收到的文件另存到别处（如 iCloud 云盘）。
    /// 默认接收已全自动存入「下载」，这里只作为额外的主动导出入口。
    func exportLastReceived() {
        guard lastReceivedFile != nil else { return }
        showSaveFile = true
    }

    func start() {
        if didStart { return }; didStart = true
        receiver.onStatus = { [weak self] s in DispatchQueue.main.async { self?.status = s } }
        // ★ 监听就绪（含被系统挂起后的自动重建）→ 立刻公告一轮，让对端马上刷新本机在线状态
        receiver.onListening = { [weak self] in self?.onReceiverReady() }
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
        sender.onEnd = { [weak self] ok, msg in self?.endTx(ok: ok, msg: msg) }
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
        let port = UInt16((o["port"] as? NSNumber)?.intValue ?? Int(RD.tcpPort))

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
            devices[i].port = port; devices[i].lastSeen = now
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

    /// ★ 监听不在 ready 就重建，并立刻重新公告。
    ///   根因：iOS 把 App 压到后台/被抢占时 NWListener 会掉到 waiting/failed，套接字失效 →
    ///   对端 TCP 连接被 RST（ECONNREFUSED），而 UDP 心跳仍在 → 「显示在线却发不进来」。
    func ensureReceiverUp() {
        guard appActive else { return }
        if receiver.ensureListening() {
            addLog("接收服务已自动重建（此前被系统挂起导致监听失效）")
            discovery.announceAll()
        }
    }

    /// 回到前台时调用：确认监听可用 + 立刻公告一轮 + 重查 tailnet 目标
    func onForeground() {
        appActive = true
        _ = receiver.ensureListening()
        // ★ v36：回到前台时**重建 UDP 接收 socket**。换 Wi-Fi / 休眠唤醒后，老 socket
        //   可能一个包都收不到（对端却一切正常）→ 表现为"设备明明在线却看不到"。
        discovery.resetSockets()
        refreshTailscale()
    }

    /// 监听就绪（含重建）→ 立刻公告，让对端第一时间刷新本机在线状态
    private func onReceiverReady() {
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

    /// 取一个 provider 的本地文件副本。视频失败重试一次（偶发占用冲突）。
    private static func loadRepresentation(_ provider: NSItemProvider, typeID: String, isVideo: Bool) -> URL? {
        let attempts = isVideo ? 2 : 1
        for attempt in 0..<attempts {
            var out: URL?
            let sem = DispatchSemaphore(value: 0)
            provider.loadFileRepresentation(forTypeIdentifier: typeID) { url, err in
                // ⚠️ 系统给的临时文件在回调返回后即被删除 → 必须在本回调内同步复制进沙盒
                if let url { out = Engine.copyIntoSandbox(url, isVideo: isVideo, typeID: typeID) }
                if let err = err { print("[RayDrop] load \(typeID) failed: \(err.localizedDescription)") }
                sem.signal()
            }
            if sem.wait(timeout: .now() + 300) == .timedOut {
                print("[RayDrop] load \(typeID) timed out")
            }
            if let u = out { return u }
            if attempt + 1 < attempts { Thread.sleep(forTimeInterval: 0.4) }
        }
        return nil
    }

    /// 复制进沙盒临时槽位，并**保证有扩展名**（没有扩展名对端判不出 mime、也进不了相册）。
    /// 返回 nil 表示复制失败或得到 0 字节文件 —— 绝不像旧实现那样 `try?` 吞错后照样返回路径。
    private static func copyIntoSandbox(_ src: URL, isVideo: Bool, typeID: String) -> URL? {
        let fm = FileManager.default
        var name = src.lastPathComponent
        if name.isEmpty { name = "picked_" + UUID().uuidString }
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

/// `done` 在所有项读完后回调（主线程）。providers 由本方法捕获的 `results` 持有，
    /// 与 picker 是否销毁无关 —— 所以调用方可以立即关掉 sheet，加载照常进行。
    ///
    /// 并发模型：为避免「在队列上阻塞等信号量、而工作项又在同一队列里排队」造成线程池耗尽，
    /// 这里改成**手动槽位调度** —— 主循环只负责派发，不阻塞；每个工作项结束后自己派发下一个。
    func preparePhotos(_ results: [PHPickerResult], done: @escaping () -> Void) {
        guard !results.isEmpty else { done(); return }
        let total = results.count
        DispatchQueue.main.async { self.status = "正在读取 \(total) 项…" }

        // 先在主线程把每项的 (provider, 类型) 解析出来（轻量，不涉 IO）
        var jobs: [(idx: Int, provider: NSItemProvider, typeID: String, isVideo: Bool)] = []
        var fails: [String] = []
        for (idx, r) in results.enumerated() {
            guard let pick = Engine.resolvePickType(r.itemProvider) else {
                fails.append("第 \(idx + 1) 项（无法识别类型）")
                continue
            }
            jobs.append((idx, r.itemProvider, pick.id, pick.isVideo))
        }

        let lock = NSLock()
        var slots: [URL?] = Array(repeating: nil, count: total)
        var failed = fails
        var next = 0
        let maxConcurrent = 2
        let group = DispatchGroup()

        /// 派发下一个任务（在锁内取任务号，避免竞态）
        func dispatchNext() {
            lock.lock()
            guard next < jobs.count else { lock.unlock(); return }
            let job = jobs[next]; next += 1
            lock.unlock()

            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                let url = Engine.loadRepresentation(job.provider, typeID: job.typeID, isVideo: job.isVideo)
                lock.lock()
                if let u = url { slots[job.idx] = u }
                else { failed.append("第 \(job.idx + 1) 项\(job.isVideo ? "视频" : "照片")") }
                lock.unlock()
                group.leave()
                dispatchNext()          // 本项结束，接力派发下一项（保持并发上限）
            }
        }
        for _ in 0..<min(maxConcurrent, jobs.count) { dispatchNext() }

        group.notify(queue: .main) {
            let ok = slots.compactMap { $0 }
            let failedList = failed.sorted()
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
                    // ★ 关键：失败绝不静默。旧实现吞掉 error，用户以为全选中，实际只发出去一部分。
                    self.status = "已选 \(ok.count) 项，另有 \(failedList.count) 项读取失败"
                    self.addLog("有 \(failedList.count) 项未能加入待发：\(failedList.joined(separator: "、"))")
                }
            }
            done()
        }
    }

    /// 点设备 → 发送暂存内容（先选类型内容，再点设备发出）
    func sendPending(to dev: DeviceInfo, host: String) {
        if pendingItems.isEmpty {
            DispatchQueue.main.async { self.status = "请先在顶部选择要发送的内容（照片/文件/文本）" }
            return
        }
        let items = pendingItems
        sender.send(host: host, port: dev.port, peerName: dev.name, items: items) { ok in
            DispatchQueue.main.async {
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
                let ext = (real as NSString).pathExtension.lowercased()
                let isImg = ["jpg","jpeg","png","heic","webp","gif","bmp"].contains(ext)
                let isVid = ["mp4","mov","mkv","avi"].contains(ext)
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
                got.append(SharedItem(url: tmp, text: nil, name: real, size: sz, kind: "file",
                                      isImage: isImg, isVideo: isVid))
            }
        }
        DispatchQueue.main.async {
            guard !got.isEmpty else { return }
            self.sharedItems = got
            self.showSharePrompt = true
            self.addLog("收到分享内容 \(got.count) 项，请选择设备发送")
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
        var items: [SendItem] = []
        for it in sharedItems {
            if it.kind == "text", let t = it.text { items.append(.text(t)) }
            else if let u = it.url { items.append(.file(u)) }
        }
        guard !items.isEmpty else { dismissShareInbox(); return }
        // 先清空：无论发送成功与否，这次分享都已经结束
        dismissShareInbox()
        sender.send(host: host, port: dev.port, peerName: dev.name, items: items) { ok in
            DispatchQueue.main.async {
                self.addLog(ok ? "分享内容已全部发送" : "分享内容发送失败")
                if ok { self.clearPendingTempFiles() }
            }
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
            DocPicker { urls in engine.setPending(urls.map { .file($0) }, summary: "已选 \(urls.count) 个文件"); showDoc = false }
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
            KindButton(icon: "photo", title: "照片", tint: .blue) { showPhoto = true }
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
        Button { engine.sendPending(to: d, host: host) } label: {
            HStack(spacing: 10) {
                Image(systemName: d.isComputer ? "desktopcomputer" : "iphone")
                    .font(.title3).frame(width: 28)
                VStack(alignment: .leading, spacing: 1) {
                    Text("\(d.name)").font(.subheadline.weight(.medium))
                    Text(host).font(.caption2).foregroundColor(.secondary)
                }
                Spacer()
                Image(systemName: "arrow.up.circle.fill").foregroundColor(.accentColor)
            }
            .padding(.horizontal).padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
                        Text(e.text).font(.caption2).foregroundColor(e.inColor)
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
        var cfg = PHPickerConfiguration(); cfg.selectionLimit = 0; cfg.filter = .any(of: [.images, .videos])
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
