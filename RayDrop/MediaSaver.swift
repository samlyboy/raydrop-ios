import Foundation
import Photos
import UniformTypeIdentifiers

/// 把收到的图片/视频再存一份进系统「照片」相册。
///
/// 关键点（都是之前"安卓显示发送成功、iPhone 相册里没有"的根因）：
/// 1. **必须带正确扩展名 + 用 addResource 显式指定 UTI/文件名**。
///    旧写法 `creationRequestForAssetFromImage(atFileURL:)` 靠扩展名推断类型，
///    而临时文件叫 `rd_<uuid>`（无扩展名）→ 系统判不出类型，performChanges 失败，
///    而失败又被忽略 → 发送端显示成功、相册里啥也没有。
/// 2. **非破坏性**：现在文件已先落在「下载」文件夹里，写真机时**不移动、不删除**那份，
///    相册只是多一份副本；相册写失败也不影响「下载」里的文件，故不致命、不中断传输。
enum RDMediaSaver {
    static func extFor(name: String, mime: String) -> String {
        let n = (name as NSString).pathExtension
        if !n.isEmpty { return n }
        switch mime {
        case "image/png": return "png"
        case "image/heic": return "heic"
        case "image/webp": return "webp"
        case "image/gif": return "gif"
        case "video/mp4": return "mp4"
        case "video/quicktime": return "mov"
        case "video/x-matertroska": return "mkv"
        default: return "jpg"
        }
    }

    /// 把「下载」里**已落盘**的文件额外存一份进相册（不移动、不删除原文件）。
    /// completion(是否成功, 失败原因)
    static func saveExisting(file: URL, name: String, mime: String, completion: @escaping (Bool, String) -> Void) {
        let isVideo = mime.hasPrefix("video/")
        let ext = extFor(name: name, mime: mime)
        // 显式给出 UTI / 原始文件名：无扩展名或怪扩展名时系统也能正确判类型
        let uti = UTType(mimeType: mime)?.identifier
            ?? (isVideo ? UTType.mpeg4Movie.identifier : UTType.jpeg.identifier)
        let opts = PHAssetResourceCreationOptions()
        opts.originalFilename = (name as NSString).pathExtension.isEmpty ? "\(name).\(ext)" : name
        opts.uniformTypeIdentifier = uti
        let resType: PHAssetResourceType = isVideo ? .video : .photo

        PHPhotoLibrary.shared().performChanges({
            let req = PHAssetCreationRequest.forAsset()
            req.addResource(with: resType, fileURL: file, options: opts)
        }) { success, error in
            if success { completion(true, "") }
            else { completion(false, error?.localizedDescription ?? "系统拒绝写入相册") }
        }
    }
}