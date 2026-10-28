import Foundation
import Photos
import UniformTypeIdentifiers

/// 把收到的图片/视频再存一份进系统「照片」相册。
///
/// 原则：**原文件直传直存，绝不转码、不改容器、不重编码**。
/// 「下载」里那份是原始字节，相册写的也是同一个文件（PhotoKit 内部只做拷贝入库）。
///
/// 历史坑与对策：
/// 1. 旧写法靠 `creationRequestForAssetFromImage(atFileURL:)` 推断类型，而临时文件名是
///    `rd_<uuid>`（无扩展名）→ 系统判不出类型，写入失败且错误被忽略 → 发送端说成功、相册没有。
///    对策：入库前保证文件**带正确扩展名**（必要时只改名字，不动内容），并显式给
///    `originalFilename`。
/// 2. v34 给视频加了 `AVURLAsset` 轨道预检，读不出视频轨就直接放弃入库。
///    这在个别容器/未收尾的 mp4 上会误杀 —— 视频明明完好、能播，却永远进不了相册。
///    对策（v35）：**去掉任何预检，直接交给 PhotoKit**，由写入后的校验结果说话。
/// 3. 单一写法失败就彻底放弃。不同来源的视频（iPhone .MOV/HEVC、安卓 .mp4/H.264、
///    第三方 App 导出的 .m4v…）对 `addResource` 的参数敏感度不一样。
///    对策（v35）：**多策略依次兜底**，任一成功即停；全失败才回报，且把每一步的真实
///    NSError（domain#code）拼起来，便于对账定位。
/// 4. 写入后**回查**一次：拿 placeholder 的 localIdentifier 查 PHAsset，确认 mediaType
///    真的是视频。避免"写进去了但被当成图片"这种更隐蔽的假成功。
enum RDMediaSaver {

    typealias Done = (Bool, String) -> Void
    private typealias Attempt = (@escaping Done) -> Void

    /// 定扩展名：原名有就用原名，没有按 mime / 类型兜一个
    static func extFor(name: String, mime: String) -> String {
        let existing = (name as NSString).pathExtension.lowercased()
        if !existing.isEmpty { return existing }
        let m = mime.lowercased()
        if m.hasPrefix("video/") || m.hasPrefix("image/") { return RD.ext(forMime: mime) }
        return RD.isVideoFile(name: name, mime: mime) ? "mov" : "jpg"
    }

    /// 把「下载」里**已落盘**的文件额外存一份进相册（不移动、不删除、不改内容）。
    static func saveExisting(file: URL, name: String, mime: String, completion: @escaping Done) {
        let isVideo = RD.isVideoFile(name: name, mime: mime)
        let isImage = RD.isImageFile(name: name, mime: mime)
        guard isVideo || isImage else {
            // 非媒体文件（.pdf/.zip/.txt…）本来就不该进相册
            completion(true, "")
            return
        }

        switch PHPhotoLibrary.authorizationStatus(for: .addOnly) {
        case .authorized, .limited:
            run(file: file, name: name, mime: mime, isVideo: isVideo, completion: completion)
        case .notDetermined:
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { st in
                if st == .authorized || st == .limited {
                    run(file: file, name: name, mime: mime, isVideo: isVideo, completion: completion)
                } else {
                    completion(false, "未获得相册写入权限")
                }
            }
        default:
            completion(false, "相册权限被拒绝（设置 → RayDrop锐传 → 照片 → 添加照片）")
        }
    }

    // MARK: - 编排

    private static func run(file: URL, name: String, mime: String, isVideo: Bool, completion: @escaping Done) {
        let ext = extFor(name: name, mime: mime)
        // 保证交给 PhotoKit 的 URL 后缀与真实容器一致（只改名，不动字节）
        let src = urlWithExtension(file, ext: ext)
        let uti = UTType(filenameExtension: ext)?.identifier
            ?? UTType(mimeType: mime)?.identifier
            ?? (isVideo ? UTType.quickTimeMovie.identifier : UTType.jpeg.identifier)

        var attempts: [Attempt] = []

        if isVideo {
            // ① 苹果的「把一个视频文件加进相册」标准入口：内部自己识别容器，最省事
            attempts.append { done in
                commit(isVideo: true) { pid in
                    if let req = PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: src) {
                        pid = req.placeholderForCreatedAsset?.localIdentifier
                    }
                } done: { done($0, $1) }
            }
            // ② addResource(.video) + 原文件名 + 按容器给的 UTI
            attempts.append { done in
                let o = PHAssetResourceCreationOptions()
                o.originalFilename = name
                o.uniformTypeIdentifier = uti
                commit(isVideo: true) { pid in
                    let req = PHAssetCreationRequest.forAsset()
                    req.addResource(with: .video, fileURL: src, options: o)
                    pid = req.placeholderForCreatedAsset?.localIdentifier
                } done: { done($0, $1) }
            }
            // ③ 不给 UTI，让 PhotoKit 自己按文件内容判（某些 mp4/m4v 给了 UTI 反而不收）
            attempts.append { done in
                let o = PHAssetResourceCreationOptions()
                o.originalFilename = name
                commit(isVideo: true) { pid in
                    let req = PHAssetCreationRequest.forAsset()
                    req.addResource(with: .video, fileURL: src, options: o)
                    pid = req.placeholderForCreatedAsset?.localIdentifier
                } done: { done($0, $1) }
            }
            // ④ 换成临时目录里的干净文件名再试一次（排除文件名/路径引起的拒收）
            attempts.append { done in
                guard let clean = copyToTemp(src, ext: ext) else {
                    done(false, "无法创建临时副本"); return
                }
                let o = PHAssetResourceCreationOptions()
                o.originalFilename = "raydrop." + ext
                commit(isVideo: true) { pid in
                    let req = PHAssetCreationRequest.forAsset()
                    req.addResource(with: .video, fileURL: clean, options: o)
                    pid = req.placeholderForCreatedAsset?.localIdentifier
                } done: { ok, detail in
                    // ⚠️ 必须等 PhotoKit 真正做完再删副本：performChanges 是异步的，
                    //    用 defer 会在它读文件之前就把副本删掉。
                    try? FileManager.default.removeItem(at: clean)
                    done(ok, detail)
                }
            }
        } else {
            // 图片沿用一直有效的那条路，再加两条兜底
            attempts.append { done in
                let o = PHAssetResourceCreationOptions()
                o.originalFilename = name
                o.uniformTypeIdentifier = uti
                commit(isVideo: false) { pid in
                    let req = PHAssetCreationRequest.forAsset()
                    req.addResource(with: .photo, fileURL: src, options: o)
                    pid = req.placeholderForCreatedAsset?.localIdentifier
                } done: { done($0, $1) }
            }
            attempts.append { done in
                commit(isVideo: false) { pid in
                    if let req = PHAssetChangeRequest.creationRequestForAssetFromImage(atFileURL: src) {
                        pid = req.placeholderForCreatedAsset?.localIdentifier
                    }
                } done: { done($0, $1) }
            }
            attempts.append { done in
                let o = PHAssetResourceCreationOptions()
                o.originalFilename = name
                commit(isVideo: false) { pid in
                    let req = PHAssetCreationRequest.forAsset()
                    req.addResource(with: .photo, fileURL: src, options: o)
                    pid = req.placeholderForCreatedAsset?.localIdentifier
                } done: { done($0, $1) }
            }
        }

        next(attempts, 0, [], completion)
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

    /// 执行一次 performChanges + 写后校验
    private static func commit(isVideo: Bool,
                               _ build: @escaping (inout String?) -> Void,
                               done: @escaping Done) {
        var pid: String?
        PHPhotoLibrary.shared().performChanges({
            build(&pid)
        }) { ok, err in
            guard ok else {
                let ns = err as NSError?
                let detail = ns.map { "\($0.domain)#\($0.code) \($0.localizedDescription)" } ?? "系统未说明原因"
                done(false, detail)
                return
            }
            // 写后回查：确认类型对得上，避免"写进去了但被当成图片/其他"
            guard let id = pid,
                  let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject else {
                done(true, "")   // 拿不到 id 就无法回查，按成功处理（文件确实在相册里）
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
        do {
            try FileManager.default.copyItem(at: file, to: dst)
            return dst
        } catch {
            return nil
        }
    }
}
