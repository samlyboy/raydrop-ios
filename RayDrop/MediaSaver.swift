import Foundation
import Photos
import UniformTypeIdentifiers
import AVFoundation

/// 把收到的图片/视频再存一份进系统「照片」相册。
///
/// 关键点（都是之前"安卓显示发送成功、iPhone 相册里没有"的根因）：
/// 1. **必须带正确扩展名 + 用 addResource 显式指定 UTI/文件名**。
///    旧写法 `creationRequestForAssetFromImage(atFileURL:)` 靠扩展名推断类型，
///    而临时文件叫 `rd_<uuid>`（无扩展名）→ 系统判不出类型，performChanges 失败，
///    而失败又被忽略 → 发送端显示成功、相册里啥也没有。
/// 2. **非破坏性**：现在文件已先落在「下载」文件夹里，写相册时**不移动、不删除**那份，
///    相册只是多一份副本；相册写失败也不影响「下载」里的文件，故不致命、不中断传输。
///
/// ★ v34 修「视频传到了但相册里没有」：
///   - 类型判定改用 `RD.isVideoFile`（mime + 扩展名双判），不再只看 mime 前缀。
///     之前对端把视频标成 `application/octet-stream` 时，这里走的是图片分支 → 按 .photo 写 → 必然失败。
///   - 视频先用 AVFoundation 读真实轨道，UTI 按**实际容器**给，而不是靠 mime 猜。
///   - 相册权限显式按 `.addOnly` 申请（iOS 14+），不再依赖隐式写入权限。
///   - 失败原因回传完整（NSError domain#code），不再只说"系统拒绝写入相册"。
enum RDMediaSaver {
    /// 定扩展名：mime 明确推得出就用 mime 推的，否则保留原名扩展名，都没有按类型给默认值
    static func extFor(name: String, mime: String) -> String {
        let existing = (name as NSString).pathExtension.lowercased()
        let m = mime.lowercased()
        if m.hasPrefix("video/") || m.hasPrefix("image/") {
            if !existing.isEmpty { return existing }
            return RD.ext(forMime: mime)
        }
        if !existing.isEmpty { return existing }
        return RD.isVideoFile(name: name, mime: mime) ? "mov" : "jpg"
    }

    /// 把「下载」里**已落盘**的文件额外存一份进相册（不移动、不删除原文件）。
    /// completion(是否成功, 失败原因)
    static func saveExisting(file: URL, name: String, mime: String, completion: @escaping (Bool, String) -> Void) {
        let isVideo = RD.isVideoFile(name: name, mime: mime)
        let isImage = RD.isImageFile(name: name, mime: mime)
        guard isVideo || isImage else {
            // 非媒体文件（.pdf/.zip/.txt…）本来就不该进相册，跳过是正确行为
            completion(true, "")
            return
        }

        var uti: String = UTType(mimeType: mime)?.identifier ?? ""
        var resType: PHAssetResourceType = isVideo ? .video : .photo

        if isVideo {
            let asset = AVURLAsset(url: file)
            let vTracks = asset.tracks(withMediaType: .video)
            guard !vTracks.isEmpty else {
                // 号称视频却读不出视频轨 → 别硬写（写进去也是坏资产），只留「下载」那份
                completion(false, "读不出视频轨（文件可能已损坏，请到「下载」里检查）")
                return
            }
            // UTI 以**文件容器类型**为准（比 mime 可靠：对端 mime 常是 octet-stream）
            if let byExt = UTType(filenameExtension: (name as NSString).pathExtension.lowercased()) {
                uti = byExt.identifier
            }
            // 容器类型认不出 / 不是电影类 → 按 QuickTime（PHPhotoLibrary 对 mov 容器接受度最高）
            if uti.isEmpty { uti = UTType.quickTimeMovie.identifier }
            resType = .video
        } else {
            if uti.isEmpty || uti == UTType.data.identifier { uti = UTType.jpeg.identifier }
            resType = .photo
        }

        let ext = extFor(name: name, mime: mime)
        let hasExt = !(name as NSString).pathExtension.isEmpty
        let opts = PHAssetResourceCreationOptions()
        opts.originalFilename = hasExt ? name : "\(name).\(ext)"
        opts.uniformTypeIdentifier = uti

        let write: (@escaping (Bool, String) -> Void) -> Void = { done in
            PHPhotoLibrary.shared().performChanges({
                let req = PHAssetCreationRequest.forAsset()
                req.addResource(with: resType, fileURL: file, options: opts)
            }) { success, error in
                if success { done(true, "") }
                else {
                    let ns = error as NSError?
                    let detail = ns.map { "\($0.domain)#\($0.code) \($0.localizedDescription)" }
                        ?? "系统拒绝写入相册"
                    done(false, detail)
                }
            }
        }

        switch PHPhotoLibrary.authorizationStatus(for: .addOnly) {
        case .authorized, .limited:
            write(completion)
        case .notDetermined:
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { st in
                if st == .authorized || st == .limited { write(completion) }
                else { completion(false, "未获得相册写入权限") }
            }
        default:
            completion(false, "相册权限被拒绝（设置 → RayDrop锐传 → 照片 → 添加照片）")
        }
    }
}