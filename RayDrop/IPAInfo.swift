import Foundation
import Compression

/// ★ v47.20：从 IPA/ZIP 内容本身还原真实文件名。
///
/// 背景：分享 IPA 到 RayDrop，面板一直显示 `share_<UUID>.bin`。诊断条（v47.19）显示
/// `v47.15 跳转=responder` —— 主 App 是新版、但 TrollStore 覆盖安装时**分享扩展没被替换**，
/// 仍是 v47.15 旧二进制，它的文件名修复从未真正运行。
///
/// 解法：不再指望扩展传名字。主 App 收到 inbox 文件后，若名字是 `share_UUID` 占位或
/// 后缀是 `.bin`，就按内容嗅探：IPA 是标准 zip（PK），中央目录里有 `Payload/xxx.app/Info.plist`，
/// 解出 plist 读 CFBundleDisplayName/CFBundleShortVersionString → 拼成 `xxx-v版本.ipa`。
enum IPAInfo {
    /// 若能从内容还原出更好的文件名则返回，否则 nil（保持原样）
    static func betterName(for url: URL) -> String? {
        guard let data = try? Data(contentsOf: url), data.count > 64 else { return nil }
        let b = [UInt8](data)
        // 必须是 zip 容器（PK\x03\x04 或空 zip 的 PK\x05\x06）
        guard b.count >= 4, b[0] == 0x50, b[1] == 0x4B else { return nil }

        // 找中央目录里的 Info.plist / .app 目录项（zip 的 EOCD 在尾部，最多 64K+22 注释）
        let searchFrom = max(0, b.count - 65_557)
        var eocd = -1
        var p = b.count - 22
        while p >= searchFrom {
            if p + 4 <= b.count, b[p] == 0x50, b[p+1] == 0x4B, b[p+2] == 0x05, b[p+3] == 0x06 {
                eocd = p; break
            }
            p -= 1
        }
        guard eocd >= 0 else { return nil }
        let entryCount = Int(u16(b, eocd + 10))
        var cdOffset = Int(u32(b, eocd + 16))
        guard entryCount > 0, cdOffset >= 0, cdOffset < b.count else { return nil }

        var appDir: String? = nil
        var infoEntry: (offset: Int, compSize: Int, method: Int)? = nil
        for _ in 0..<entryCount {
            guard cdOffset + 46 <= b.count,
                  b[cdOffset] == 0x50, b[cdOffset+1] == 0x4B,
                  b[cdOffset+2] == 0x01, b[cdOffset+3] == 0x02 else { break }
            let method = Int(u16(b, cdOffset + 10))
            let compSize = Int(u32(b, cdOffset + 20))
            let nameLen = Int(u16(b, cdOffset + 28))
            let extraLen = Int(u16(b, cdOffset + 30))
            let commentLen = Int(u16(b, cdOffset + 32))
            let localOff = Int(u32(b, cdOffset + 42))
            let nameStart = cdOffset + 46
            guard nameStart + nameLen <= b.count else { break }
            let name = String(bytes: b[nameStart..<(nameStart + nameLen)], encoding: .utf8)
                ?? String(bytes: b[nameStart..<(nameStart + nameLen)], encoding: .ascii)
                ?? ""
            if name.hasPrefix("Payload/") && name.hasSuffix(".app/"), appDir == nil {
                appDir = String(name.dropFirst("Payload/".count).dropLast())
            }
            if name.hasPrefix("Payload/") && name.hasSuffix(".app/Info.plist") {
                infoEntry = (localOff, compSize, method)
            }
            cdOffset = nameStart + nameLen + extraLen + commentLen
        }

        // 没有 .app/Info.plist：只是普通 zip，不冒充 IPA
        guard let info = infoEntry else { return nil }
        let appBase = appDir ?? "App"

        // 读本地文件头，跳过文件名/额外字段，取压缩数据
        guard info.offset + 30 <= b.count,
              b[info.offset] == 0x50, b[info.offset+1] == 0x4B,
              b[info.offset+2] == 0x03, b[info.offset+3] == 0x04 else { return nil }
        let lNameLen = Int(u16(b, info.offset + 26))
        let lExtraLen = Int(u16(b, info.offset + 28))
        let dataStart = info.offset + 30 + lNameLen + lExtraLen
        guard dataStart + info.compSize <= b.count else { return nil }

        let compressed = Array(b[dataStart..<(dataStart + info.compSize)])
        let raw: Data
        if info.method == 0 {
            raw = Data(compressed)
        } else if info.method == 8 {
            // deflate：预分配 64KB 足够读 Info.plist（通常 < 10KB）
            let cap = 65_536
            var out = [UInt8](repeating: 0, count: cap)
            let got = compressed.withUnsafeBytes { src in
                out.withUnsafeMutableBytes { dst in
                    compression_decode_buffer(dst.baseAddress!, dst.count,
                                              src.baseAddress!, src.count,
                                              nil, COMPRESSION_DEFLATE)
                }
            }
            guard got > 0 else { return nil }
            raw = Data(out[0..<got])
        } else {
            return nil
        }

        guard let plist = try? PropertyListSerialization.propertyList(from: raw, options: [], format: nil) as? [String: Any] else {
            return nil
        }
        let display = (plist["CFBundleDisplayName"] as? String)
            ?? (plist["CFBundleName"] as? String)
            ?? appBase
        let ver = plist["CFBundleShortVersionString"] as? String ?? ""
        let safeName = display.isEmpty ? appBase : display
        let base = ver.isEmpty ? safeName : "\(safeName)-v\(ver)"
        return sanitize(base) + ".ipa"
    }

    private static func sanitize(_ s: String) -> String {
        var out = ""
        for ch in s.unicodeScalars {
            if ch.value == 47 || ch.value == 92 || ch.value == 58 || ch.value < 32 { continue }
            out.unicodeScalars.append(ch)
        }
        return out.isEmpty ? "App" : out
    }
    private static func u16(_ b: [UInt8], _ i: Int) -> UInt16 {
        UInt16(b[i]) | (UInt16(b[i+1]) << 8)
    }
    private static func u32(_ b: [UInt8], _ i: Int) -> UInt32 {
        UInt32(b[i]) | (UInt32(b[i+1]) << 8) | (UInt32(b[i+2]) << 16) | (UInt32(b[i+3]) << 24)
    }
}
