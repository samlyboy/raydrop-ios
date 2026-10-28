import SwiftUI
import Photos
import UIKit

// MARK: - 自建相册选择器（v44）
//
// 为什么不用 PHPicker：
//   1) 系统控件的网格固定「最新在左上」，没有任何排序 API；
//   2) 它是 sheet，下拉就关，手势禁不掉；
//   3) 选中的角标样式不可改。
// 微信能做到这些，是因为它自己读 PhotoKit 画网格 —— 这里走同一条路。
//
// 排序：按 creationDate **升序**（最老在上、最新在下），打开时自动滚到底部，
//       所以进来第一眼就是最新的那张，往上拉看更早的。
// 编号：点选顺序 = 发送顺序，角标显示 1、2、3…（不依赖系统 PHPicker 的 .ordered）。

struct AssetPickerView: View {
    /// 用户点了取消 / 没有选中
    let onCancel: () -> Void
    /// 没有相册权限时，退回到系统 PHPicker（零权限也能选）
    let onFallback: () -> Void
    /// 按**点选顺序**回传（数组第 0 个就是编号 1）
    let onDone: ([PHAsset]) -> Void

    @State private var auth: PHAuthorizationStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    @State private var assets: [PHAsset] = []
    @State private var picked: [String] = []          // localIdentifier，按点选先后
    @State private var loading = true

    private let cols = Array(repeating: GridItem(.flexible(), spacing: 2), count: 3)
    private let bg = Color(red: 0.06, green: 0.06, blue: 0.07)
    private let blue = Color(red: 0.04, green: 0.52, blue: 1)

    var body: some View {
        ZStack {
            bg.ignoresSafeArea()
            VStack(spacing: 0) {
                topBar
                Rectangle().fill(Color.white.opacity(0.08)).frame(height: 0.5)
                bodyContent
                bottomBar
            }
        }
        .preferredColorScheme(.dark)
        .onAppear(perform: start)
    }

    // MARK: 顶部

    private var topBar: some View {
        HStack {
            Button(action: onCancel) {
                Text("取消").font(.system(size: 16)).foregroundColor(.white.opacity(0.85))
            }
            Spacer()
            Text("照片与视频").font(.system(size: 16, weight: .semibold)).foregroundColor(.white)
            Spacer()
            Button(action: finish) {
                Text(picked.isEmpty ? "完成" : "完成 \(picked.count)")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(picked.isEmpty ? .white.opacity(0.28) : blue)
            }
            .disabled(picked.isEmpty)
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 12)
    }

    private var bottomBar: some View {
        Text(picked.isEmpty
             ? "点选照片或视频，编号就是发送顺序"
             : "已选 \(picked.count) 项，将按 1 → \(picked.count) 的顺序发送")
        .font(.system(size: 12))
        .foregroundColor(.white.opacity(0.5))
        .frame(maxWidth: .infinity)
        .padding(.top, 8)
        .padding(.bottom, 26)
        .background(bg)
    }

    // MARK: 主体

    @ViewBuilder
    private var bodyContent: some View {
        if auth == .denied || auth == .restricted {
            deniedView
        } else if loading {
            VStack(spacing: 12) {
                ProgressView().progressViewStyle(.circular).tint(.white)
                Text("正在读取相册…").font(.footnote).foregroundColor(.white.opacity(0.5))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if assets.isEmpty {
            Text("相册里没有可发送的照片或视频")
                .font(.footnote).foregroundColor(.white.opacity(0.5))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            grid
        }
    }

    private var grid: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVGrid(columns: cols, spacing: 2) {
                    ForEach(assets, id: \.localIdentifier) { a in
                        AssetCell(asset: a, order: orderOf(a), blue: blue)
                            .id(a.localIdentifier)
                            .onTapGesture { toggle(a) }
                    }
                }
                .padding(.bottom, 6)
            }
            .onChange(of: assets.count) { _ in
                scrollToNewest(proxy, delay: 0.05)
            }
            .onChange(of: loading) { done in
                // 连续滚三次：LazyVGrid 对末尾元素的定位在首次布局时可能偏，
                // 多滚几次逐步收敛，保证打开就停在最新那张。
                if !done {
                    scrollToNewest(proxy, delay: 0.1)
                    scrollToNewest(proxy, delay: 0.5)
                    scrollToNewest(proxy, delay: 1.2)
                }
            }
        }
    }

    /// 升序排列 → 最新在数组末尾 → 滚到最后一个 cell（右下角）
    private func scrollToNewest(_ proxy: ScrollViewProxy, delay: Double) {
        guard let last = assets.last else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            proxy.scrollTo(last.localIdentifier, anchor: .bottom)
        }
    }

    private var deniedView: some View {
        VStack(spacing: 14) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 42)).foregroundColor(.white.opacity(0.35))
            Text("需要访问相册").font(.system(size: 17, weight: .semibold)).foregroundColor(.white)
            Text("RayDrop 要读取相册，才能显示你的照片和视频。\n也可以用系统选择器，那个不需要授权。")
                .font(.system(size: 13))
                .multilineTextAlignment(.center)
                .foregroundColor(.white.opacity(0.55))
                .padding(.horizontal, 24)
            HStack(spacing: 10) {
                Button {
                    if let u = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(u)
                    }
                } label: {
                    Text("去设置授权")
                        .font(.system(size: 15, weight: .medium))
                        .padding(.horizontal, 18).padding(.vertical, 10)
                        .background(blue).foregroundColor(.white).cornerRadius(10)
                }
                Button(action: onFallback) {
                    Text("用系统选择器")
                        .font(.system(size: 15, weight: .medium))
                        .padding(.horizontal, 18).padding(.vertical, 10)
                        .background(Color.white.opacity(0.12)).foregroundColor(.white).cornerRadius(10)
                }
            }
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: 数据

    private func start() {
        auth = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        switch auth {
        case .authorized, .limited:
            loadAssets()
        case .notDetermined:
            PHPhotoLibrary.requestAuthorization(for: .readWrite) { s in
                DispatchQueue.main.async {
                    auth = s
                    if s == .authorized || s == .limited { loadAssets() } else { loading = false }
                }
            }
        default:
            loading = false
        }
    }

    private func loadAssets() {
        loading = true
        // 取相册在后台线程，几千张也不会卡住首帧
        DispatchQueue.global(qos: .userInitiated).async {
            let opt = PHFetchOptions()
            // ★ 升序：最老在最前、最新在最后 → 打开滚到底部即「最新在右下」
            opt.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
            opt.predicate = NSPredicate(format: "mediaType == %d OR mediaType == %d",
                                        PHAssetMediaType.image.rawValue,
                                        PHAssetMediaType.video.rawValue)
            let r = PHAsset.fetchAssets(with: opt)
            var list: [PHAsset] = []
            list.reserveCapacity(r.count)
            r.enumerateObjects { a, _, _ in list.append(a) }
            DispatchQueue.main.async {
                assets = list
                loading = false
            }
        }
    }

    private func toggle(_ a: PHAsset) {
        let id = a.localIdentifier
        if let i = picked.firstIndex(of: id) {
            picked.remove(at: i)
        } else {
            picked.append(id)
        }
    }

    /// 已选的序号（从 1 开始）；未选返回 nil
    private func orderOf(_ a: PHAsset) -> Int? {
        guard let i = picked.firstIndex(of: a.localIdentifier) else { return nil }
        return i + 1
    }

    private func finish() {
        guard !picked.isEmpty else { onCancel(); return }
        var byID: [String: PHAsset] = [:]
        for a in assets { byID[a.localIdentifier] = a }
        // ★ 严格按点选顺序回传，绝不按相册顺序
        let ordered = picked.compactMap { byID[$0] }
        guard !ordered.isEmpty else { onCancel(); return }
        onDone(ordered)
    }
}

// MARK: - 单个格子

private struct AssetCell: View {
    let asset: PHAsset
    let order: Int?
    let blue: Color

    @State private var img: UIImage?

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color(white: 0.16)
                .aspectRatio(1, contentMode: .fill)
                .overlay(
                    Group {
                        if let img = img {
                            Image(uiImage: img).resizable().scaledToFill()
                        }
                    }
                )
                .clipped()

            // 视频时长（右下）
            if asset.mediaType == .video {
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        Text(durationText)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(.white)
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            .background(Color.black.opacity(0.55))
                            .cornerRadius(4)
                            .padding(4)
                    }
                }
            }

            // 编号 / 空心圈（右上）
            ZStack {
                Circle()
                    .fill(order == nil ? Color.black.opacity(0.22) : blue)
                    .frame(width: 23, height: 23)
                Circle()
                    .stroke(Color.white, lineWidth: order == nil ? 1.5 : 0)
                    .frame(width: 23, height: 23)
                if let order = order {
                    Text("\(order)")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(.white)
                }
            }
            .padding(6)
        }
        .contentShape(Rectangle())
        .onAppear(perform: loadThumb)
    }

    private var durationText: String {
        let t = Int(asset.duration.rounded())
        if t >= 3600 {
            return String(format: "%d:%02d:%02d", t / 3600, (t % 3600) / 60, t % 60)
        }
        return String(format: "%d:%02d", t / 60, t % 60)
    }

    private func loadThumb() {
        if let hit = ThumbCache.shared.cached(asset.localIdentifier) {
            img = hit
            return
        }
        ThumbCache.shared.load(asset) { u in
            if let u = u { img = u }
        }
    }
}

// MARK: - 缩略图缓存

/// 相册缩略图缓存：按 localIdentifier 存内存，滚动来回不重复解码。
final class ThumbCache {
    static let shared = ThumbCache()
    private let cache = NSCache<NSString, UIImage>()
    private let mgr = PHImageManager.default()

    func cached(_ id: String) -> UIImage? { cache.object(forKey: id as NSString) }

    func load(_ asset: PHAsset, done: @escaping (UIImage?) -> Void) {
        let key = asset.localIdentifier as NSString
        if let hit = cache.object(forKey: key) { done(hit); return }

        let opt = PHImageRequestOptions()
        opt.deliveryMode = .opportunistic      // 先给低清再给高清，滚动时不空白
        opt.resizeMode = .fast
        opt.isNetworkAccessAllowed = true      // iCloud 未下载的缩略图也能拉
        opt.isSynchronous = false

        mgr.requestImage(for: asset,
                         targetSize: CGSize(width: 320, height: 320),
                         contentMode: .aspectFill,
                         options: opt) { image, info in
            if let image = image {
                self.cache.setObject(image, forKey: key)
                DispatchQueue.main.async { done(image) }
                return
            }
            // 只有「真正失败」才回报 nil；取消/降级不算
            let cancelled = (info?[PHImageCancelledKey] as? Bool) ?? false
            if !cancelled, info?[PHImageErrorKey] != nil {
                DispatchQueue.main.async { done(nil) }
            }
        }
    }
}
