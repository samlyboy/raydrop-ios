import Foundation

/// ★ v47.20：从 IPA/ZIP 内容本身还原真实文件名。
///
/// 背景：分享 IPA 到 RayDrop，面板一直显示 `share_<UUID>.bin`。v47.19 诊断条显示
/// `v47.15 跳转=responder` —— 主 App 是新版、但 TrollStore 覆盖安装时**分享扩展没被替换**，
/// 仍是 v47.15 旧二进制，它的文件名修复从未真正运行。
///
/// 解法：不再指望扩展传名字。主 App 收到 inbox 文件后，若名字是 `share_UUID` 占位或
/// 后缀是 `.bin`，就按内容嗅探：IPA 是标准 zip（PK），中央目录有 `Payload/xxx.app/` 条目，
/// 直接取 app 名；若 Info.plist 恰好是未压缩存储，再解出 CFBundleShortVersionString 拼版本号。
/// 不依赖 Compression 框架，纯 Foundation 实现，编译零风险。
enum IPAInfo {
    /// 若能从内容还原出更好的文件名则返回，否则 nil（保持原样）
    static func betterName(for url: URL) -> String? {
        guard let data = try? Data(contentsOf: url), data.count > 64 else { return nil }
        let b = [UInt8](data)
        guard b.count >= 4, b[0] == 0x50, b[1] == 0x4B else { return nil }  // zip: PK

        // EOCD（zip 结束记录）在尾部，注释最长 64K
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

        var appBase: String? = nil
        var infoPlist: Data? = nil
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

            if name.hasPrefix("Payload/") && name.hasSuffix(".app/") {
                // 目录项：`Payload/xxx.app/` → xxx
                let n = String(name.dropFirst("Payload/".count).dropLast())  // xxx.app
                appBase = String(n.dropLast(4))                              // xxx
            } else if name.hasPrefix("Payload/") && name.hasSuffix(".app/Info.plist") {
                if appBase == nil {
                    let n = String(name.dropFirst("Payload/".count))         // xxx.app/Info.plist
                    appBase = String(n.split(separator: "/").first ?? "").replacingOccurrences(of: ".app", with: "")
                }
                // 只在未压缩（method=0）时直接读，压缩的 plist 需要 deflate，跳过
                if method == 0, localOff + 30 <= b.count,
                   b[localOff] == 0x50, b[localOff+1] == 0x4B,
                   b[localOff+2] == 0x03, b[localOff+3] == 0x04 {
                    let lName = Int(u16(b, localOff + 26))
                    let lExtra = Int(u16(b, localOff + 28))
                    let start = localOff + 30 + lName + lExtra
                    if start + compSize <= b.count {
                        infoPlist = Data(b[start..<(start + compSize)])
                    }
                }
            }
            cdOffset = nameStart + nameLen + extraLen + commentLen
        }

        guard var base = appBase, !base.isEmpty else { return nil }
        if let d = infoPlist,
           let plist = try? PropertyListSerialization.propertyList(from: d, options: [], format: nil) as? [String: Any] {
            let display = (plist["CFBundleDisplayName"] as? String)
                ?? (plist["CFBundleName"] as? String)
                ?? base
            let ver = plist["CFBundleShortVersionString"] as? String ?? ""
            base = display.isEmpty ? base : display
            if !ver.isEmpty { base = "\(base)-v\(ver)" }
        }
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
