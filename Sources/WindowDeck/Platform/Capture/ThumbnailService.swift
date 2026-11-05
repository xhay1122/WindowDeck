import AppKit
import CoreGraphics
import Foundation
@preconcurrency import ScreenCaptureKit
import WindowDeckCore

/// 窗口截图、缓存、按需刷新与预热。
@MainActor
final class ThumbnailService {
    final class Thumbnail {
        let image: CGImage
        let capturedAt: Date

        init(image: CGImage, capturedAt: Date) {
            self.image = image
            self.capturedAt = capturedAt
        }
    }

    /// 截图完成（窗口 ID, 新图）。
    var onUpdate: ((CGWindowID, CGImage) -> Void)?

    var isEnabled = false {
        didSet {
            if !isEnabled { clear() }
        }
    }

    var quality: ThumbnailQuality = .balanced
    /// 超过该时间的缓存才在打开时刷新。
    var staleInterval: TimeInterval = 2

    private let cache = NSCache<NSNumber, Thumbnail>()
    private var scWindows: [CGWindowID: SCWindow] = [:]
    private var contentFetchedAt: Date?
    private var contentTask: Task<Void, Never>?
    private var inflight: Set<CGWindowID> = []
    private let maxConcurrent = 4

    init() {
        // 约 200MB：成本按像素字节数计算。
        cache.totalCostLimit = 200 * 1024 * 1024
    }

    func cached(_ id: CGWindowID) -> CGImage? {
        cache.object(forKey: NSNumber(value: id))?.image
    }

    /// 直接写入缓存（离屏预览用）。
    func inject(_ image: CGImage, for id: CGWindowID) {
        cache.setObject(Thumbnail(image: image, capturedAt: Date()), forKey: NSNumber(value: id), cost: image.bytesPerRow * image.height)
    }

    func clear() {
        cache.removeAllObjects()
        scWindows.removeAll()
        contentFetchedAt = nil
    }

    /// 窗口集合变化后调用，后台刷新 SCWindow 映射。
    func invalidateContent() {
        contentFetchedAt = nil
    }

    // MARK: 刷新

    /// 按传入顺序（可见卡片优先）刷新过期缩略图，最大并发 4。
    func refresh(_ windows: [WindowInfo], force: Bool = false) {
        guard isEnabled, PermissionService.isScreenRecordingGranted else { return }
        let now = Date()
        let targets = windows.filter { w in
            guard !w.isMinimized, !inflight.contains(w.id) else { return false }
            if force { return true }
            guard let existing = cache.object(forKey: NSNumber(value: w.id)) else { return true }
            return now.timeIntervalSince(existing.capturedAt) > staleInterval
        }
        guard !targets.isEmpty else { return }
        for w in targets { inflight.insert(w.id) }

        Task { @MainActor in
            await self.ensureContent(for: targets.map(\.id))
            let scale = NSScreen.main?.backingScaleFactor ?? 2
            let maxPixel = self.quality.maxPixelDimension
            let jobs = targets.map { CaptureJob(id: $0.id, frame: $0.frame, scWindow: self.scWindows[$0.id], scale: scale, maxPixel: maxPixel) }
            await withTaskGroup(of: (CGWindowID, CGImage?).self) { group in
                var next = 0
                while next < min(self.maxConcurrent, jobs.count) {
                    let job = jobs[next]
                    group.addTask { (job.id, await Self.capture(job)) }
                    next += 1
                }
                while let (id, image) = await group.next() {
                    self.inflight.remove(id)
                    if let image {
                        self.store(image, for: id)
                    }
                    if next < jobs.count {
                        let job = jobs[next]
                        group.addTask { (job.id, await Self.capture(job)) }
                        next += 1
                    }
                }
            }
            for w in targets { self.inflight.remove(w.id) }
        }
    }

    /// 窗口失去焦点时预热截图，保证打开覆盖层时缓存基本是新的。
    func prewarm(_ window: WindowInfo) {
        refresh([window], force: true)
    }

    private func store(_ image: CGImage, for id: CGWindowID) {
        let cost = image.bytesPerRow * image.height
        cache.setObject(Thumbnail(image: image, capturedAt: Date()), forKey: NSNumber(value: id), cost: cost)
        onUpdate?(id, image)
    }

    /// 维护 [CGWindowID: SCWindow]：缺少目标窗口或已过期时重新获取。
    private func ensureContent(for ids: [CGWindowID]) async {
        let fresh = contentFetchedAt.map { Date().timeIntervalSince($0) < 5 } ?? false
        if fresh, ids.allSatisfy({ scWindows[$0] != nil }) { return }
        if let contentTask {
            await contentTask.value
            if ids.allSatisfy({ scWindows[$0] != nil }) { return }
        }
        let task = Task { @MainActor in
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
                var map: [CGWindowID: SCWindow] = [:]
                for window in content.windows { map[window.windowID] = window }
                self.scWindows = map
                self.contentFetchedAt = Date()
            } catch {
                Log.capture.error("SCShareableContent failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        contentTask = task
        await task.value
        contentTask = nil
    }

    /// SCWindow 是系统给出的不可变快照，跨任务传递是安全的。
    private struct CaptureJob: @unchecked Sendable {
        let id: CGWindowID
        let frame: CGRect
        let scWindow: SCWindow?
        let scale: CGFloat
        let maxPixel: Double
    }

    private nonisolated static func capture(_ job: CaptureJob) async -> CGImage? {
        guard let window = job.scWindow else { return nil }
        let size = window.frame.size.width > 0 ? window.frame.size : job.frame.size
        guard size.width > 0, size.height > 0 else { return nil }
        var pixelW = size.width * job.scale
        var pixelH = size.height * job.scale
        let longest = max(pixelW, pixelH)
        if longest > job.maxPixel {
            let k = job.maxPixel / longest
            pixelW *= k
            pixelH *= k
        }
        let config = SCStreamConfiguration()
        config.width = max(Int(pixelW.rounded()), 1)
        config.height = max(Int(pixelH.rounded()), 1)
        config.showsCursor = false
        config.ignoreShadowsSingleWindow = true
        config.scalesToFit = true
        // 以 Retina 原始分辨率采样后再缩到目标尺寸，避免先按 1x 采样再放大。
        config.captureResolution = .best
        let filter = SCContentFilter(desktopIndependentWindow: window)
        do {
            return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        } catch {
            Log.capture.debug("capture \(window.windowID) failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}
