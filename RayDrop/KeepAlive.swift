import Foundation
import AVFoundation
import UIKit

/// 后台保活：iOS 只允许在声明的后台模式里继续执行代码。声明 `audio` 后，用一个
/// 静音循环音频会话把进程挂在后台，从而让 UDP 发现 + TCP 接收服务持续运行。
/// 不播放任何声音（volume = 0 且输出混音为静音），仅作为保活占位。
final class RDKeepAlive: NSObject, AVAudioPlayerDelegate
{
    private static var _shared: RDKeepAlive?
    static let shared = RDKeepAlive()

    private var player: AVAudioPlayer?
    private var session: AVAudioSession?
    private var timer: Timer?

    @objc private func handleInterruption(_ note: Notification) { /* 中断后尝试恢复 */ }

    /// 启动保活（可在 App 启动时调用一次）
    func start()
    {
        if player != nil { return }

        let session = AVAudioSession.sharedInstance()
        self.session = session
        do {
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)
        } catch { }

        // 生成 1 秒静音 WAV 并循环播放
        if let url = Self.makeSilentWav(),
           let p = try? AVAudioPlayer(contentsOf: url)
        {
            p.volume = 0.0001        // 几乎无声；配合混音策略用户听不到
            p.numberOfLoops = -1     // 无限循环
            p.delegate = self
            p.prepareToPlay()
            p.play()
            self.player = p
        }

        // 兜底：定期把会话重新激活，防止长时间后台被系统挂起
        let t = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            guard let self, self.player?.isPlaying == true else { return }
            try? AVAudioSession.sharedInstance().setActive(true, options: [])
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t

        NotificationCenter.default.addObserver(
            self, selector: #selector(handleInterruption(_:)),
            name: AVAudioSession.interruptionNotification, object: nil)
    }

    /// 在 SwiftUI App 上声明 @UIApplicationDelegateAdaptor，把启动钩子接进来
    func stop()
    {
        timer?.invalidate(); timer = nil
        player?.stop(); player = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// 动态生成 1 秒静音 PCM WAV（44.1kHz / 单声道 / 16bit）
    private static func makeSilentWav() -> URL? {
        let sampleRate: UInt32 = 44100
        let seconds: UInt32 = 1
        let samples = sampleRate * seconds
        let dataSize = Int(samples) * 2               // 16-bit mono
        let byteRate = sampleRate * 2
        let blockAlign: UInt16 = 2
        var data = Data()

        func append32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        func append16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        func appendTag(_ s: String) { data.append(contentsOf: Array(s.utf8)) }

        appendTag("RIFF"); append32(UInt32(36 + dataSize)); appendTag("WAVE")
        appendTag("fmt "); append32(16); append16(1); append16(1)
        append32(sampleRate); append32(byteRate); append16(blockAlign); append16(16)
        appendTag("data"); append32(UInt32(dataSize))
        data.append(Data(count: dataSize))            // 全 0 = 静音

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("rd_keepalive.wav")
        do { try data.write(to: url); return url } catch { return nil }
    }
}

/// App 委托：负责启动保活、监听分享扩展的通知、唤醒主界面处理分享
final class RDAppDelegate: NSObject, UIApplicationDelegate
{
    private var shareObserver: Any?

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]?) -> Bool
    {
        RDKeepAlive.shared.start()
        listenForShare()
        return true
    }

    /// 分享扩展通过 Darwin 通知告知"inbox 里有新文件"；主 APP 在前台或后台都会收到
    private func listenForShare()
    {
        let name = "com.raydrop.ios.sharedItemsAdded" as CFString
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(self).toOpaque(),
            { _, _, _, _, _ in
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: .rdAppShouldScanInbox, object: nil)
                }
            },
            name, nil, .deliverImmediately)
    }

    /// 分享扩展用 URL scheme 唤起主 APP
    func application(_ app: UIApplication, open url: URL,
                     options: [UIApplication.OpenURLOptionsKey: Any] = [:]) -> Bool
    {
        NotificationCenter.default.post(name: .rdAppShouldScanInbox, object: nil)
        return true
    }
}
