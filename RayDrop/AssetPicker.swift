import SwiftUI
import Photos
import UIKit

// MARK: - 自建相册选择器（v45）
//
// v44 遗留的三个问题，这一版全部处理：
//
// 【1】打开停在最老的一张
//   SwiftUI 的 scrollTo 对 LazyVGrid 里「还没实例化的最后一个 cell」定位不可靠：
//   内容总高度只是估算值，滚过去会落回顶部（v44 重试三次也没救回来）。
//   这一版直接沿视图层级摸到宿主 UIScrollView，用 scrollRectToVisible 把内容最后
//   一像素滚进视野 —— UIScrollView 自己会做边界钳制，不用我们算 contentSize/inset。
//
// 【2】每行 3 张 → 5 张
//
// 【3】新增「长按起手 + 滑动连选」
//   同一块区域上的「滑」既要滚动又要连选，系统只能二选一（苹果自己的相册也是
//   「长按 0.28s 进入连选」）。所以：直接滑 = 正常滚动，行为不变；停住 0.28s 后滑 =
//   连选，连选期间把 UIScrollView 的 isScrollEnabled 关掉，免得手指一动页面跟着跑。
//
// 编号规则（位置决定编号，跟手指从哪一头开始无关）：
//   以 3 列为例，从下往上、每行从右往左：
//       下右=1  下中=2  下左=3
//       中右=4  中中=5  中左=6
//       上右=7  上中=8  上左=9
//   实现：选中区域按「行从下往上、行内从右往左」遍历取号。
//   点选（tap）仍然是「点的先后 = 编号」，两种方式的结果可以混着用。
//
// 排序：PHFetchOptions 按 creationDate **升序**（最老在前、最新在最后），
//       所以最新的那张在内容末尾 → 滚到底 = 右下角。

struct AssetPickerView: View {
    let onCancel: () -> Void
    /// 没有相册权限时，退回到系统 PHPicker（零权限也能选）
    let onFallback: () -> Void
    /// 按**选中的先后/位置**回传（数组第 0 个就是编号 1）
    let onDone: ([PHAsset]) -> Void

    @StateObject private var host = ScrollHost()

    @State private var auth: PHAuthorizationStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    @State private var assets: [PHAsset] = []
    @State private var idIndex: [String: Int] = [:]
    @State private var picked: [String] = []          // localIdentifier，按编号先后
    // 每个可见格子在滚动视图里的位置（连选命中用）。
    // 存成类引用而不是 @State 字典：滚动时每帧都会变，走 @State 会每帧重绘整屏。
    @State private var frameStore = FrameStore()
    @State private var loading = true

    // 连选会话状态
    @State private var dragBase: [String]? = nil      // 起手前已经选好的（本轮不参与重排）
    @State private var dragAnchor: Int? = nil         // 起手那一格在 assets 里的下标
    @State private var touch = TouchPoint()           // 按下位置（类引用，写它不触发重绘）

    private let colCount = 5
    private let gap: CGFloat = 2
    private let gridSpace = "rdGrid"
    private let bg = Color(red: 0.06, green: 0.06, blue: 0.07)
    private let blue = Color(red: 0.04, green: 0.52, blue: 1)

    private var cols: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: gap), count: colCount)
    }

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
        .onDisappear { host.lock(false) }
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
             ? "长按任意一张再滑动，可以整片连选 · 编号就是发送顺序"
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
        ScrollView {
            LazyVGrid(columns: cols, spacing: gap) {
                ForEach(assets, id: \.localIdentifier) { a in
                    AssetCell(asset: a, order: orderOf(a), blue: blue)
                        .id(a.localIdentifier)
                        .background(
                            GeometryReader { g in
                                Color.clear.preference(
                                    key: CellFrameKey.self,
                                    value: [a.localIdentifier: g.frame(in: .named(gridSpace))]
                                )
                            }
                        )
                        .onTapGesture { toggle(a) }
                }
            }
            .padding(.bottom, 2)
            .simultaneousGesture(selectGesture)

            // 内容最末尾的锚点：它一出现，宿主 UIScrollView 就把底部滚进来
            ScrollBottomAnchor(host: host)
                .frame(width: 1, height: 1)
        }
        .coordinateSpace(name: gridSpace)
        .onPreferenceChange(CellFrameKey.self) { frameStore.d = $0 }
        .simultaneousGesture(touchTracker)
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

    // MARK: 手势

    /// 只记录「手指按在哪」，不参与识别；写类属性，避免每一帧都触发 SwiftUI 重绘
    private var touchTracker: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(gridSpace))
            .onChanged { v in
                touch.p = v.startLocation
                host.touched = true
            }
    }

    /// 长按 0.28s 起手 → 后续滑动连选。
    /// 用 simultaneousGesture 挂载（不是 highPriority）：直接滑不会被长按拖住，
    /// 滚动跟原来一样跟手；只有停住 0.28s 了才进入连选，并且此时才关掉滚动。
    private var selectGesture: some Gesture {
        LongPressGesture(minimumDuration: 0.28, maximumDistance: 30)
            .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .named(gridSpace)))
            .onChanged { value in
                switch value {
                case .first(let ok):
                    guard ok else { return }
                    if dragBase == nil, let p = touch.p, let hit = hitIndex(at: p) {
                        beginDrag(at: hit)
                    }
                case .second(let ok, let drag):
                    guard ok else { return }
                    if dragBase == nil {
                        if let p = drag?.location ?? touch.p, let hit = hitIndex(at: p) {
                            beginDrag(at: hit)
                        }
                    }
                    if let d = drag, dragAnchor != nil, let hit = hitIndex(at: d.location) {
                        applyRange(to: hit)
                    }
                }
            }
            .onEnded { _ in endDrag() }
    }

    // MARK: 连选

    private func beginDrag(at hit: Int) {
        guard dragBase == nil, hit >= 0, hit < assets.count else { return }
        dragBase = picked
        dragAnchor = hit
        host.lock(true)                      // 连选期间关掉滚动，否则页面跟着手指跑
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        applyRange(to: hit)                  // 长按不动 = 等同于点选这一张
    }

    /// 把「起手格 → 当前格」围出的矩形重新取号：行由下往上、行内由右往左
    private func applyRange(to hit: Int) {
        guard let anchor = dragAnchor, let base = dragBase else { return }
        host.lock(true)                      // 每次拖动都重申一次锁，防止被框架重设
        var next = base
        for i in rangeIndices(from: anchor, to: hit) {
            guard i >= 0, i < assets.count else { continue }
            let id = assets[i].localIdentifier
            if !next.contains(id) { next.append(id) }
        }
        if next != picked { picked = next }
    }

    private func endDrag() {
        dragBase = nil
        dragAnchor = nil
        host.lock(false)                     // 无论如何都要解锁，否则页面再也滚不动
    }

    /// 两格之间围出的矩形，按「行从下往上、行内从右往左」给出下标序列。
    /// 例（3 列）：由右下划到左上 → 编号 1..9 依次是
    ///   下右1 下中2 下左3 / 中右4 中中5 中左6 / 上右7 上中8 上左9
    private func rangeIndices(from a: Int, to b: Int) -> [Int] {
        let per = colCount
        let ar = a / per, ac = a % per
        let br = b / per, bc = b % per
        var out: [Int] = []
        var r = max(ar, br)
        let rStop = min(ar, br)
        while r >= rStop {
            var c = max(ac, bc)
            let cStop = min(ac, bc)
            while c >= cStop {
                let i = r * per + c
                if i < assets.count { out.append(i) }
                c -= 1
            }
            r -= 1
        }
        return out
    }

    /// 手指位置 → 格子下标。先精确命中，再退「最近的格子中心」（允许划到格子缝隙里）
    private func hitIndex(at p: CGPoint) -> Int? {
        var best: (index: Int, dist: CGFloat)?
        for (id, f) in frameStore.d {
            if f.contains(p), let i = idIndex[id] { return i }
            guard let i = idIndex[id] else { continue }
            let dx = f.midX - p.x, dy = f.midY - p.y
            let d = (dx * dx + dy * dy).squareRoot()
            if best == nil || d < best!.dist { best = (i, d) }
        }
        if let b = best, b.dist <= 140 { return b.index }
        return nil
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
            // ★ 升序：最老在最前、最新在最后 → 滚到底部即「最新在右下」
            opt.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
            opt.predicate = NSPredicate(format: "mediaType == %d OR mediaType == %d",
                                        PHAssetMediaType.image.rawValue,
                                        PHAssetMediaType.video.rawValue)
            let r = PHAsset.fetchAssets(with: opt)
            var list: [PHAsset] = []
            list.reserveCapacity(r.count)
            r.enumerateObjects { a, _, _ in list.append(a) }
            var index: [String: Int] = [:]
            index.reserveCapacity(list.count)
            for (i, a) in list.enumerated() { index[a.localIdentifier] = i }
            DispatchQueue.main.async {
                assets = list
                idIndex = index
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
        // ★ 严格按编号顺序回传，绝不按相册顺序
        let ordered = picked.compactMap { byID[$0] }
        guard !ordered.isEmpty else { onCancel(); return }
        onDone(ordered)
    }
}

// MARK: - 宿主 UIScrollView 抓手
//
// 1) 打开就停在底部（最新那张）：scrollRectToVisible 到内容最后一像素，
//    边界由 UIScrollView 自己钳制，不用猜 contentSize。
// 2) 连选期间锁滚动：isScrollEnabled = false。
final class ScrollHost: ObservableObject {
    fileprivate weak var sv: UIScrollView?
    fileprivate var touched = false
    private let deadline = Date().addingTimeInterval(2.5)

    func attach(_ v: UIView) {
        if sv == nil { sv = Self.find(v) }
        guard let sv = sv else { return }
        guard Date() < deadline, !touched else { return }
        guard !sv.isTracking, !sv.isDragging, !sv.isDecelerating else { return }
        Self.scrollToBottom(sv)
    }

    func lock(_ on: Bool) {
        // 两道锁一起上：SwiftUI 偶尔会重设 isScrollEnabled，pan 手势的开关更稳。
        sv?.isScrollEnabled = !on
        sv?.panGestureRecognizer.isEnabled = !on
    }

    private static func find(_ v: UIView) -> UIScrollView? {
        var p: UIView? = v.superview
        while let cur = p {
            if let s = cur as? UIScrollView { return s }
            p = cur.superview
        }
        return nil
    }

    private static func scrollToBottom(_ sv: UIScrollView) {
        let h = sv.contentSize.height
        guard h > sv.bounds.height + 1 else { return }
        let w = max(1, sv.bounds.width)
        sv.scrollRectToVisible(CGRect(x: 0, y: h - 1, width: w, height: 1), animated: false)
    }
}

/// 放在滚动内容最末尾的 1pt 锚点。布局稳定前连续校正几次，
/// 因为 LazyVGrid 的内容高度要等几帧才收敛。
private struct ScrollBottomAnchor: UIViewRepresentable {
    let host: ScrollHost

    func makeUIView(context: Context) -> UIView {
        let v = UIView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
        v.isUserInteractionEnabled = false
        v.backgroundColor = .clear
        for d in [0.0, 0.05, 0.15, 0.35, 0.7, 1.2, 2.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + d) { [weak v] in
                guard let v = v else { return }
                host.attach(v)
            }
        }
        return v
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        host.attach(uiView)
    }
}

/// 手指按下位置。用类引用存，改它不会触发 SwiftUI 重绘（滚动时每帧都在变）。
final class TouchPoint {
    var p: CGPoint?
}

/// 可见格子位置表，同样用类引用存：滚动每一帧都会刷新，不能走 @State（会每帧重绘整屏）。
final class FrameStore {
    var d: [String: CGRect] = [:]
}

// MARK: - 格子位置收集（连选命中用）

private struct CellFrameKey: PreferenceKey {
    static var defaultValue: [String: CGRect] { [:] }
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { _, new in new }
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
                            .font(.system(size: 9, weight: .medium))
                            .foregroundColor(.white)
                            .padding(.horizontal, 4).padding(.vertical, 1)
                            .background(Color.black.opacity(0.55))
                            .cornerRadius(3)
                            .padding(3)
                    }
                }
            }

            // 编号 / 空心圈（右上）
            ZStack {
                Circle()
                    .fill(order == nil ? Color.black.opacity(0.22) : blue)
                    .frame(width: 21, height: 21)
                Circle()
                    .stroke(Color.white, lineWidth: order == nil ? 1.4 : 0)
                    .frame(width: 21, height: 21)
                if let order = order {
                    Text("\(order)")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(.white)
                        .minimumScaleFactor(0.6)
                        .lineLimit(1)
                }
            }
            .padding(4)
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
                         targetSize: CGSize(width: 300, height: 300),
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
