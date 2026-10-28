import Foundation
import Photos
import UIKit
import UniformTypeIdentifiers

/// 把收到的图片/视频再存一份进系统「照片」相册。
///
/// 原则：**原文件直传直存，绝不转码、不改容器、不重编码**。
/// 「下载」里那份是原始字节，相册写的也是同一个文件（PhotoKit 内部只做拷贝入库）。
///
/// 历史坑与对策：
/// 1. 旧写法靠 `creationRequestForAssetFromImage(atFileURL:)` 推断类型，而临时文件名是
///    `rd_<uuid>`（无扩展名）→ 系统判不出类型，写入失败且错误被忽略 → 发送端说成功、相册没有。
///    对策：入库前保证文件**带正确扩展名**（必要时只改名字，不动内容）。
/// 2. v34 给视频加了 `AVURLAsset` 轨道预检，读不出视频轨就直接放弃入库 → 误杀能播的文件。
///    对策（v35）：去掉任何预检，直接交给 PhotoKit，由写入结果说话。
/// 3. 单一写法失败就彻底放弃 → 多策略依次兜底（v35）。
/// 4. **v38 两个真机故障**：
///    ① iOS 17「收完就闪退到桌面」：旧 `commit` 写成功后用 `PHAsset.fetchAssets` 回查类型，
///       这是**读**接口，而 Info.plist 只有 `NSPhotoLibraryAddUsageDescription`（只加不读）。
///       iOS 17 的 TCC 发现越权读隐私数据 → 直接杀进程，表现就是收完最后一张就闪回桌面。
///       对策：只在**确实拿到读权限**时才做回查；否则以 `performChanges` 的返回值定性。
///       同时补上 `NSPhotoLibraryUsageDescription`，杜绝任何读接口触发 TCC 崩溃。
///    ② iOS 15「显示已存但相册没有」：日志是 `PHPhotosErrorDomain#-1`，图片视频全中。
///       根因是旧实现**信任扩展名**去定 UTI：发送端把 HEIC 装成 .jpeg 发过来时，
///       给 PhotoKit 的 UTI(`public.jpeg`) 与真实字节(`heic`) 不符 → 写入被拒。
///       对策：入库前**读文件头魔数**嗅探真实容器（jpeg/png/heic/gif/webp/mov/mp4），
///       按真实类型定扩展名与 UTI；再补上「不给 UTI 让系统自己判」和「data 直写」两条纯字节路径。
/// 5. 仍失败时的最后兜底（v38）：`UISaveVideoAtPathToSavedPhotosAlbum` /
///    `UIImageWriteToSavedPhotosAlbum` —— iOS 最老的存图存视频接口，兼容性最好。
///    视频那条是**整文件拷贝、不改字节**；图片那条会由系统重新编码一次，仅在全部 PhotoKit
///    路径都失败时使用（有总比彻底没有好），日志里会标明走了兜底。
/// 6. **v39 两个真机故障（iOS 17 → iOS 15 视频不进相册，反向正常）**：
///    ① **假成功**：`performChanges` 回 `ok=true` 只代表 change block 没抛异常。创建请求返回
///       nil 时 block 里什么都没做，系统照样回 ok → 旧代码 `done(true, "")`，日志打「已存相册」
///       而相册里没有，且**后面四条兜底全被跳过**（iOS 17 上第一条策略直接成功，所以只有
///       老系统暴露）。对策：必须拿到 placeholder（真实资产 id）才算写入成功。
///    ② **名字与字节不一致**：`originalFilename` 沿用对端原名（可能是 `.mp4`），而真实容器是
///       MOV。iOS 15 严格按名字校验 → 直接拒收（错误只剩 `PHPhotosErrorDomain#-1`）；iOS 17 宽容。
///       对策：`originalFilename` 的后缀改成嗅探出的真实容器。
///    另外把苹果标准入口 `creationRequestForAssetFromVideo` 提到第一位、补一条「视频字节直写」，
///    并让临时副本走**硬链接**（几 GB 视频不再整份复制）。
enum RDMediaSaver {

    typealias Done = (Bool, String) -> Void
    private typealias Attempt = (@escaping Done) -> Void

    /// 最后兜底用的委托对象（老 API 只认 target/selector）
    private final class LegacySaver: NSObject {
        static let shared = LegacySaver()
        private var slots: [Int: Done] = [:]
        private var next = 0
        private let lock = NSLock()

        func reserve(_ done: @escaping Done) -> UnsafeMutableRawPointer {
            lock.lock()
            let key = next; next += 1
            slots[key] = done
            lock.unlock()
            // +1 保证指针非 nil（0 会被当成 no context）
            return UnsafeMutableRawPointer(bitPattern: key + 1)!
        }

        private func take(_ p: UnsafeMutableRawPointer?) -> Done? {
            guard let p else { return nil }
            let key = Int(bitPattern: p) - 1
            lock.lock(); let d = slots.removeValue(forKey: key); lock.unlock()
            return d
        }

        @objc func image(_ image: UIImage, didFinishSavingWithError error: Error?, contextInfo: UnsafeMutableRawPointer?) {
            let d = take(contextInfo); guard let cb = d else { return }
            guard let e = error as NSError? else { cb(true, ""); return }
            cb(false, "老接口 \(e.domain)#\(e.code) \(e.localizedDescription)")
        }

        @objc func video(_ path: String, didFinishSavingWithError error: Error?, contextInfo: UnsafeMutableRawPointer?) {
            let d = take(contextInfo); guard let cb = d else { return }
            guard let e = error as NSError? else { cb(true, ""); return }
            cb(false, "老接口 \(e.domain)#\(e.code) \(e.localizedDescription)")
        }
    }

    /// 定扩展名：先看真实字节，再退回原名，最后按 mime 兜
    static func extFor(file: URL, name: String, mime: String) -> String {
        if let sniffed = sniffExt(file) { return sniffed }
        let existing = (name as NSString).pathExtension.lowercased()
        if !existing.isEmpty { return existing }
        let m = mime.lowercased()
        if m.hasPrefix("video/") || m.hasPrefix("image/") { return RD.ext(forMime: mime) }
        return RD.isVideoFile(name: name, mime: mime) ? "mov" : "jpg"
    }

    /// 把「下载」里**已落盘**的文件额外存一份进相册（不移动、不删除、不改内容）。
    static func saveExisting(file: URL, name: String, mime: String, completion: @escaping Done) {
        // ★★ v43 关键修复：媒体种类一律以**文件头魔数**为准，name/mime 只作兜底。
        //
        //   真机故障（iOS 17 → iOS 15 视频只进「下载」不进相册）：
        //   那段视频在相册里的原始文件名就是 `106644.jpeg`，于是发送端按扩展名算出
        //   `image/jpeg`，这里按 name/mime 判成「图片」→ 拿 `addResource(.photo)` 去写一个
        //   9.8MB 的 QuickTime 容器 → PhotoKit 直接拒收 `PHPhotosErrorDomain#3302`，
        //   而真正该走的 6 条视频路径（含苹果标准入口）**一条都没试**。
        //   名字会撒谎（相册导出、聊天软件保存、第三方 App 导入都会改名字），字节不会。
        let sniffed = sniffExt(file)
        let videoExts: Set<String> = ["mov", "mp4", "m4v", "3gp", "3g2", "avi", "mkv",
                                      "webm", "ts", "mpg", "mpeg", "wmv", "flv"]
        let isVideo: Bool
        let isImage: Bool
        if let s = sniffed {
            isVideo = videoExts.contains(s)
            isImage = !isVideo
        } else {
            // 魔数认不出（极少数封装）→ 退回按名字/mime 判
            isVideo = RD.isVideoFile(name: name, mime: mime)
            isImage = RD.isImageFile(name: name, mime: mime)
        }
        guard isVideo || isImage else {
            // 非媒体文件（.pdf/.zip/.txt…）本来就不该进相册
            completion(true, "")
            return
        }
        // ★ 只许回调一次：调用方用 withCheckedContinuation 等这个结果，
        //   多回调一次在 Swift 里是致命错误（直接闪退），这里统一兜住。
        let done = once(completion)
        authorize { ok, why in
            if ok { run(file: file, name: name, mime: mime, isVideo: isVideo, completion: done) }
            else { done(false, why) }
        }
    }

    /// 包一层「最多只触发一次」
    private static func once(_ cb: @escaping Done) -> Done {
        let lock = NSLock()
        var fired = false
        return { ok, msg in
            lock.lock()
            if fired { lock.unlock(); return }
            fired = true
            lock.unlock()
            cb(ok, msg)
        }
    }

    private static func authorize(_ cb: @escaping (Bool, String) -> Void) {
        switch PHPhotoLibrary.authorizationStatus(for: .addOnly) {
        case .authorized, .limited:
            cb(true, "")
        case .notDetermined:
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { st in
                if st == .authorized || st == .limited { cb(true, "") }
                else { cb(false, "未获得相册写入权限") }
            }
        default:
            cb(false, "相册权限被拒绝（设置 → RayDrop锐传 → 照片 → 添加照片）")
        }
    }

    // MARK: - 编排

    private static func run(file: URL, name: String, mime: String, isVideo: Bool, completion: @escaping Done) {
        let ext = extFor(file: file, name: name, mime: mime)
        // 保证交给 PhotoKit 的 URL 后缀与真实容器一致（只改名，不动字节）
        let src = urlWithExtension(file, ext: ext)
        let uti = UTType(filenameExtension: ext)?.identifier
            ?? UTType(mimeType: mime)?.identifier
            ?? (isVideo ? UTType.quickTimeMovie.identifier : UTType.jpeg.identifier)
        // ★ v39：交给 PhotoKit 的 originalFilename 后缀**必须与真实容器一致**。
        //   iOS 15 对「名字说 mp4、字节是 mov」这种情况会直接拒收（错误只剩 PHPhotosErrorDomain#-1），
        //   而 iOS 17 会宽容地按字节判。只改名字，不改一个字节。
        let baseName = (name as NSString).deletingPathExtension
        let albumName = (baseName.isEmpty ? "RayDrop" : baseName) + "." + ext

        var attempts: [Attempt] = []

        if isVideo {
            // ★ v39 顺序重排：苹果「把视频文件加进相册」的标准入口放到**第一位**。
            //   它是 iOS 上最老、兼容性最好的写视频路径（iOS 15 上实测比 addResource 稳），
            //   旧版把它排第三，前面两条一旦「假成功」就轮不到它 —— 见 commit() 的 pid 校验。
            // ① 苹果标准入口：creationRequestForAssetFromVideo（系统自己做容器校验）
            attempts.append { done in
                commit(isVideo: true) { pid in
                    if let req = PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: src) {
                        pid = req.placeholderForCreatedAsset?.localIdentifier
                    }
                } done: { done($0, $1) }
            }
            // ② 不给 UTI：让 PhotoKit 自己按真实字节判容器（最贴近「原样入库」）
            attempts.append { done in
                let o = PHAssetResourceCreationOptions()
                o.originalFilename = albumName
                commit(isVideo: true) { pid in
                    let req = PHAssetCreationRequest.forAsset()
                    req.addResource(with: .video, fileURL: src, options: o)
                    pid = req.placeholderForCreatedAsset?.localIdentifier
                } done: { done($0, $1) }
            }
            // ③ 给按真实容器推出的 UTI
            attempts.append { done in
                let o = PHAssetResourceCreationOptions()
                o.originalFilename = albumName
                o.uniformTypeIdentifier = uti
                commit(isVideo: true) { pid in
                    let req = PHAssetCreationRequest.forAsset()
                    req.addResource(with: .video, fileURL: src, options: o)
                    pid = req.placeholderForCreatedAsset?.localIdentifier
                } done: { done($0, $1) }
            }
            // ④ 字节直写：完全绕开「文件路径 / 后缀 / 沙盒可读性」，写进去的还是原始字节。
            //    路径类写法在个别系统版本上会因为临时目录权限或 URL 指向被拒，这条能兜住。
            //    视频可能很大，加 256MB 上限，避免整文件读进内存把 App 撑爆。
            attempts.append { done in
                let size = ((try? FileManager.default.attributesOfItem(atPath: src.path))?[.size] as? NSNumber)?.intValue ?? 0
                guard size > 0, size <= 256 * 1024 * 1024 else {
                    done(false, "文件 \(size / 1048576)MB，跳过字节直写"); return
                }
                guard let data = try? Data(contentsOf: src), !data.isEmpty else {
                    done(false, "读不出文件内容"); return
                }
                let o = PHAssetResourceCreationOptions()
                o.originalFilename = albumName
                o.uniformTypeIdentifier = uti
                commit(isVideo: true) { pid in
                    let req = PHAssetCreationRequest.forAsset()
                    req.addResource(with: .video, data: data, options: o)
                    pid = req.placeholderForCreatedAsset?.localIdentifier
                } done: { done($0, $1) }
            }
            // ⑤ 换成临时目录里的干净文件名再试一次（排除文件名/路径引起的拒收）
            attempts.append { done in
                guard let clean = copyToTemp(src, ext: ext) else {
                    done(false, "无法创建临时副本"); return
                }
                commit(isVideo: true) { pid in
                    if let req = PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: clean) {
                        pid = req.placeholderForCreatedAsset?.localIdentifier
                    }
                } done: { ok, detail in
                    // ⚠️ 必须等 PhotoKit 真正做完再删副本：performChanges 是异步的，
                    //    用 defer 会在它读文件之前就把副本删掉。
                    try? FileManager.default.removeItem(at: clean)
                    done(ok, detail)
                }
            }
            // ⑥ 最后兜底：老接口，整文件拷贝入库（不改字节），iOS 15 上兼容性最好
            attempts.append { done in
                let ctx = LegacySaver.shared.reserve(done)
                UISaveVideoAtPathToSavedPhotosAlbum(src.path, LegacySaver.shared,
                                                    #selector(LegacySaver.video(_:didFinishSavingWithError:contextInfo:)),
                                                    ctx)
            }
        } else {
            // ① 不给 UTI：HEIC 装成 .jpeg 这类「名实不符」的坑，交给系统嗅探最保险
            attempts.append { done in
                let o = PHAssetResourceCreationOptions()
                o.originalFilename = albumName
                commit(isVideo: false) { pid in
                    let req = PHAssetCreationRequest.forAsset()
                    req.addResource(with: .photo, fileURL: src, options: o)
                    pid = req.placeholderForCreatedAsset?.localIdentifier
                } done: { done($0, $1) }
            }
            // ② data 直写：完全绕开文件路径/后缀问题，写入的是原始字节
            attempts.append { done in
                guard let data = try? Data(contentsOf: src), !data.isEmpty else {
                    done(false, "读不出文件内容"); return
                }
                let o = PHAssetResourceCreationOptions()
                o.originalFilename = albumName
                o.uniformTypeIdentifier = uti
                commit(isVideo: false) { pid in
                    let req = PHAssetCreationRequest.forAsset()
                    req.addResource(with: .photo, data: data, options: o)
                    pid = req.placeholderForCreatedAsset?.localIdentifier
                } done: { done($0, $1) }
            }
            // ③ fileURL + UTI
            attempts.append { done in
                let o = PHAssetResourceCreationOptions()
                o.originalFilename = albumName
                o.uniformTypeIdentifier = uti
                commit(isVideo: false) { pid in
                    let req = PHAssetCreationRequest.forAsset()
                    req.addResource(with: .photo, fileURL: src, options: o)
                    pid = req.placeholderForCreatedAsset?.localIdentifier
                } done: { done($0, $1) }
            }
            // ④ 苹果的「把图片文件加进相册」标准入口
            attempts.append { done in
                commit(isVideo: false) { pid in
                    if let req = PHAssetChangeRequest.creationRequestForAssetFromImage(atFileURL: src) {
                        pid = req.placeholderForCreatedAsset?.localIdentifier
                    }
                } done: { done($0, $1) }
            }
            // ⑤ 最后兜底：老接口（系统会重新编码一次，仅在前四条全失败时使用）
            attempts.append { done in
                guard let img = UIImage(contentsOfFile: src.path) else {
                    done(false, "解不出图片"); return
                }
                let ctx = LegacySaver.shared.reserve(done)
                UIImageWriteToSavedPhotosAlbum(img, LegacySaver.shared,
                                               #selector(LegacySaver.image(_:didFinishSavingWithError:contextInfo:)),
                                               ctx)
            }
        }

        // 全部失败时把「真实容器 + 大小」带上，真机排查时能直接判断是不是容器/编码不被支持
        let madeTemp = (src != file)
        next(attempts, 0, [], { ok, msg in
            // 先取大小再清临时副本（顺序不能反，删掉就读不到了）
            let sz = ((try? FileManager.default.attributesOfItem(atPath: src.path))?[.size] as? NSNumber)?.int64Value ?? 0
            if madeTemp { try? FileManager.default.removeItem(at: src) }
            guard !ok else { completion(true, ""); return }
            let mb = String(format: "%.1f", Double(sz) / 1048576.0)
            completion(false, "[真实容器=\(ext) \(mb)MB] " + msg)
        })
    }

    /// 依次尝试；全部失败时把每一步的原因拼起来回报
    private static func next(_ list: [Attempt], _ i: Int, _ errs: [String], _ completion: @escaping Done) {
        guard i < list.count else {
            completion(false, errs.isEmpty ? "系统拒绝写入相册" : errs.joined(separator: " / "))
            return
        }
        list[i]({ ok, detail in
            if ok { completion(true, "") }
            else {
                let tag = "方案\(i + 1)：\(detail)"
                next(list, i + 1, errs + [tag], completion)
            }
        })
    }

    /// 执行一次 performChanges（+ 有读权限时才做写后校验）
    private static func commit(isVideo: Bool,
                               _ build: @escaping (inout String?) -> Void,
                               done: @escaping Done) {
        var pid: String?
        PHPhotoLibrary.shared().performChanges({
            build(&pid)
        }) { ok, err in
            guard ok else {
                let ns = err as NSError?
                // 带上当前授权状态：真机排查时一眼能分清「权限没给」还是「文件被拒」
                let auth = PHPhotoLibrary.authorizationStatus(for: .addOnly).rawValue
                let base = ns.map { "\($0.domain)#\($0.code) \($0.localizedDescription)" } ?? "系统未说明原因"
                done(false, base + " [auth=\(auth)]")
                return
            }
            // ★★ v39 关键修复：`performChanges` 回 ok=true 只代表「change block 没抛异常」，
            //    **不代表真的写进去了**。当创建请求自己返回 nil（老系统对某些容器/编码、
            //    或文件路径不可读时会这样），block 里一个操作都没执行，系统照样回 ok=true。
            //    旧代码在这里 `done(true, "")` → 日志打「已存相册」，相册里空空如也，
            //    而且**后面四条兜底策略全被跳过**。这正是 iOS 15 上「视频显示已存、相册没有」的成因。
            //    修法：必须先拿到 placeholder（真实资产 id）才算写入成功，否则判失败、继续走下一策略。
            guard let id = pid, !id.isEmpty else {
                done(false, "系统未创建相册资产（creationRequest 返回 nil，本机可能不支持该容器/编码）")
                return
            }
            // ⚠️ 只有**确实拿到读权限**才能 fetch。否则在 iOS 17 上会因缺少
            //    NSPhotoLibraryUsageDescription 被 TCC 直接杀进程（用户看到的就是「收完闪退」）。
            guard canReadLibrary() else {
                done(true, "")     // 没有读权限：placeholder 已拿到 = 确实入库，不做越权回查
                return
            }
            guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject else {
                done(true, "")     // 拿到 placeholder 但查不到：以创建成功为准
                return
            }
            let want: PHAssetMediaType = isVideo ? .video : .image
            if asset.mediaType == want {
                done(true, "")
            } else {
                done(false, "已写入但类型不符（mediaType=\(asset.mediaType.rawValue)）")
            }
        }
    }

    /// 是否拥有「读取相册」权限（决定能不能安全地回查 PHAsset）
    private static func canReadLibrary() -> Bool {
        PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized
    }

    // MARK: - 小工具

    /// 文件后缀与目标不一致（或没有后缀）时，复制一份带正确后缀的临时文件；一致则原样返回。
    /// 只改文件名，内容一个字节都不动。
    private static func urlWithExtension(_ file: URL, ext: String) -> URL {
        let cur = file.pathExtension.lowercased()
        if cur == ext.lowercased(), !cur.isEmpty { return file }
        if let c = copyToTemp(file, ext: ext) { return c }
        return file
    }

    private static func copyToTemp(_ file: URL, ext: String) -> URL? {
        let dst = FileManager.default.temporaryDirectory
            .appendingPathComponent("rd_album_" + UUID().uuidString + "." + ext)
        // ★ v39：优先**硬链接** —— 同一沙盒卷内只是加一个目录项，几 GB 的视频也是瞬间完成、
        //   不占额外空间（旧写法整份 copy，2GB 视频要复制一遍、慢且吃磁盘）。
        //   硬链接失败（跨卷等）再退回真实拷贝。
        if (try? FileManager.default.linkItem(at: file, to: dst)) != nil { return dst }
        do {
            try FileManager.default.copyItem(at: file, to: dst)
            return dst
        } catch {
            return nil
        }
    }

    /// 读文件头魔数判断**真实容器**（不信扩展名）。
    /// 发送端可能把 HEIC 装成 .jpeg、把 MOV 装成 .mp4 发过来，按扩展名给 UTI 会被 PhotoKit 拒收。
    static func sniffExt(_ url: URL) -> String? {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? fh.close() }
        let head = fh.readData(ofLength: 16)
        guard head.count >= 12 else { return nil }
        let b = [UInt8](head)

        // JPEG: FF D8 FF
        if b[0] == 0xFF, b[1] == 0xD8, b[2] == 0xFF { return "jpg" }
        // PNG: 89 50 4E 47
        if b[0] == 0x89, b[1] == 0x50, b[2] == 0x4E, b[3] == 0x47 { return "png" }
        // GIF: "GIF8"
        if b[0] == 0x47, b[1] == 0x49, b[2] == 0x46, b[3] == 0x38 { return "gif" }
        // WebP: "RIFF" .... "WEBP"
        if b[0] == 0x52, b[1] == 0x49, b[2] == 0x46, b[3] == 0x46,
           b[8] == 0x57, b[9] == 0x45, b[10] == 0x42, b[11] == 0x50 { return "webp" }
        // ISO BMFF（heic / mov / mp4 共用）：offset 4 起是 "ftyp"
        if b[4] == 0x66, b[5] == 0x74, b[6] == 0x79, b[7] == 0x70 {
            let brand = String(bytes: b[8..<12], encoding: .ascii)?.lowercased() ?? ""
            switch brand {
            case "heic", "heix", "hevc", "hevx", "mif1", "msf1", "heim": return "heic"
            case "avif", "avis": return "avif"
            case "qt  ": return "mov"
            case "isom", "iso2", "iso4", "iso5", "iso6", "mp41", "mp42", "avc1", "m4v ", "m4a ", "dash", "3gp4", "3gp5", "3g2a":
                return "mp4"
            default:
                // 未知 brand：按「带视频轨的 ISO BMFF」当 mp4 试，让 PhotoKit 自己判
                return "mp4"
            }
        }
        // 老式 QuickTime：offset 4 起是 moov / mdat / wide / free
        let qt = String(bytes: b[4..<8], encoding: .ascii)?.lowercased() ?? ""
        if ["moov", "mdat", "wide", "free", "skip", "pnot"].contains(qt) { return "mov" }
        return nil
    }
}
