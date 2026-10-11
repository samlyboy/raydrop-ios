import Foundation
import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

final class Engine: ObservableObject {
    /// 设备记录：id 用稳定标识（did）而不是 3 位码 —— 对方改了码也还是同一台设备，不会多出一条
    struct DeviceInfo: Identifiable {
        var id: String
        var code: String
        var name: String
        var host: String
        var port: UInt16
        var lastSeen: Date
        var cfOnly: Bool
    }

    @Published var status = "启动中…"
    @Published var log = ""
    @Published var myCode = RDStore.shared.myCode
    @Published var myName = RDStore.shared.myName
    @Published var trusted = RDStore.shared.trustedCodes
    @Published var devices: [DeviceInfo] = []
    @Published var selectedTarget: DeviceInfo?
    @Published var myCodePending = ""
    /// 传输进度：如「(3/6) ↑上传 1.2 MB/s」；接收方向显示 ↓下载
    @Published var progress = ""
    @Published var txActive = false
    @Published var paused = false

    private let receiver = RDReceiver()
    private let discovery = RDDiscovery()
    private let sender = RDSender()
    private var txUp = false, txTotal = 0

    static func fmtSpeed(_ bps: Double) -> String {
        if bps >= 1048576 { return String(format: "%.1f MB/s", bps / 1048576) }
        return String(format: "%.0f KB/s", bps / 1024)
    }
    private func beginTx(up: Bool, total: Int) {
        DispatchQueue.main.async {
            self.txUp = up; self.txTotal = total; self.txActive = true; self.paused = false
            self.progress = "(0/\(max(1, total))) " + (up ? "↑上传" : "↓下载") + " 0 KB/s"
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

    func start() {
        receiver.onStatus = { [weak self] s in DispatchQueue.main.async { self?.status = s } }
        receiver.onSaved = { [weak self] from, name in
            DispatchQueue.main.async { self?.log = "\(from) → 已存相册 \(name)\n" + (self?.log ?? "") }
        }
        receiver.onStart = { [weak self] total in self?.beginTx(up: false, total: total) }
        receiver.onProgress = { [weak self] cur, total, done, bps in self?.updateTx(cur: cur, total: total, bps: bps) }
        receiver.onEnd = { [weak self] ok, msg in self?.endTx(ok: ok, msg: msg) }
        discovery.onDevice = { [weak self] o in self?.ingest(o) }
        sender.onStatus = { [weak self] s in DispatchQueue.main.async { self?.status = s } }
        sender.onStart = { [weak self] total in self?.beginTx(up: true, total: total) }
        sender.onProgress = { [weak self] cur, total, done, bps in self?.updateTx(cur: cur, total: total, bps: bps) }
        sender.onEnd = { [weak self] ok, msg in self?.endTx(ok: ok, msg: msg) }
        receiver.start(); discovery.start()
        refreshPeers()
        Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in self?.refreshPeers() }
        Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.cull() }
    }

    private func register() {
        let ip = RDIP.tailscaleIP()
        if !ip.isEmpty { RDDirectory.register(code: myCode, name: myName, ip: ip, port: RD.tcpPort) }
    }

    /// 每 60s：把自己注册到 CF 目录，并用「信任码」反查对方 IP；
    /// 拿到 IP 后立刻单播告知自己 —— 即使 UDP 广播被系统拦掉（iOS 常见），双方也能互相发现。
    private func refreshPeers() {
        register()
        for code in trusted {
            RDDirectory.lookup(code: code) { [weak self] peer in
                guard let self = self, let peer = peer, !peer.ip.isEmpty else { return }
                DispatchQueue.main.async {
                    self.upsert(id: "cf:" + code, code: code, name: peer.name, host: peer.ip, port: peer.port, cfOnly: true)
                    self.discovery.announceTo([peer.ip])
                    self.syncTargets()
                }
            }
        }
    }

    private func ingest(_ o: [String: Any]) {
        guard let code = o["code"] as? String else { return }
        let name = o["name"] as? String ?? "设备"
        let ips = o["ips"] as? [String] ?? []
        let port = UInt16((o["port"] as? NSNumber)?.intValue ?? Int(RD.tcpPort))
        let host = ips.first(where: { $0.hasPrefix("100.") }) ?? ips.first ?? (o["srcIP"] as? String ?? "")
        let did = (o["did"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? ("code:" + code)
        upsert(id: did, code: code, name: name, host: host, port: port, cfOnly: false)
        discovery.announceTo(host.isEmpty ? [] : [host])   // 收到就回告一次，对方立刻能看到我
        syncTargets()
    }

    /// 合并规则：did → 3位码 → 同名同 IP（对方改码后仍视为同一台设备）
    private func upsert(id: String, code: String, name: String, host: String, port: UInt16, cfOnly: Bool) {
        var idx = devices.firstIndex { $0.id == id }
        if idx == nil { idx = devices.firstIndex { $0.code == code } }
        if idx == nil, !host.isEmpty { idx = devices.firstIndex { $0.name == name && $0.host == host } }
        if let i = idx {
            if !id.hasPrefix("cf:") { devices[i].id = id }     // 真 did 优先于 cf:code
            devices[i].code = code
            devices[i].name = name
            if !host.isEmpty { devices[i].host = host }
            devices[i].port = port
            devices[i].lastSeen = Date()
            if !cfOnly { devices[i].cfOnly = false }
        } else {
            devices.append(DeviceInfo(id: id, code: code, name: name, host: host, port: port, lastSeen: Date(), cfOnly: cfOnly))
        }
    }

    private func syncTargets() { discovery.setExtraTargets(devices.map { $0.host }.filter { !$0.isEmpty }) }

    /// 清理：局域网设备 45s 没消息就下线；CF 目录设备 10 分钟后过期。
    /// 没有这一步，对方改码/重启后旧条目会永远留在列表里（就是之前出现两条的原因之一）。
    private func cull() {
        let now = Date()
        var kept = devices.filter { now.timeIntervalSince($0.lastSeen) < ($0.cfOnly ? 600 : 45) }
        let direct = kept.filter { !$0.cfOnly }
        if !direct.isEmpty { kept = kept.filter { d in !d.cfOnly || !direct.contains { $0.code == d.code } } }
        if kept.count != devices.count { devices = kept; syncTargets() }
    }

    func setCode(_ c: String) {
        let c = c.trimmingCharacters(in: .whitespaces)
        if c.count == 3 && c.allSatisfy(\.isNumber) {
            RDStore.shared.myCode = c; myCode = c
            register()
            discovery.announceTo(devices.map { $0.host }.filter { !$0.isEmpty })
        }
    }
    func setName(_ n: String) { RDStore.shared.myName = n; myName = n }
    func addTrust() { RDStore.shared.trust(myCodePending); myCodePending = ""; trusted = RDStore.shared.trustedCodes; refreshPeers() }
    func removeTrust(_ c: String) { RDStore.shared.untrust(c); trusted = RDStore.shared.trustedCodes }

    func lookup(_ code: String) {
        let c = code.trimmingCharacters(in: .whitespaces)
        guard c.count == 3 else { return }
        RDDirectory.lookup(code: c) { [weak self] peer in
            guard let self = self else { return }
            DispatchQueue.main.async {
                if let peer = peer, !peer.ip.isEmpty {
                    self.upsert(id: "cf:" + c, code: c, name: peer.name, host: peer.ip, port: peer.port, cfOnly: true)
                    self.discovery.announceTo([peer.ip])
                    self.syncTargets()
                    self.status = "已找到 \(peer.name)"
                } else { self.status = "未找到该码的在线设备" }
            }
        }
    }

    /// 发送：按用户在相册里选择的顺序逐个导出并保序传输。
    /// 用下标占位保证顺序；每个结果恰好 enter/leave 一次（图片或视频只取其一）。
    func send(to dev: DeviceInfo, results: [PHPickerResult], completion: @escaping () -> Void) {
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
            self.sender.send(host: dev.host, port: dev.port, files: final) { _ in completion() }
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
    @State var lookupCode = ""

    var body: some View {
        NavigationView {
            Form {
                Section("我的码 / 名称") {
                    TextField("3位数字码", text: Binding(get: { engine.myCode }, set: { engine.setCode($0) })).keyboardType(.numberPad)
                    TextField("设备名称", text: Binding(get: { engine.myName }, set: { engine.setName($0) }))
                }
                Section("信任码（这些码发来的文件自动接收并存相册）") {
                    ForEach(engine.trusted, id: \.self) { c in
                        HStack { Text(c + " (自动接收)"); Spacer(); Button("移除") { engine.removeTrust(c) }.font(.caption) }
                    }
                    HStack { TextField("3位数字码", text: $engine.myCodePending).keyboardType(.numberPad); Button("添加") { engine.addTrust() } }
                }
                Section("发现的设备") {
                    if engine.devices.isEmpty { Text("未发现").foregroundColor(.gray) }
                    ForEach(engine.devices) { d in
                        HStack {
                            VStack(alignment: .leading) { Text(d.name + " [" + d.code + "]").font(.headline); Text("\(d.host):\(d.port)").font(.caption).foregroundColor(.gray) }
                            Spacer()
                            Button("发送到此") { engine.selectedTarget = d; showPicker = true }.font(.caption)
                        }
                    }
                }
                Section("通过 3 位码查找 Tailscale 设备") {
                    HStack { TextField("3位数字码", text: $lookupCode).keyboardType(.numberPad); Button("查找") { engine.lookup(lookupCode) } }
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
                    if !engine.log.isEmpty { Text(engine.log).font(.caption) }
                }
            }
            .navigationTitle("RayDrop 锐传 v6")
        }
        .sheet(isPresented: $showPicker) {
            PhotoPicker { results in
                if let t = engine.selectedTarget { engine.send(to: t, results: results) {} }
            }
        }
        .onAppear { engine.start() }
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
