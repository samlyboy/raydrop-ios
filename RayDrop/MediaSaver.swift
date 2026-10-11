import Foundation
import Photos
import UniformTypeIdentifiers

/// 把接收到的临时文件存进系统「照片」相册。
///
/// 两个关键点（都是之前"安卓显示发送成功、iPhone 相册里没有"的根因）：
/// 1. **临时文件必须带正确扩展名 + 用 addResource 显式指定 UTI/文件名**。
///    旧写法 `creationRequestForAssetFromImage(atFileURL:)` 靠扩展名推断类型，
///    而临时文件叫 `rd_<uuid>`（无扩展名）→ 系统判不出类型，performChanges 失败，
///    而失败又被忽略，接收端照样回"ACK 成功"，于是发送端显示成功、相册里啥也没有。
/// 2. **必须等保存结果再回 ACK**：成功回 `{"ack":i}`，失败回 `{"ack":i,"err":"..."}`，
///    让发送方能显示"对方保存失败"而不是假成功。
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

    /// completion(是否成功, 失败原因)
    static func save(tempFile src: URL, name: String, mime: String, completion: @escaping (Bool, String) -> Void) {
        let isVideo = mime.hasPrefix("video/")
        let ext = extFor(name: name, mime: mime)
        // 改成带扩展名的文件名：系统靠它/UTI 判断资源类型
        let dst = src.deletingLastPathComponent().appendingPathComponent("rd_save_\(UUID().uuidString).\(ext)")
        do {
            if FileManager.default.fileExists(atPath: dst.path) { try FileManager.default.removeItem(at: dst) }
            try FileManager.default.moveItem(at: src, to: dst)
        } catch {
            completion(false, "临时文件改名失败：\(error.localizedDescription)")
            return
        }

        let uti = UTType(mimeType: mime)?.identifier
            ?? (isVideo ? UTType.mpeg4Movie.identifier : UTType.jpeg.identifier)
        let opts = PHAssetResourceCreationOptions()
        opts.originalFilename = name
        opts.uniformTypeIdentifier = uti
        let resType: PHAssetResourceType = isVideo ? .video : .photo

        PHPhotoLibrary.shared().performChanges({
            let req = PHAssetCreationRequest.forAsset()
            req.addResource(with: resType, fileURL: dst, options: opts)
        }) { success, error in
            try? FileManager.default.removeItem(at: dst)
            if success { completion(true, "") }
            else { completion(false, error?.localizedDescription ?? "系统拒绝写入相册") }
        }
    }
}