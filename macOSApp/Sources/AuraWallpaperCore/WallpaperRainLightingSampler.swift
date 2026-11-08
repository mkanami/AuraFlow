import AppKit
import AVFoundation
import CoreImage
import ImageIO
import IOSurface
import OSLog
import WebKit

/// Renderers can expose their already completed frame without a full-size CPU readback.
@MainActor public protocol WallpaperRainSurfaceProviding: AnyObject {
    var rainLightingSurfaceID: UInt32? { get }
}

@MainActor
final class WallpaperRainLightingSampler {
    private enum Source: Equatable {
        case video(ObjectIdentifier), surface(UInt32), image(ObjectIdentifier), file(URL), web(ObjectIdentifier)
        var label: String {
            switch self {
            case .video: return "video"
            case .surface: return "rendered-frame"
            case .image, .file: return "image"
            case .web: return "web"
            }
        }
    }
    private static let logger = Logger(subsystem: "com.andrijvergeles.auraflow", category: "WallpaperRainLighting")
    private static let queue = DispatchQueue(label: "com.andrijvergeles.auraflow.rain-lighting", qos: .utility)
    nonisolated private static let context = CIContext(options: [.cacheIntermediates: false])
    private var source: Source?
    private var videoItem: AVPlayerItem?
    private var videoOutput: AVPlayerItemVideoOutput?
    private var nextSample = -Double.infinity
    private var epoch: UInt64 = 0
    private var task: UUID?
    private var completedStatic = false
    private var viewport = CGSize.zero
    private var published = false
    private(set) var submittedSamples = 0
    var onSample: ((WallpaperRainLighting) -> Void)?

    func stop() {
        guard source != nil else { return }
        epoch &+= 1
        source = nil
        completedStatic = false
        published = false
        nextSample = -Double.infinity
        detachVideo()
    }

    func sample(content: NSView, surfaceID: UInt32?, imageURL: URL?, at time: Double) {
        guard task == nil, time >= nextSample else { return }
        if viewport != content.bounds.size { stop(); viewport = content.bounds.size }
        let views = descendants(of: content)
        let surfaceID = surfaceID ?? views.compactMap { ($0 as? WallpaperRainSurfaceProviding)?.rainLightingSurfaceID }.first
        var video: AVPlayerLayer?
        var image: CGImage?
        var web: WKWebView?
        let selected: Source
        if let surfaceID { selected = .surface(surfaceID) }
        else if let imageURL { selected = .file(imageURL) }
        else {
            video = views.lazy.compactMap { findVideo(in: $0.layer) }.first
            if let item = video?.player?.currentItem { selected = .video(ObjectIdentifier(item)) }
            else if let found = views.compactMap({ $0 as? WKWebView }).first {
                web = found; selected = .web(ObjectIdentifier(found))
            } else if let found = views.lazy.compactMap({ findImage(in: $0.layer) }).first {
                image = found; selected = .image(ObjectIdentifier(found))
            } else { stop(); return }
        }
        if source != selected {
            stop()
            source = selected
            onSample?(.neutral)
        } else if completedStatic { return }
        nextSample = time + 2
        let ticket = UUID()
        task = ticket
        let epoch = epoch
        let viewport = content.bounds.size
        switch selected {
        case .surface(let id):
            guard let surface = IOSurfaceLookup(id) else { complete(nil, ticket: ticket, epoch: epoch); return }
            process(CIImage(ioSurface: surface), viewport: viewport, ticket: ticket, epoch: epoch)
        case .video:
            guard let layer = video, let item = layer.player?.currentItem else { complete(nil, ticket: ticket, epoch: epoch); return }
            if videoItem !== item {
                detachVideo()
                let output = AVPlayerItemVideoOutput(pixelBufferAttributes: nil)
                output.suppressesPlayerRendering = false
                item.add(output)
                videoItem = item; videoOutput = output
            }
            let time = item.currentTime()
            guard let output = videoOutput, output.hasNewPixelBuffer(forItemTime: time),
                  let pixelBuffer = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil) else {
                complete(nil, ticket: ticket, epoch: epoch); return
            }
            process(CIImage(cvPixelBuffer: pixelBuffer), viewport: viewport, gravity: layer.videoGravity,
                ticket: ticket, epoch: epoch)
        case .file(let url):
            Self.queue.async { [weak self] in
                let source = CGImageSourceCreateWithURL(url as CFURL, nil)
                let options = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 64] as CFDictionary
                let image = source.flatMap { CGImageSourceCreateThumbnailAtIndex($0, 0, options) }
                let result = image.flatMap { Self.analyze(CIImage(cgImage: $0), viewport: viewport) }
                DispatchQueue.main.async { self?.complete(result, ticket: ticket, epoch: epoch) }
            }
        case .image:
            guard let image else { complete(nil, ticket: ticket, epoch: epoch); return }
            process(CIImage(cgImage: image), viewport: viewport, ticket: ticket, epoch: epoch)
        case .web:
            guard let web else { complete(nil, ticket: ticket, epoch: epoch); return }
            let configuration = WKSnapshotConfiguration()
            configuration.rect = web.bounds
            configuration.snapshotWidth = 32
            web.takeSnapshot(with: configuration) { [weak self] image, _ in
                guard let self else { return }
                guard self.epoch == epoch, let cg = image?.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                    self.complete(nil, ticket: ticket, epoch: epoch); return
                }
                self.process(CIImage(cgImage: cg), viewport: viewport, ticket: ticket, epoch: epoch)
            }
        }
    }

    private func process(_ image: CIImage, viewport: CGSize, gravity: AVLayerVideoGravity = .resizeAspectFill,
                         ticket: UUID, epoch: UInt64) {
        submittedSamples += 1
        Self.queue.async { [weak self] in
            let result = Self.analyze(image, viewport: viewport, gravity: gravity)
            DispatchQueue.main.async { self?.complete(result, ticket: ticket, epoch: epoch) }
        }
    }

    nonisolated private static func analyze(_ image: CIImage, viewport: CGSize,
                                          gravity: AVLayerVideoGravity = .resizeAspectFill) -> WallpaperRainLighting? {
        let target = CGRect(x: 0, y: 0, width: 32, height: max(8, min(32, (32 * viewport.height / max(1, viewport.width)).rounded())))
        let extent = image.extent
        guard extent.width > 0, extent.height > 0, !extent.isInfinite else { return nil }
        let sx = target.width / extent.width, sy = target.height / extent.height
        let factor = gravity == .resizeAspect ? min(sx, sy) : max(sx, sy)
        let scale = gravity == .resize ? CGAffineTransform(scaleX: sx, y: sy) : CGAffineTransform(scaleX: factor, y: factor)
        var small = image.transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY)).transformed(by: scale)
        small = small.transformed(by: CGAffineTransform(translationX: (target.width - small.extent.width) / 2,
            y: (target.height - small.extent.height) / 2))
        let opaque = small.composited(over: CIImage(color: .black).cropped(to: target)).cropped(to: target)
        guard let frame = context.createCGImage(opaque, from: target, format: .RGBA8,
            colorSpace: CGColorSpace(name: CGColorSpace.sRGB)) else { return nil }
        return WallpaperRainLighting.analyze(frame)
    }

    private func complete(_ result: WallpaperRainLighting?, ticket: UUID, epoch: UInt64) {
        guard task == ticket else { return }
        task = nil
        guard self.epoch == epoch, source != nil, let result else { return }
        if !published {
            published = true
            Self.logger.debug("Rain lighting ready source=\(self.source?.label ?? "unknown", privacy: .public)")
        }
        if case .image = source { completedStatic = true }
        if case .file = source { completedStatic = true }
        onSample?(result)
    }
    private func detachVideo() {
        if let output = videoOutput { videoItem?.remove(output) }
        videoOutput = nil; videoItem = nil
    }
    deinit { if let videoOutput { videoItem?.remove(videoOutput) } }
}

@MainActor private func descendants(of root: NSView) -> [NSView] {
    var result = [root]
    var index = 0
    while index < result.count, result.count < 256 {
        result.append(contentsOf: result[index].subviews)
        index += 1
    }
    return result
}
@MainActor private func findVideo(in layer: CALayer?) -> AVPlayerLayer? {
    guard let layer else { return nil }
    if let video = layer as? AVPlayerLayer, video.player != nil { return video }
    for child in layer.sublayers ?? [] { if let video = findVideo(in: child) { return video } }
    return nil
}
@MainActor private func findImage(in layer: CALayer?) -> CGImage? {
    guard let layer else { return nil }
    if let contents = layer.contents, CFGetTypeID(contents as CFTypeRef) == CGImage.typeID { return (contents as! CGImage) }
    for child in layer.sublayers ?? [] { if let image = findImage(in: child) { return image } }
    return nil
}
