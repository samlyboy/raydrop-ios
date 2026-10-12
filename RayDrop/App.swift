import Foundation
import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import UIKit

final class Engine: ObservableObject {
    struct DeviceInfo: Identifiable {
        var id: String
        var code: String
        var name: String
        var platform: String     // iOS / Android / PC，驱动设备图标
        var lanHost: String
        var tsHost: String
        var port: UInt16
        var lastSeen: Date
        /// 手机 vs 电脑图标
        var isComputer: Bool { platform.lowercased().contains("pc") || platform.lowercased().contains("mac") }
    }
    struct LogEntry: Identifiable { let id = UUID(); let text: String; let inColor: Color; let isHeader: Bool }

    @Published var status = "启动中…"
    @Published var logEntries: [LogEntry] = []
    @Published var myCode = RDStore.shared.myCode
    @Published var myName = RDStore.shared.myName
    @Published var devices: [DeviceInfo] = []
    @Published var progress = ""
    @Published var txActive = false
    @Published var paused = false
    /// 已选待发送内容的摘要，如「已选 3 项」
    @Published var pendingSummary = ""
    @Published var receivedFrom = ""
    @Published var receivedText = ""
    @Published var showRecvText = false
    @Published var saveFileURL: URL? = nil
    @Published var saveFileName = ""
    @Published var showSaveFile = false

    private let receiver = RDReceiver()
    private let discovery = RDDiscovery()
    private let sender = RDSender()
    private var txUp = false, txTotal = 0, txPeer = "对方"
    private var pendingItems: [SendItem] = []
    private var didStart = false

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
    private func beginTx(up: Bool, peer: String, total: Int) {
        DispatchQueue.main.async {
            self.txUp = up; self.txTotal = total; self.txActive = true; self.paused = false
            let p = peer.isEmpty ? "对方" : peer
            self.txPeer = p
            self.progress = "(0/\(max(1, total))) " + (up ? "↑上传" : "↓下载") + " 0 KB/s"
            self.addHeader(up ? "发送 → \(p)   共 \(total) 项" : "接收 ← \(p)   共 \(total) 项")
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
        if didStart { return }; didStart = true
        receiver.onStatus = { [weak self] s in DispatchQueue.main.async { self?.status = s } }
        receiver.onSaved = { [weak self] from, name in self?.addEntry("\(from) → 本机  \(name)", Engine.cIn) }
        receiver.onText = { [weak self] from, text in
            DispatchQueue.main.async {
                self?.receivedFrom = from.isEmpty ? "对方" : from
                self?.receivedText = text
                self?.showRecvText = true
                self?.addEntry("\(from) → 本机  [文本] \(text.count) 字", Engine.cIn)
            }
        }
        receiver.onFileToSave = { [weak self] from, url, name, mime in
            DispatchQueue.main.async {
                self?.saveFileURL = url; self?.saveFileName = name; self?.showSaveFile = true
                self?.addEntry("\(from) → 本机  \(name)（待存储到文件）", Engine.cIn)
            }
        }
        receiver.onStart = { [weak self] peer, total in self?.beginTx(up: false, peer: peer, total: total) }
        receiver.onProgress = { [weak self] cur, total, done, bps in self?.updateTx(cur: cur, total: total, bps: bps) }
        receiver.onEnd = { [weak self] ok, msg in self?.endTx(ok: ok, msg: msg) }
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
        sender.onProgress = { [weak self] cur, total, done, bps in self?.updateTx(cur: cur, total: total, bps: bps) }
        sender.onEnd = { [weak self] ok, msg in self?.endTx(ok: ok, msg: msg) }
        receiver.start(); discovery.start()
        Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.cull() }
    }

    private func ingest(_ o: [String: Any]) {
        guard let code = o["code"] as? String else { return }
        let name = o["name"] as? String ?? "设备"
        let platform = o["platform"] as? String ?? ""
        let ips = o["ips"] as? [String] ?? []
        let port = UInt16((o["port"] as? NSNumber)?.intValue ?? Int(RD.tcpPort))
        var lan = "", ts = ""
        for ip in ips { if ip.hasPrefix("100.") { if ts.isEmpty { ts = ip } } else if lan.isEmpty { lan = ip } }
        let src = o["srcIP"] as? String ?? ""
        if !src.isEmpty { if src.hasPrefix("100.") { ts = src } else { lan = src } }
        let did = (o["did"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? ("code:" + code)
        upsert(id: did, code: code, name: name, platform: platform, lanHost: lan, tsHost: ts, port: port)
        discovery.announceTo(src.isEmpty ? [] : [src])
        syncTargets()
    }
    private func upsert(id: String, code: String, name: String, platform: String, lanHost: String, tsHost: String, port: UInt16) {
        var idx = devices.firstIndex { $0.id == id }
        if idx == nil { idx = devices.firstIndex { $0.code == code } }
        if idx == nil, !lanHost.isEmpty { idx = devices.firstIndex { $0.name == name && $0.lanHost == lanHost } }
        if let i = idx {
            devices[i].id = id.hasPrefix("cf:") ? devices[i].id : id
            devices[i].code = code; devices[i].name = name; devices[i].platform = platform
            devices[i].lanHost = lanHost; devices[i].tsHost = tsHost; devices[i].port = port; devices[i].lastSeen = Date()
        } else {
            devices.append(DeviceInfo(id: id, code: code, name: name, platform: platform, lanHost: lanHost, tsHost: tsHost, port: port, lastSeen: Date()))
        }
    }
    private func syncTargets() {
        var all: [String] = []
        for d in devices { if !d.lanHost.isEmpty { all.append(d.lanHost) }; if !d.tsHost.isEmpty { all.append(d.tsHost) } }
        discovery.setExtraTargets(all)
    }
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

    // ---- 顶部选类型/内容 → 暂存 ----
    func setPending(_ items: [SendItem], summary: String) {
        pendingItems = items
        DispatchQueue.main.async { self.pendingSummary = items.isEmpty ? "" : summary }
    }
    func preparePhotos(_ results: [PHPickerResult]) {
        guard !results.isEmpty else { return }
        let group = DispatchGroup(); let lock = NSLock()
        var urls: [URL?] = Array(repeating: nil, count: results.count)
        for (idx, r) in results.enumerated() {
            let provider = r.itemProvider
            let isVideo = provider.hasItemConformingToTypeIdentifier(UTType.movie.identifier)
            let type = isVideo ? UTType.movie.identifier : UTType.image.identifier
            group.enter()
            provider.loadFileRepresentation(forTypeIdentifier: type) { url, _ in
                defer { group.leave() }
                if let url { let tmp = self.copyTemp(url); lock.lock(); urls[idx] = tmp; lock.unlock() }
            }
        }
        group.notify(queue: .global()) {
            let final = urls.compactMap { $0 }
            self.setPending(final.map { .file($0) }, summary: "已选 \(final.count) 张照片/视频")
        }
    }

    /// 点设备 → 发送暂存内容（先选类型内容，再点设备发出）
    func sendPending(to dev: DeviceInfo, host: String) {
        if pendingItems.isEmpty {
            DispatchQueue.main.async { self.status = "请先在顶部选择要发送的内容（照片/文件/文本）" }
            return
        }
        let items = pendingItems
        sender.send(host: host, port: dev.port, peerName: dev.name, items: items) { _ in
            DispatchQueue.main.async { self.pendingItems = []; self.pendingSummary = "" }
        }
    }
    private func copyTemp(_ src: URL) -> URL {
        let dst = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "-" + src.lastPathComponent)
        try? FileManager.default.copyItem(at: src, to: dst)
        return dst
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
                    Button(action: openFiles) { Label("打开文件浏览器", systemImage: "folder") }
                }
            }
        }
        .sheet(isPresented: $showPhoto) {
            PhotoPicker { results in engine.preparePhotos(results); showPhoto = false }
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
        .alert("设备名称", isPresented: $editName) {
            TextField("设备名称", text: $editNameDraft)
            Button("取消", role: .cancel) {}
            Button("确认") { engine.setName(editNameDraft) }
        }
        .sheet(isPresented: $engine.showSaveFile) {
            if let u = engine.saveFileURL { DocExportPicker(url: u) }
        }
        .onAppear { engine.start() }
    }

    /// 只保留设备名称：前缀加粗大字体，点一下直接编辑（不再显示 3 位码与铅笔图标）
    private var header: some View {
        Button {
            editNameDraft = engine.myName
            editName = true
        } label: {
            HStack(spacing: 4) {
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
                if engine.devices.isEmpty {
                    Text("未发现设备，等待广播/探测…").foregroundColor(.gray).font(.footnote).padding(.horizontal)
                } else {
                    let lan = engine.devices.filter { !$0.lanHost.isEmpty }
                    let ts = engine.devices.filter { !$0.tsHost.isEmpty }
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
                    Text("\(d.name) [\(d.code)]").font(.subheadline.weight(.medium))
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
    var body: some Scene { WindowGroup { ContentView() } }
}
