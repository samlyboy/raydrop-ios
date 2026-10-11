import Foundation
import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

final class Engine: ObservableObject {
    struct DeviceInfo: Identifiable { let id = UUID(); let code: String; let name: String; let host: String; let port: UInt16 }

    @Published var status = "启动中…"
    @Published var log = ""
    @Published var myCode = RDStore.shared.myCode
    @Published var myName = RDStore.shared.myName
    @Published var trusted = RDStore.shared.trustedCodes
    @Published var devices: [DeviceInfo] = []
    @Published var selectedTarget: DeviceInfo?

    private let receiver = RDReceiver()
    private let discovery = RDDiscovery()
    private let sender = RDSender()

    func start() {
        receiver.onStatus = { [weak self] s in DispatchQueue.main.async { self?.status = s } }
        receiver.onSaved = { [weak self] from, name in
            DispatchQueue.main.async { self?.log = "\(from) → 已存相册 \(name)\n" + (self?.log ?? "") }
        }
        discovery.onDevice = { [weak self] o in self?.ingest(o) }
        sender.onStatus = { [weak self] s in DispatchQueue.main.async { self?.status = s } }
        receiver.start(); discovery.start()
        register()
        Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in self?.register() }
    }

    private func register() {
        let ip = RDIP.tailscaleIP()
        if !ip.isEmpty { RDDirectory.register(code: myCode, name: myName, ip: ip, port: RD.tcpPort) }
    }

    private func ingest(_ o: [String: Any]) {
        guard let code = o["code"] as? String else { return }
        let name = o["name"] as? String ?? "设备"
        let ips = o["ips"] as? [String] ?? []
        let port = UInt16((o["port"] as? NSNumber)?.intValue ?? Int(RD.tcpPort))
        let host = ips.first(where: { $0.hasPrefix("100.") }) ?? ips.first ?? ""
        if let i = devices.firstIndex(where: { $0.code == code }) { devices[i] = DeviceInfo(code: code, name: name, host: host, port: port) }
        else { devices.append(DeviceInfo(code: code, name: name, host: host, port: port)) }
    }

    func setCode(_ c: String) { let c = c.trimmingCharacters(in: .whitespaces); if c.count == 3 && c.allSatisfy(\.isNumber) { RDStore.shared.myCode = c; myCode = c; register() } }
    func setName(_ n: String) { RDStore.shared.myName = n; myName = n }
    func addTrust() { RDStore.shared.trust(myCodePending); myCodePending = ""; trusted = RDStore.shared.trustedCodes }
    func removeTrust(_ c: String) { RDStore.shared.untrust(c); trusted = RDStore.shared.trustedCodes }
    @Published var myCodePending = ""

    func lookup(_ code: String) {
        let c = code.trimmingCharacters(in: .whitespaces)
        guard c.count == 3 else { return }
        RDDirectory.lookup(code: c) { peer in
            DispatchQueue.main.async {
                if let peer = peer {
                    if let i = self.devices.firstIndex(where: { $0.code == c }) { self.devices[i] = DeviceInfo(code: c, name: peer.name, host: peer.ip, port: peer.port) }
                    else { self.devices.append(DeviceInfo(code: c, name: peer.name, host: peer.ip, port: peer.port)) }
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
                Section("状态") { Text(engine.status).font(.footnote); if !engine.log.isEmpty { Text(engine.log).font(.caption) } }
            }
            .navigationTitle("RayDrop 锐传")
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
