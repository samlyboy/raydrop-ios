import Foundation
import AVFoundation
import UIKit
import UserNotifications

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

    /// 音频中断（来电 / 其它 App 抢占）结束后恢复播放：否则保活静默失效、后台服务被挂起、对端误判离线。
    @objc private func handleInterruption(_ note: Notification) {
        guard let info = note.userInfo,
              let raw = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        guard type == .ended else { return }
        try? AVAudioSession.sharedInstance().setActive(true, options: [])
        player?.play()
    }

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

        // 兜底（双保险）：定期检查——会话被系统回收就重新激活，播放器被中断就重新开播。
        // 只"重新激活会话"不够：中断后 player 会停，必须重开播，否则后台保活失效 → 对端误判离线。
        let t = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            guard let self else { return }
            if self.player?.isPlaying != true { self.player?.play() }
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
        // ★ 不能用「全 0 数字静音」：部分 iOS 版本会把纯静音视作无效播放而挂起 App，
        //   后台 UDP 发现随之停摆 → 对端把本机误判为离线（而 Tailscale 由独立扩展进程持有，仍显示在线）。
        //   改用 200Hz 正弦、幅度 ±8 LSB（≈-72dBFS，再叠加 player 音量后完全听不见），出声数据非零 → 保活更稳。
        var pcm = Data(capacity: dataSize)
        for i in 0..<Int(samples) {
            let v = Int16(round(8.0 * sin(2.0 * Double.pi * 200.0 * Double(i) / Double(sampleRate))))
            withUnsafeBytes(of: v.littleEndian) { pcm.append(contentsOf: $0) }
        }
        data.append(pcm)

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
        RDShareNotify.requestAuthIfNeeded()
        listenForShare()
        return true
    }

    /// ★ v46：切到后台开始计时（空闲 2 分钟就结束进程；有传输则一直等着）
    func applicationDidEnterBackground(_ application: UIApplication)
    {
        RDIdleExit.shared.didEnterBackground()
    }

    /// 回到前台立刻取消计时
    func applicationWillEnterForeground(_ application: UIApplication)
    {
        RDIdleExit.shared.willEnterForeground()
        // ★ v47：已经回到 App 了，分享扩展排的那条「点此发送」通知就没意义了 → 撤掉
        RDShareNotify.cancelReady()
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

/// 后台空闲自动退出（v46）
///
/// 需求：切到后台时，**没有在传文件**就 2 分钟后结束进程；**正在传**就一直活着。
///
/// 为什么不是「进后台立刻退」：这个 App 靠静音音频保活，进后台后进程本来就会一直跑，
/// 不收文件也不传文件时白占内存、还一直挂着一个后台音频。给个 2 分钟宽限期，是为了
/// 覆盖「刚切出去马上又切回来」「对端刚好这时候发文件过来」这两种情况。
///
/// 判定用轮询而不是监听状态变化：Engine 里 txActive / sendingToID / preparing 三个
/// 标记会在很多处被改动（开始、结束、中止、失败、超时），逐个挂钩容易漏；每 5 秒问一次
/// 「现在忙吗」最不容易出错，代价可以忽略。
final class RDIdleExit
{
    static let shared = RDIdleExit()

    /// 由 Engine 注入：是否正在传输 / 连接中 / 正在导出素材
    var isBusy: () -> Bool = { false }

    /// 后台空闲多久结束进程
    private let limit: TimeInterval = 120
    /// 轮询间隔
    private let tickInterval: TimeInterval = 5

    private var timer: Timer?
    private var idleSince: Date?
    private var inBackground = false
    private var fired = false

    func didEnterBackground()
    {
        guard !fired else { return }
        inBackground = true
        // 进后台那一刻就在传 → 先不计时；等它传完再由 evaluate 起算
        idleSince = isBusy() ? nil : Date()
        startTicking()
    }

    func willEnterForeground()
    {
        inBackground = false
        idleSince = nil
        stopTicking()
    }

    private func startTicking()
    {
        stopTicking()
        let t = Timer.scheduledTimer(withTimeInterval: tickInterval, repeats: true) { [weak self] _ in
            self?.evaluate()
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func stopTicking()
    {
        timer?.invalidate()
        timer = nil
    }

    private func evaluate()
    {
        guard inBackground, !fired else { return }
        if isBusy() {
            // 又忙起来了：清空起点，等这次传完重新计 2 分钟
            idleSince = nil
            return
        }
        if idleSince == nil { idleSince = Date() }
        guard let since = idleSince, Date().timeIntervalSince(since) >= limit else { return }
        shutdown()
    }

    private func shutdown()
    {
        fired = true
        stopTicking()
        RDKeepAlive.shared.stop()          // 先把静音音频停掉，别让系统音频会话悬着
        UserDefaults.standard.synchronize() // 退出前落盘，防止刚改的名字/编号丢失
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { exit(0) }
    }
}


/// 分享扩展 ↔ 主 APP 的通知协作（v47）
///
/// 为什么需要它：iOS 不让分享扩展切到宿主 APP。v47 用非官方接口强行跳转（见
/// `ShareViewController.jumpToHostApp()`），但那条路不是 100% 有效，所以扩展同时排了
/// 一条 5 秒后的本地通知当兜底 —— 跳转成功时主 APP 会在 5 秒内到前台，这里把它撤掉，
/// 用户什么都看不到；跳转失败时通知才浮现，点一下照样进面板。
///
/// 通知授权只能在主 APP 里申请（扩展无权弹授权框），因此启动时问一次；用户拒绝的话
/// 整套兜底自动失效，退化成「回相册」，不影响其它功能。
enum RDShareNotify
{
    /// 与 `ShareViewController.readyNotificationID` 必须一致
    static let readyID = "rd_share_ready"

    static func requestAuthIfNeeded()
    {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { s in
            guard s.authorizationStatus == .notDetermined else { return }
            center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
    }

    /// 撤掉（未送达的 + 已送达的）分享就绪通知
    static func cancelReady()
    {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [readyID])
        center.removeDeliveredNotifications(withIdentifiers: [readyID])
    }
}
