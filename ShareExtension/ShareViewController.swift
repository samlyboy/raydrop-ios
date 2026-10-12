import Foundation
import UIKit
import UniformTypeIdentifiers

/// 分享扩展：把相册/文件/文本暂存到 App Group 的 inbox 目录，然后唤起主 APP 选设备发送。
/// 主 APP 的 consumeSharedItems() 会读取这里。
final class ShareViewController: UIViewController
{
    private let appGroupID = "group.com.raydrop.ios"
    private var statusLabel: UILabel!

    override func viewDidLoad() {
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
        let cancel = UIButton(type: .system); cancel.setTitle("取消", for: .normal)
        cancel.addTarget(self, action: #selector(cancelTapped), for: .touchUpInside)
        v.addArrangedSubview(icon); v.addArrangedSubview(statusLabel); v.addArrangedSubview(cancel)
        view.addSubview(v)
        NSLayoutConstraint.activate([
            v.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            v.centerYAnchor.constraint(equalTo: view.centerYAnchor),
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
        statusLabel.text = "已准备 \(count) 项，正在打开 RayDrop…"
        // 扩展里禁止 UIApplication.shared，但 NSExtensionContext.open 是允许的：
        // 它会直接跳到主 APP（而不是让用户手动切出去再找）。
        // 同时用 Darwin 通知兜底，保证主 APP 在后台时也能被唤醒扫描 inbox。
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName("com.raydrop.ios.sharedItemsAdded" as CFString),
            nil, nil, true)

        if let ctx = extensionContext, let url = URL(string: "raydrop://shared")
        {
            ctx.open(url) { success in
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                    self?.extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
                }
            }
        }
        else
        {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
            }
        }
    }
}
