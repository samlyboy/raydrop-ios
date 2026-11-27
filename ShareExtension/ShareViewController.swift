import Foundation
import UIKit
import UniformTypeIdentifiers
import UserNotifications

/// 分享扩展：把相册/文件/文本暂存到 App Group 的 inbox 目录，然后把主 APP 拉到前台。
/// 主 APP 的 consumeSharedItems() 会读取这里，弹出「分享到 RayDrop」面板（文件已列好，点设备即发）。
///
/// ★ 为什么要「拉」而不是「等」：iOS 没给分享扩展任何官方手段切到宿主 APP。
///   扩展只能 completeRequest，之后系统把用户送回**发起分享的 App**（也就是相册），
///   这正是「分享完还得自己去桌面点图标」的根因。
///   v47 起走两条非官方路径（TrollStore 侧载，不走商店审核）：
///     ① 沿响应链找到 UIApplication，调它的 openURL:（老接口，实测最有效）
///     ② extensionContext.open(url) —— 官方接口，但分享扩展基本被忽略，留作兜底
///   两条都指望不上时：落下一条 5 秒后的本地通知。主 APP 成功起来会立刻撤掉它，
///   所以正常情况下用户永远看不到这条通知；只有跳转失败它才浮现，点一下照样能进到面板。
final class ShareViewController: UIViewController
{
    private let appGroupID = "group.com.raydrop.ios"
    /// 与主 APP 里 RDShareNotify.readyID 必须一致；主 APP 靠这个 id 撤销通知
    private let readyNotificationID = "rd_share_ready"
    private var statusLabel: UILabel!

    override func viewDidLoad()
    {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        setupUI()
        DispatchQueue.global().async { [weak self] in
            self?.handle()
        }
    }

    func setupUI()
    {
        let v = UIStackView()
        v.axis = .vertical; v.alignment = .center; v.spacing = 12
        v.translatesAutoresizingMaskIntoConstraints = false
        let icon = UIImageView(image: UIImage(systemName: "arrow.up.circle.fill"))
        icon.tintColor = .systemBlue; icon.contentMode = .scaleAspectFit
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.heightAnchor.constraint(equalToConstant: 48).isActive = true
        statusLabel = UILabel(); statusLabel.text = "正在准备…"
        statusLabel.font = .preferredFont(forTextStyle: .subheadline)
        statusLabel.textColor = .secondaryLabel
        statusLabel.numberOfLines = 0
        statusLabel.textAlignment = .center
        let cancel = UIButton(type: .system); cancel.setTitle("取消", for: .normal)
        cancel.addTarget(self, action: #selector(cancelTapped), for: .touchUpInside)
        v.addArrangedSubview(icon); v.addArrangedSubview(statusLabel); v.addArrangedSubview(cancel)
        view.addSubview(v)
        NSLayoutConstraint.activate([
            v.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            v.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            v.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 24),
            v.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -24),
        ])
    }

    @objc func cancelTapped()
    {
        extensionContext?.cancelRequest(withError: NSError(domain: "RayDropShare", code: 0))
    }

    func inboxDir() -> URL?
    {
        guard let base = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID) else { return nil }
        let inbox = base.appendingPathComponent("inbox")
        try? FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        return inbox
    }

    func handle()
    {
        guard let items = extensionContext?.inputItems as? [NSExtensionItem] else { finish(0); return }
        guard let inbox = inboxDir() else { DispatchQueue.main.async { self.finish(0) }; return }

        // 计数器：等所有 provider 的异步回调都完成再收尾
        let group = DispatchGroup()
        var count = 0
        var diag: [String] = []
        let seq = DispatchQueue(label: "share.copy")

        func note(_ s: String) { seq.sync { diag.append(s) } }

        func extOf(_ typeID: String) -> String {
            if let t = UTType(typeID) {
                if t.conforms(to: .movie) || t.conforms(to: .video) || t.conforms(to: .audiovisualContent) { return "mov" }
                if t.conforms(to: .image) {
                    if t.conforms(to: .jpeg) { return "jpg" }
                    if t.conforms(to: .png) { return "png" }
                    if t.conforms(to: .heic) { return "heic" }
                    return "jpg"
                }
                // ★ v47.17：常见文档类型按 conforms 映射，别一律 bin
                if t.conforms(to: .pdf) { return "pdf" }
                if t.conforms(to: .json) { return "json" }
                if t.conforms(to: .plainText) { return "txt" }
            }
            // UTType 认不出的具体类型（如 com.apple.itunes.ipa）：从标识符字符串兜底
            let s = typeID.lowercased()
            if s.contains("zip") || s.contains("archive") { return "zip" }
            if s.contains("ipa") { return "ipa" }
            if s.contains("pdf") { return "pdf" }
            if s.contains("apk") { return "apk" }
            return "bin"
        }

        /// 相册分享的视频/图片，临时文件名常没有扩展名；补一个，主 App 的 alignExtension 还会再按文件头纠正
        /// ★ v47.18：hint 为分享面板标题里的原文件名，优先于临时 URL 名与 UUID。
        func saveURL(_ src: URL, _ typeID: String, _ hint: String? = nil) {
            var base = src.lastPathComponent
            // 临时名没扩展名 / 是 UUID 占位 / 是系统 cache 名 → 用标题里的原文件名
            let ext = (base as NSString).pathExtension.lowercased()
            let looksTemp = base.isEmpty || ext.isEmpty || ext == "tmp" || base.hasPrefix("tmp") ||
                            base.hasPrefix("share_") || (hint != nil && !base.contains("."))
            if looksTemp, let h = hint, !h.isEmpty {
                base = h
            } else if looksTemp {
                base = "share_" + UUID().uuidString + "." + extOf(typeID)
            }
            let dst = inbox.appendingPathComponent("f_" + base)
            try? FileManager.default.removeItem(at: dst)
            // loadFileRepresentation / loadItem 给的可能仍是安全作用域 URL；不 startAccessing 会 copy 失败 → -count=0
            let scoped = src.startAccessingSecurityScopedResource()
            defer { if scoped { src.stopAccessingSecurityScopedResource() } }
            do {
                try FileManager.default.copyItem(at: src, to: dst)
                // ★ v47.16：copyItem 会保留源文件的修改时间 —— 相册视频的 modificationDate
                //   就是拍摄/导入时间（常是几个月前）。主 APP 的 inbox 残留清理按该时间判断，
                //   会把刚分享进来的视频当成「1 小时前的残留」直接删掉 → 分享后 0 项。
                //   写入完成立刻把时间戳刷新成「现在」，彻底切断这条误删链。
                try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: dst.path)
                seq.sync { count += 1 }
            }
            catch { note("复制失败 \(base)：\(error.localizedDescription)") }
        }
        /// ★ v47.18：文件名来源优先级 provider.suggestedName > 分享面板标题 hint > UUID。
        ///   旧版无条件 UUID 命名 → IPA 变成 share_<UUID>.bin。
        func saveData(_ d: Data, _ typeID: String, _ suggested: String? = nil, _ hint: String? = nil) {
            var base = (suggested ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if base.isEmpty || (base as NSString).pathExtension.isEmpty { base = (hint ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
            if base.isEmpty || (base as NSString).pathExtension.isEmpty {
                base = "share_" + UUID().uuidString + "." + extOf(typeID)
            }
            // ★ v47.19：所有名字来源都失败时，至少按文件内容嗅探出正确后缀，别一律 .bin。
            //   IPA / zip / apk 都是 PK(50 4B) 开头的 zip 容器；PDF 是 %PDF。
            if !base.hasSuffix("." + extOf(typeID)) && extOf(typeID) == "bin" {
                let b = [UInt8](d.prefix(8))
                if b.count >= 4, b[0] == 0x50, b[1] == 0x4B {
                    // zip 容器：从字节里找 Payload/ 判断是 IPA，否则 zip
                    let head = String(data: d.prefix(2048), encoding: .ascii) ?? ""
                    base = (base as NSString).deletingPathExtension + (head.contains("Payload/") ? ".ipa" : ".zip")
                } else if b.count >= 4, b[0] == 0x25, b[1] == 0x50, b[2] == 0x44, b[3] == 0x46 {
                    base = (base as NSString).deletingPathExtension + ".pdf"
                }
            }
            note("saveData 命名=\(base) suggested=\(suggested ?? "nil") hint=\(hint ?? "nil")")
            let dst = inbox.appendingPathComponent("f_" + base)
            do {
                try d.write(to: dst)
                try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: dst.path)
                seq.sync { count += 1 }
            }
            catch { note("写字节失败 \(base)：\(error.localizedDescription)") }
        }
        func saveText(_ t: String) {
            let trimmed = t.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            let dst = inbox.appendingPathComponent("t_text.txt")
            try? trimmed.write(to: dst, atomically: true, encoding: .utf8)
            seq.sync { count += 1 }
        }

        // ★ v47.15：沿用主 App v44 已验证的口径 —— 笼统 public.movie / public.image 常常没注册，
        //   直接 loadFileRepresentation 会失败（视频/混选时 count=0）。先取 provider 自报的具体类型。
        let generic: Set<String> = [
            UTType.item.identifier, UTType.data.identifier, UTType.content.identifier,
            UTType.movie.identifier, UTType.video.identifier, UTType.audiovisualContent.identifier,
            UTType.image.identifier, UTType.fileURL.identifier
        ]
        func mediaCandidates(_ p: NSItemProvider) -> [String] {
            var out: [String] = []
            for id in p.registeredTypeIdentifiers where !generic.contains(id) {
                guard let t = UTType(id) else { continue }
                if t.conforms(to: .movie) || t.conforms(to: .video) ||
                   t.conforms(to: .audiovisualContent) || t.conforms(to: .image) {
                    if !out.contains(id) { out.append(id) }
                }
            }
            for t in [UTType.quickTimeMovie, .mpeg4Movie, .jpeg, .png, .heic] {
                let id = t.identifier
                if !out.contains(id) && p.hasItemConformingToTypeIdentifier(id) { out.append(id) }
            }
            for t in [UTType.movie, .video, .audiovisualContent, .image] {
                let id = t.identifier
                if !out.contains(id) && p.hasItemConformingToTypeIdentifier(id) { out.append(id) }
            }
            return Array(out.prefix(6))
        }

        /// 单个 provider：文件 → item → 字节，逐候选串行回退，任一成功立刻收手（不重复保存）
        func loadMedia(_ p: NSItemProvider, _ ids: [String], _ hint: String? = nil, _ done: @escaping () -> Void) {
            if ids.isEmpty { done(); return }
            func tryFile(_ i: Int) {
                if i >= ids.count { tryItem(0); return }
                p.loadFileRepresentation(forTypeIdentifier: ids[i]) { url, _ in
                    if let u = url { saveURL(u, ids[i], hint); done(); return }
                    tryFile(i + 1)
                }
            }
            func tryItem(_ i: Int) {
                let sub = Array(ids.prefix(2))
                if i >= sub.count { tryData(0); return }
                p.loadItem(forTypeIdentifier: sub[i], options: nil) { obj, _ in
                    if let u = obj as? URL { saveURL(u, sub[i], hint); done(); return }
                    if let d = obj as? Data { saveData(d, sub[i], p.suggestedName, hint); done(); return }
                    tryItem(i + 1)
                }
            }
            func tryData(_ i: Int) {
                let sub = Array(ids.prefix(2))
                if i >= sub.count {
                    note("媒体读取失败：\(p.registeredTypeIdentifiers.prefix(6).joined(separator: ","))")
                    done(); return
                }
                p.loadDataRepresentation(forTypeIdentifier: sub[i]) { d, _ in
                    if let d { saveData(d, sub[i], p.suggestedName, hint); done(); return }
                    tryData(i + 1)
                }
            }
            tryFile(0)
        }

        /// 非媒体（文件 / 文本 / 未知类型）
        /// ★ v47.17 修「分享 IPA 文件名变 share_<UUID>.bin」：旧版把 fileURL 从候选里排除，
        ///   文件类附件一路落到 public.data 的 Data 分支，saveData 只能用 UUID 命名。
        ///   现在优先 fileURL（拿原始 URL = 原始文件名），其次 provider 自报的具体类型，
        ///   文本只在真注册了文本类型时才试，最后的 Data 兜底也带上 suggestedName。
        func loadOther(_ p: NSItemProvider, _ hint: String? = nil, _ done: @escaping () -> Void) {
            // ① 文件 URL：文件名 + 后缀都在这里，必须最优先
            // ★ v47.19：去掉 hasItemConformingTo(fileURL) 前置门槛。
            //   WorkBuddy 等 App 分享文件时只注册 public.data、不声明 fileURL，
            //   但 loadItem(forTypeIdentifier: fileURL) 实际仍能返回带原名的 URL。
            //   旧版被 guard 直接跳过 → 一路落到 public.data → saveData 用 UUID 命名 → IPA 变 share_UUID.bin。
            func tryFileURL() {
                p.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { obj, _ in
                    if let u = obj as? URL { note("fileURL 命中=\(u.lastPathComponent)"); saveURL(u, UTType.fileURL.identifier, hint); done(); return }
                    note("fileURL 未命中")
                    tryTyped(0)
                }
            }
            // ② provider 自报的具体非媒体类型（com.apple.itunes.ipa / zip / pdf…）
            func tryTyped(_ i: Int) {
                let ids = p.registeredTypeIdentifiers.filter {
                    $0 != UTType.fileURL.identifier && $0 != UTType.data.identifier && $0 != UTType.item.identifier
                }
                if i >= ids.count { tryGenericFile(0); return }
                p.loadFileRepresentation(forTypeIdentifier: ids[i]) { url, _ in
                    if let u = url { saveURL(u, ids[i], hint); done(); return }
                    // 具体类型走不通就试 loadItem（有些 provider 只给 Data）
                    p.loadItem(forTypeIdentifier: ids[i], options: nil) { obj, _ in
                        if let u = obj as? URL { saveURL(u, ids[i], hint); done(); return }
                        if let d = obj as? Data { saveData(d, ids[i], p.suggestedName, hint); done(); return }
                        tryTyped(i + 1)
                    }
                }
            }
            // ③ 通用 item/data 的文件表示：即使 provider 只注册 public.data，
            //   loadFileRepresentation 常仍返回带原文件名的临时 URL —— 这是 UUID 命名前的最后一道抢救。
            //   ★ v47.19：IPA 变 share_UUID.bin 就是漏了这一跳：ids 被过滤空 → 直接掉到 tryRaw(Data)。
            func tryGenericFile(_ i: Int) {
                let ids = [UTType.item.identifier, UTType.data.identifier]
                if i >= ids.count { tryText(); return }
                p.loadFileRepresentation(forTypeIdentifier: ids[i]) { url, _ in
                    if let u = url {
                        note("通用文件表示命中 \(ids[i])=\(u.lastPathComponent)")
                        saveURL(u, ids[i], hint); done(); return
                    }
                    tryGenericFile(i + 1)
                }
            }
            // ④ 真文本：仅当注册了文本类型才试，避免把二进制误当 UTF-8 文本
            func tryText() {
                let tid = p.hasItemConformingToTypeIdentifier(UTType.plainText.identifier)
                    ? UTType.plainText.identifier
                    : (p.hasItemConformingToTypeIdentifier(UTType.text.identifier) ? UTType.text.identifier : "")
                guard !tid.isEmpty else { tryRaw(); return }
                p.loadItem(forTypeIdentifier: tid, options: nil) { obj, _ in
                    if let s = obj as? String { saveText(s); done(); return }
                    if let d = obj as? Data, let s = String(data: d, encoding: .utf8) {
                        saveText(s); done(); return
                    }
                    tryRaw()
                }
            }
            // ④ 最后兜底：public.data，带 suggestedName 保住原名
            func tryRaw() {
                p.loadDataRepresentation(forTypeIdentifier: UTType.data.identifier) { d, _ in
                    if let d { saveData(d, UTType.data.identifier, p.suggestedName, hint) }
                    else { note("附件读取失败：\(p.registeredTypeIdentifiers.prefix(6).joined(separator: ","))") }
                    done()
                }
            }
            tryFileURL()
        }

        for item in items
        {
            // ★ v47.18：分享面板标题常带原文件名（文件 App / WorkBuddy 分享 IPA 时尤其），
            //   作为文件名兜底提示传给 saveURL/saveData。只取「像文件名」的一段（含点号且不太长）。
            let title = item.attributedContentText?.string
                .trimmingCharacters(in: .whitespacesAndNewlines)
            note("标题原文=\(title ?? "nil")")
            var nameHint: String? = nil
            if let t = title, t.contains("."), t.count <= 300,
               !t.contains("\n"), !t.hasPrefix("http") { nameHint = t }

            for provider in item.attachments ?? []
            {
                // 诊断：把每个 provider 的类型与建议名写全，下次一眼看出文件名藏在哪个字段
                note("注册类型=\(provider.registeredTypeIdentifiers.prefix(8).joined(separator: ","))")
                if let sn = provider.suggestedName, !sn.isEmpty { note("建议名=\(sn)") }
                if let nh = nameHint { note("标题名=\(nh)") }

                let ids = mediaCandidates(provider)
                group.enter()
                if ids.isEmpty { loadOther(provider, nameHint) { group.leave() } }
                else { loadMedia(provider, ids, nameHint) { group.leave() } }
            }
            // ★ v47.18：attributedContentText 若是文件名（含扩展名），别再当文本另存一份；
            //   只有纯文本标题（无扩展名）才走原来的文本保存路径。
            if let s = title, !s.isEmpty, nameHint == nil { saveText(s) }
        }

        // ★ v47.15：视频从 iCloud / 未导出相册导出可能几十秒，原 8s 必然超时 → 放宽到 90s。
        //   图片/文本通常在数秒内完成，届时 group 就绪会提前收尾，不会白等。
        DispatchQueue.global().async {
            let deadline = DispatchTime.now() + 90
            var toldSlow = false
            while group.wait(timeout: .now()) == .timedOut && DispatchTime.now() < deadline {
                if !toldSlow && DispatchTime.now() > deadline - 85 {
                    toldSlow = true
                    DispatchQueue.main.async { self.statusLabel.text = "视频导出较慢，请稍候…" }
                }
                usleep(50_000)
            }
            let n = seq.sync { count }
            // ★ v47.19：诊断取全部字段（旧版只取前 4 条，关键的 saveData 命名/建议名被截掉了）
            let d = seq.sync { diag.prefix(16).joined(separator: " | ") }
            DispatchQueue.main.async { self.finish(n, d) }
        }
    }

    func finish(_ count: Int, _ detail: String = "")
    {
        if count == 0
        {
            statusLabel.text = "没有可分享的内容"
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                self?.cancelTapped()
            }
            return
        }

        // 先告诉主 APP「inbox 有新东西」：它若本来就在后台跑着，这条通知能让它立刻去扫；
        // 万一跳转失败、用户过一会儿自己点开 App，内容也已经就绪。
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName("com.raydrop.ios.sharedItemsAdded" as CFString),
            nil, nil, true)

        // ★ v47.19：诊断必须先落地、再拉起主 APP。
        //   旧版顺序相反：jumpToHostApp() 一调用，主 APP 立刻起来读走 last_share_diag.txt，
        //   此时扩展还没写 → 主 APP 读到空/旧内容 → 三版诊断全部石沉大海。
        //   先写 route="?" 占位，跳转后若还能补写再更新；关键是让文件名诊断先可读。
        writeDiag(route: "pending", count: count, detail: detail)
        let route = jumpToHostApp()
        statusLabel.text = "已准备 \(count) 项，正在打开 RayDrop…"
        writeDiag(route: route, count: count, detail: detail)
        scheduleReadyNotification(count)

        // 留 0.35s 让跳转指令生效，再收掉分享面板（顺序反了会被系统把跳转吞掉）
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            self?.extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
        }
    }

    // MARK: - 拉起主 APP（v47）

    /// 依次尝试两条路径，返回实际用上的那条（写进诊断文件，主 APP 会打进日志）
    private func jumpToHostApp() -> String
    {
        guard let url = URL(string: "raydrop://shared") else { return "bad-url" }
        var route = "none"

        // ① 响应链找 UIApplication，调它的 openURL:（iOS 15/17 上实测有效）
        //    注意：扩展里禁止写 UIApplication.shared（编译期不可用 + 运行期断言），
        //    但顺着 next 链摸到的那个实例是现成的，不经过被禁的入口。
        let sel = NSSelectorFromString("openURL:")
        if let app = findResponder(respondingTo: sel)
        {
            _ = app.perform(sel, with: url)
            route = "responder"
        }

        // ② 官方接口，分享扩展上通常被无视，但万一某版系统放开了呢（成本几乎为零）
        if let ctx = extensionContext
        {
            ctx.open(url) { _ in }
            if route == "none" { route = "context" }
        }

        return route
    }

    /// 顺响应链（VC → view → window → … → UIApplication）找第一个能响应 sel 的对象
    private func findResponder(respondingTo sel: Selector) -> UIResponder?
    {
        var seeds: [UIResponder] = [self]
        if let v = viewIfLoaded
        {
            seeds.append(v)
            if let w = v.window { seeds.append(w) }
        }
        for seed in seeds
        {
            var cur: UIResponder? = seed
            var hops = 0
            while let c = cur, hops < 48
            {
                if c.responds(to: sel) { return c }
                cur = c.next
                hops += 1
            }
        }
        return nil
    }

    // MARK: - 通知兜底

    /// 5 秒后的本地通知：主 APP 一旦到前台会立刻撤销它，所以成功跳转时用户看不到；
    /// 只有跳转被系统吞掉时它才浮现，点一下照样进到「分享到 RayDrop」面板。
    private func scheduleReadyNotification(_ count: Int)
    {
        let center = UNUserNotificationCenter.current()
        let content = UNMutableNotificationContent()
        content.title = "已选好 \(count) 项"
        content.body = "点这里打开 RayDrop，选设备即可发送"
        content.sound = .default
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 5, repeats: false)
        let req = UNNotificationRequest(identifier: readyNotificationID, content: content, trigger: trigger)
        center.add(req) { _ in }
    }

    /// 把本次跳转结果写到 App Group，主 APP 读走后会删掉并打进日志
    private func writeDiag(route: String, count: Int, detail: String)
    {
        guard let base = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID) else { return }
        let f = base.appendingPathComponent("last_share_diag.txt")
        let compact = String(detail.prefix(1400))
        let text = "v47.19 跳转=\(route) 项=\(count)" + (compact.isEmpty ? "" : " | " + compact)
        try? text.write(to: f, atomically: true, encoding: .utf8)
    }
}
