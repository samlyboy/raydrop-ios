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
        var urls: [URL] = []
        var text = ""

        // 先把 NSItemProvider 提供的文件拷到 inbox
        for item in items
        {
            for provider in item.attachments ?? []
            {
                if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
                {
                    provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { obj, _ in
                        if let u = obj as? URL { urls.append(u) }
                    }
                }
                else if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier)
                    || provider.hasItemConformingToTypeIdentifier(UTType.movie.identifier)
                    || provider.hasItemConformingToTypeIdentifier("public.data")
                {
                    provider.loadFileRepresentation(forTypeIdentifier: UTType.item.identifier) { url, _ in
                        if let url { urls.append(url) }
                    }
                }
                else if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier)
                {
                    provider.loadItem(forTypeIdentifier: UTType.plainText.identifier, options: nil) { obj, _ in
                        if let s = obj as? String { text += s }
                    }
                }
            }
            if let s = item.attributedContentText?.string { text += s }
        }

        // 等待 provider 的异步回调落地（最多 1.5s）
        let deadline = Date().addingTimeInterval(1.5)
        while Date() < deadline && urls.isEmpty && text.isEmpty { usleep(50_000) }
        usleep(300_000)

        var count = 0
        if let inbox = inboxDir()
        {
            for u in urls
            {
                let base = u.lastPathComponent.isEmpty ? ("share_" + UUID().uuidString) : u.lastPathComponent
                let dst = inbox.appendingPathComponent("f_" + base)
                try? FileManager.default.removeItem(at: dst)
                do { try FileManager.default.copyItem(at: u, to: dst); count += 1 } catch { }
            }
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            {
                let dst = inbox.appendingPathComponent("t_text.txt")
                try? text.write(to: dst, atomically: true, encoding: .utf8)
                count += 1
            }
        }

        DispatchQueue.main.async { self.finish(count) }
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
        // 扩展里不能调 UIApplication.shared（iOS 会拒绝编译），也拉不起主 APP。
        // 做法：只把文件放进 App Group 的 inbox，然后关闭扩展；
        // 主 APP 在 onAppear / 回前台 / 收到 Darwin 通知时扫描 inbox 并弹设备列表。
        // 用 CFNotificationCenter 通知主 APP（主 APP 已在后台时也能被唤醒）。
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName("com.raydrop.ios.sharedItemsAdded" as CFString),
            nil, nil, true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
        }
    }
}
