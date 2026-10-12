import Foundation
import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

final class Engine: ObservableObject {
    /// 设备记录：id 用稳定标识（did）而不是 3 位码 —— 对方改了码也还是同一台设备，不会多出一条。
    /// 一台设备可能同时有局域网 IP 和 Tailscale IP，两个都存，列表里分组展示由用户选走哪条。
    struct DeviceInfo: Identifiable {
        var id: String
        var code: String
        var name: String
        var lanHost: String
        var tsHost: String
        var port: UInt16
        var lastSeen: Date
    }

    /// 任务列表条目：header=true 是带时间戳的分隔行
    struct LogEntry: Identifiable { let id = UUID(); let text: String; let inColor: Color; let isHeader: Bool }

    @Published var status = "启动中…"
    @Published var logEntries: [LogEntry] = []
    @Published var myCode = RDStore.shared.myCode
    @Published var myName = RDStore.shared.myName
    @Published var devices: [DeviceInfo] = []
    @Published var selectedTarget: DeviceInfo?
    /// 传输进度：如「(3/6) ↑上传 1.2 MB/s」；接收方向显示 ↓下载
    @Published var progress = ""
    @Published var txActive = false
    @Published var paused = false

    private let receiver = RDReceiver()
    private let discovery = RDDiscovery()
    private let sender = RDSender()
    private var txUp = false, txTotal = 0, txPeer = "对方"

    static let cIn = Color(red: 0.90, green: 0.22, blue: 0.21)     // 接收：红
    static let cOut = Color(red: 0.18, green: 0.60, blue: 0.24)    // 发送：绿
    static let cSys = Color.secondary

    private static let fmtTime: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "MM-dd HH:mm:ss"; return f
    }()
    /// 新条目插在最前面（新的在上面）
    private func addEntry(_ text: String, _ color: Color, header: Bool = false) {
        DispatchQueue.main.async {
            // 批次进行中：新条目插在时间戳分隔行下方，让分隔行始终钉在每批任务的顶部
            let at = (self.pinHeader && !self.logEntries.isEmpty && self.logEntries[0].isHeader && !header) ? 1 : 0
            self.logEntries.insert(LogEntry(text: text, inColor: color, isHeader: header), at: at)
            if self.logEntries.count > 300 { self.logEntries.removeLast(self.logEntries.count - 300) }
        }
    }
    private func addLog(_ text: String) { addEntry(text, Engine.cSys) }
    /// 每轮传输插入一条带时间戳的分隔行，钉在该批任务顶部（新条目都插在它下面）
    private func addHeader(_ title: String) {
        pinHeader = true
        addEntry(Engine.fmtTime.string(from: Date()) + "  " + title, Engine.cSys, header: true)
    }
    /// 批次进行中标记：结束（完成/失败/终止）后释放，后续新条目回到最顶上
    private var pinHeader = false

    static func fmtSpeed(_ bps: Double) -> String {
        if bps >= 1048576 { return String(format: "%.1f MB/s", bps / 1048576) }
        return String(format: "%.0f KB/s", bps / 1024)
    }
    private func beginTx(up: Bool, peer: String, total: Int) {
        DispatchQueue.main.async {
            self.txUp = up; self.txTotal = total; self.txActive = true; self.paused = false
            let p = peer.isEmpty ? "对方" : peer
            self.txPeer = p
            self.progress = "(0/\(max(1, total))) " + (up ? "↑上传" : "↓下载") + " 0 KB/s"
            self.addHeader(up ? "发送 → \(p)   共 \(total) 个" : "接收 ← \(p)   共 \(total) 个")
        }
    }
    private func updateTx(cur: Int, total: Int, bps: Double) {
        DispatchQueue.main.async {
            let t = total > 0 ? total : self.txTotal
            guard t > 0 else { return }
            self.progress = "(\(min(max(1, cur), t))/\(t)) " + (self.txUp ? "↑上传" : "↓下载") + " " + Engine.fmtSpeed(bps)
        }
    }
    private func endTx(ok: Bool, msg: String) {
        DispatchQueue.main.async {
            self.txActive = false; self.paused = false
            self.pinHeader = false   // 批次结束，分隔行不再钉顶
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
        pinHeader = false   // 批次被终止，分隔行不再钉顶
    }

    func start() {
        receiver.onStatus = { [weak self] s in DispatchQueue.main.async { self?.status = s } }
        receiver.onSaved = { [weak self] from, name in
            // 接收：红色「一加 → 本机  003_001_xxx.jpg」
            self?.addEntry("\(from) → 本机  \(name)", Engine.cIn)
        }
        receiver.onStart = { [weak self] peer, total in self?.beginTx(up: false, peer: peer, total: total) }
        receiver.onProgress = { [weak self] cur, total, done, bps in self?.updateTx(cur: cur, total: total, bps: bps) }
        receiver.onEnd = { [weak self] ok, msg in self?.endTx(ok: ok, msg: msg) }
        discovery.onDevice = { [weak self] o in self?.ingest(o) }
        sender.onStatus = { [weak self] s in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.status = s
                // 发送成功一个：绿色「本机 → 一加  003_001_xxx」
                if s.hasPrefix("已发送 ") {
                    let name = String(s.dropFirst("已发送 ".count))
                    self.addEntry("本机 → \(self.txPeer)  \(name)", Engine.cOut)
                } else {
                    self.addLog(s)
                }
            }
        }
        sender.onStart = { [weak self] peer, total in self?.beginTx(up: true, peer: peer, total: total) }
        sender.onProgress = { [weak self] cur, total, done, bps in self?.updateTx(cur: cur, total: total, bps: bps) }
        sender.onEnd = { [weak self] ok, msg in self?.endTx(ok: ok, msg: msg) }
        receiver.start(); discovery.start()
        Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.cull() }
    }

    private func ingest(_ o: [String: Any]) {
        guard let code = o["code"] as? String else { return }
        let name = o["name"] as? String ?? "设备"
        let ips = o["ips"] as? [String] ?? []
        let port = UInt16((o["port"] as? NSNumber)?.intValue ?? Int(RD.tcpPort))
        // 地址实时分类：ips 是对方当下网卡快照（每次告知都重新枚举）；srcIP 是报文实际来源，最权威
        var lan = "", ts = ""
        for ip in ips { if ip.hasPrefix("100.") { if ts.isEmpty { ts = ip } } else if lan.isEmpty { lan = ip } }
        let src = o["srcIP"] as? String ?? ""
        if !src.isEmpty { if src.hasPrefix("100.") { ts = src } else { lan = src } }
        let did = (o["did"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? ("code:" + code)
        upsert(id: did, code: code, name: name, lanHost: lan, tsHost: ts, port: port)
        discovery.announceTo(src.isEmpty ? [] : [src])   // 回告报文来源，对方立刻能看到我
        syncTargets()
    }

    /// 合并规则：did → 同名同 IP（对方改码后仍视为同一台设备）。
    /// 地址实时覆盖：本次告知快照里没有的地址一律清掉，杜绝陈旧 IP 缓存。
    private func upsert(id: String, code: String, name: String, lanHost: String, tsHost: String, port: UInt16) {
        var idx = devices.firstIndex { $0.id == id }
        if idx == nil { idx = devices.firstIndex { $0.code == code } }
        if idx == nil, !lanHost.isEmpty { idx = devices.firstIndex { $0.name == name && $0.lanHost == lanHost } }
        if idx == nil, !tsHost.isEmpty { idx = devices.firstIndex { $0.name == name && $0.tsHost == tsHost } }
        if let i = idx {
            devices[i].id = id.hasPrefix("cf:") ? devices[i].id : id    // 真 did 优先
            devices[i].code = code
            devices[i].name = name
            devices[i].lanHost = lanHost
            devices[i].tsHost = tsHost
            devices[i].port = port
            devices[i].lastSeen = Date()
        } else {
            devices.append(DeviceInfo(id: id, code: code, name: name, lanHost: lanHost, tsHost: tsHost, port: port, lastSeen: Date()))
        }
    }

    private func syncTargets() {
        var all: [String] = []
        for d in devices { if !d.lanHost.isEmpty { all.append(d.lanHost) }; if !d.tsHost.isEmpty { all.append(d.tsHost) } }
        discovery.setExtraTargets(all)
    }

    /// 清理：45s 没消息就下线（对方改码/重启后的旧条目靠这个自动消失）。
    private func cull() {
        let now = Date()
        let kept = devices.filter { now.timeIntervalSince($0.lastSeen) < 45 }
        if kept.count != devices.count { devices = kept; syncTargets() }
    }

    func setCode(_ c: String) {
        let c = c.trimmingCharacters(in: .whitespaces)
        if c.count == 3 && c.allSatisfy(\.isNumber) {
            RDStore.shared.myCode = c; myCode = c
            discovery.announceTo(devices.flatMap { [$0.lanHost, $0.tsHost] }.filter { !$0.isEmpty })
        }
    }
    func setName(_ n: String) { RDStore.shared.myName = n; myName = n }

    /// 发送：按用户在相册里选择的顺序逐个导出并保序传输。host 由用户在设备列表里选定（局域网或 Tailscale）。
    /// 用下标占位保证顺序；每个结果恰好 enter/leave 一次（图片或视频只取其一）。
    func send(to dev: DeviceInfo, host: String, results: [PHPickerResult], completion: @escaping () -> Void) {
        let group = DispatchGroup()
        let lock = NSLock()
        var urls: [URL?] = Array(repeating: nil, count: results.count)
        for (idx, r) in results.enumerated() {
            let provider = r.itemProvider
            let isVideo = provider.hasItemConformingToTypeIdentifier(UTType.movie.identifier)
            let type = isVideo ? UTType.movie.identifier : UTType.image.identifier
            group.enter()
            provider.loadFileRepresentation(forTypeIdentifier: type) { url, _ in
                defer { group.leave() }
                if let url {
                    let tmp = self.copyTemp(url)
                    lock.lock(); urls[idx] = tmp; lock.unlock()
                }
            }
        }
        group.notify(queue: .global()) {
            let final = urls.compactMap { $0 }
            guard !final.isEmpty else { return }
            self.sender.send(host: host, port: dev.port, peerName: dev.name, files: final) { _ in completion() }
        }
    }
    private func copyTemp(_ src: URL) -> URL {
        let dst = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "-" + src.lastPathComponent)
        try? FileManager.default.copyItem(at: src, to: dst)
        return dst
    }
}

struct ContentView: View {
    @StateObject var engine = Engine()
    @State var showPicker = false
    @State var pendingResults: [PHPickerResult] = []
    @State var selectedHost = ""

    var body: some View {
        NavigationView {
            Form {
                Section("我的码 / 名称") {
                    TextField("3位数字码", text: Binding(get: { engine.myCode }, set: { engine.setCode($0) })).keyboardType(.numberPad)
                    TextField("设备名称", text: Binding(get: { engine.myName }, set: { engine.setName($0) }))
                }
                // 分两组：同一台机器两条通道就出现两次（局域网一行、Tailscale 一行），由用户选走哪条
                Section("【局域网】设备") {
                    let rows = engine.devices.filter { !$0.lanHost.isEmpty }
                    if rows.isEmpty { Text("（无）").foregroundColor(.gray) }
                    ForEach(rows) { d in devRow(d, host: d.lanHost) }
                }
                Section("【Tailscale】设备") {
                    let rows = engine.devices.filter { !$0.tsHost.isEmpty }
                    if rows.isEmpty { Text("（无）").foregroundColor(.gray) }
                    ForEach(rows) { d in devRow(d, host: d.tsHost) }
                }
                if engine.devices.isEmpty {
                    Section { Text("未发现设备，等待广播/探测…").foregroundColor(.gray) }
                }
                Section("状态") {
                    HStack(alignment: .firstTextBaseline) {
                        Text(engine.status).font(.footnote)
                        Spacer(minLength: 8)
                        if !engine.progress.isEmpty { Text(engine.progress).font(.footnote).foregroundColor(.secondary) }
                    }
                    if engine.txActive {
                        HStack {
                            Button(engine.paused ? "继续" : "暂停") { engine.togglePause() }.buttonStyle(.bordered)
                            Button("终止", role: .destructive) { engine.abortTx() }.buttonStyle(.bordered)
                            Spacer()
                        }
                    }
                    if !engine.logEntries.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(engine.logEntries) { e in
                                if e.isHeader {
                                    VStack(spacing: 2) {
                                        Divider()
                                        Text(e.text).font(.caption2).foregroundColor(.secondary)
                                        Divider()
                                    }
                                } else {
                                    Text(e.text).font(.caption).foregroundColor(e.inColor)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("RayDrop 锐传 v8")
        }
        .sheet(isPresented: $showPicker) {
            PhotoPicker { results in
                if let t = engine.selectedTarget { engine.send(to: t, host: selectedHost, results: results) {} }
            }
        }
        .onAppear { engine.start() }
    }

    @ViewBuilder private func devRow(_ d: Engine.DeviceInfo, host: String) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) { Text(d.name + " [" + d.code + "]").font(.headline); Text(host).font(.caption).foregroundColor(.gray) }
            Spacer()
            Button("发送到此") { engine.selectedTarget = d; selectedHost = host; showPicker = true }.font(.caption)
        }
    }
}

struct PhotoPicker: UIViewControllerRepresentable {
    let onPick: ([PHPickerResult]) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }
    func makeUIViewController(context: Context) -> PHPickerViewController {
        var cfg = PHPickerConfiguration(); cfg.selectionLimit = 0; cfg.filter = .any(of: [.images, .videos])
        let pc = PHPickerViewController(configuration: cfg); pc.delegate = context.coordinator; return pc
    }
    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}
    class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let onPick: ([PHPickerResult]) -> Void
        init(onPick: @escaping ([PHPickerResult]) -> Void) { self.onPick = onPick }
        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) { onPick(results); picker.dismiss(animated: true) }
    }
}

@main
struct RayDropApp: App {
    var body: some Scene { WindowGroup { ContentView() } }
}
