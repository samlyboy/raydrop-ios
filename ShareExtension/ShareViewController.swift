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
        let lock = NSLock()
        var count = 0
        let seq = DispatchQueue(label: "share.copy")

        func save(_ src: URL) {
            let base = src.lastPathComponent.isEmpty ? ("share_" + UUID().uuidString) : src.lastPathComponent
            let dst = inbox.appendingPathComponent("f_" + base)
            try? FileManager.default.removeItem(at: dst)
            // loadFileRepresentation 给的 URL 是系统临时文件，回调结束即被删除 → 必须同步复制
            do { try FileManager.default.copyItem(at: src, to: dst) } catch { return }
            seq.sync { count += 1 }
        }
        func saveText(_ t: String) {
            let trimmed = t.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            let dst = inbox.appendingPathComponent("t_text.txt")
            try? trimmed.write(to: dst, atomically: true, encoding: .utf8)
            seq.sync { count += 1 }
        }

        for item in items
        {
            for provider in item.attachments ?? []
            {
                if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
                {
                    group.enter()
                    provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { obj, _ in
                        defer { group.leave() }
                        if let u = obj as? URL { save(u) }
                    }
                }
                // 图片/视频：用具体的 image / movie 类型注册，UTType.item 在相册分享时匹配不到
                else if provider.hasItemConformingToTypeIdentifier(UTType.movie.identifier)
                {
                    group.enter()
                    provider.loadFileRepresentation(forTypeIdentifier: UTType.movie.identifier) { url, _ in
                        defer { group.leave() }
                        if let url { save(url) }
                    }
                }
                else if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier)
                {
                    group.enter()
                    provider.loadFileRepresentation(forTypeIdentifier: UTType.image.identifier) { url, _ in
                        defer { group.leave() }
                        if let url { save(url) }
                    }
                }
                else if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier)
                {
                    group.enter()
                    provider.loadItem(forTypeIdentifier: UTType.plainText.identifier, options: nil) { obj, _ in
                        defer { group.leave() }
                        if let s = obj as? String { saveText(s) }
                    }
                }
                else
                {
                    // 兜底：任何 public.data 类附件
                    group.enter()
                    provider.loadFileRepresentation(forTypeIdentifier: UTType.data.identifier) { url, _ in
                        defer { group.leave() }
                        if let url { save(url) }
                    }
                }
            }
            if let s = item.attributedContentText?.string { saveText(s) }
        }

        // 等所有异步回调（最多 8 秒）
        let deadline = DispatchTime.now() + 8
        DispatchQueue.global().async {
            while group.wait(timeout: .now()) == .timedOut && DispatchTime.now() < deadline {
                usleep(50_000)
            }
            let n = seq.sync { count }
            DispatchQueue.main.async { self.finish(n) }
        }
    }

    func finish(_ count: Int)
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

        let route = jumpToHostApp()
        statusLabel.text = "已准备 \(count) 项，正在打开 RayDrop…"
        writeDiag(route: route, count: count)
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
    private func writeDiag(route: String, count: Int)
    {
        guard let base = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID) else { return }
        let f = base.appendingPathComponent("last_share_diag.txt")
        let text = "v47 跳转=\(route) 项=\(count)"
        try? text.write(to: f, atomically: true, encoding: .utf8)
    }
}
