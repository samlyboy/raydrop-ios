import Foundation
import Photos

/// 把临时文件存进系统「照片」相册（写入相册无需隐私权限）
enum RDMediaSaver {
    static func save(tempFile: URL, mime: String, completion: @escaping (Bool) -> Void) {
        let isVideo = mime.hasPrefix("video/")
        var localIdentifier: String? = nil
        PHPhotoLibrary.shared().performChanges({
            let req: PHAssetChangeRequest?
            if isVideo {
                req = PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: tempFile)
            } else {
                req = PHAssetChangeRequest.creationRequestForAssetFromImage(atFileURL: tempFile)
            }
            localIdentifier = req?.placeholderForCreatedAsset?.localIdentifier
        }) { success, _ in
            try? FileManager.default.removeItem(at: tempFile)
            completion(success)
        }
    }
}
