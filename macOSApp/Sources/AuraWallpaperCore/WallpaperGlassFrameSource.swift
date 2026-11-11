import AppKit
import AVFoundation
import CoreImage
import ImageIO
import IOSurface
import WebKit

/// Reads only the wallpaper renderer's own media, never the screen or other windows.
@MainActor
final class WallpaperGlassFrameSource {
    struct Frame {
        let image: CIImage
        let gravity: AVLayerVideoGravity
        let revision: UInt64
        let label: String
    }
    private enum Source: Equatable {
        case surface(UInt32), video(ObjectIdentifier), image(ObjectIdentifier), file(URL), web(ObjectIdentifier)
    }
    private var source: Source?
    private weak var imageLayer: CALayer?
    private weak var videoLayer: AVPlayerLayer?
    private weak var surfaceProvider: (any WallpaperRainSurfaceProviding)?
    private weak var webView: WKWebView?
    private var videoItem: AVPlayerItem?
    private var output: AVPlayerItemVideoOutput?
    private var frame: Frame?
    private var revision: UInt64 = 0
    private var epoch: UInt64 = 0
    private var nextDiscovery = -Double.infinity
    private var nextWeb = -Double.infinity
    private var pending = false
    private var lastSurfaceSequence: UInt64?
    private(set) var submittedSnapshots = 0
    var hasVideoOutput: Bool { output != nil }

    func stop() {
        guard source != nil || output != nil || frame != nil else { return }
        epoch &+= 1
        if let output { videoItem?.remove(output) }
        output = nil; videoItem = nil; videoLayer = nil; webView = nil; imageLayer = nil; surfaceProvider = nil
        source = nil; frame = nil; pending = false; lastSurfaceSequence = nil
        nextDiscovery = -.infinity; nextWeb = -.infinity
    }

    func current(content: NSView, surfaceID: UInt32?, sequence: UInt64?, imageURL: URL?, surfaceGravity: AVLayerVideoGravity? = nil, at time: Double) -> Frame? {
        if time >= nextDiscovery {
            discover(content: content, surfaceID: surfaceID, imageURL: imageURL)
            nextDiscovery = time + 0.5
        }
        switch source {
        case .surface(let id):
            let sequence = sequence ?? surfaceProvider?.rainFrameSequence
            let gravity = surfaceGravity ?? surfaceProvider?.rainFrameGravity ?? .resize
            if frame == nil || sequence == nil || sequence != lastSurfaceSequence || frame?.gravity != gravity {
                if let surface = IOSurfaceLookup(id) {
                    publish(CIImage(ioSurface: surface), label: "rendered-frame", gravity: gravity)
                    lastSurfaceSequence = sequence
                } else { frame = nil }
            }
        case .video:
            // Swapping an AVPlayerItem in the same layer must invalidate the cached output.
            if videoLayer?.player?.currentItem !== videoItem {
                nextDiscovery = -.infinity; frame = nil; return nil
            }
            if let item = videoItem, let output {
                let itemTime = item.currentTime()
                if output.hasNewPixelBuffer(forItemTime: itemTime),
                   let pixelBuffer = output.copyPixelBuffer(forItemTime: itemTime, itemTimeForDisplay: nil) {
                    publish(CIImage(cvPixelBuffer: pixelBuffer), label: "video", gravity: videoLayer?.videoGravity ?? .resizeAspectFill)
                }
            }
        case .web:
            if time >= nextWeb, !pending, let webView, webView.bounds.width > 0 {
                nextWeb = time + 0.125
                pending = true; submittedSnapshots += 1
                let epoch = epoch
                let configuration = WKSnapshotConfiguration()
                configuration.rect = webView.bounds
                configuration.snapshotWidth = NSNumber(value: min(1536, webView.bounds.width))
                webView.takeSnapshot(with: configuration) { [weak self] image, _ in
                    guard let self, self.epoch == epoch else { return }
                    self.pending = false
                    if let cg = image?.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                        self.publish(CIImage(cgImage: cg), label: "web", gravity: .resize)
                    }
                }
            }
        case .image:
            if let imageLayer, let frame, frame.gravity != Self.gravity(imageLayer.contentsGravity) {
                publish(frame.image, label: frame.label, gravity: Self.gravity(imageLayer.contentsGravity))
            }
        default: break
        }
        return frame
    }

    private func discover(content: NSView, surfaceID: UInt32?, imageURL: URL?) {
        var views = [content], index = 0
        while index < views.count, views.count < 256 {
            views.append(contentsOf: views[index].subviews); index += 1
        }
        let provider = views.compactMap { $0 as? WallpaperRainSurfaceProviding }.first { $0.rainLightingSurfaceID != nil }
        let surfaceID = surfaceID ?? provider?.rainLightingSurfaceID
        let video = views.lazy.compactMap { Self.video(in: $0.layer) }.first
        let web = views.compactMap { $0 as? WKWebView }.first
        let imageLayer = views.lazy.compactMap { Self.imageLayer(in: $0.layer) }.first
        let image: CGImage? = imageLayer.flatMap { layer in
            guard let contents = layer.contents else { return nil }; return (contents as! CGImage)
        }
        let selected: Source?
        if let surfaceID { selected = .surface(surfaceID) }
        else if let imageURL { selected = .file(imageURL) }
        else if let item = video?.player?.currentItem { selected = .video(ObjectIdentifier(item)) }
        else if let web { selected = .web(ObjectIdentifier(web)) }
        else if let image { selected = .image(ObjectIdentifier(image)) }
        else { selected = nil }
        if selected == source {
            // SwiftUI can rebuild the leaf while keeping the same media item.
            // Refresh weak owners even when its texture identity is unchanged.
            switch selected {
            case .video: videoLayer = video
            case .image: self.imageLayer = imageLayer
            case .web: webView = web
            case .surface: surfaceProvider = provider
            default: break
            }
            return
        }
        stop(); source = selected; surfaceProvider = provider
        switch selected {
        case .video:
            videoLayer = video
            videoItem = video?.player?.currentItem
            let output = AVPlayerItemVideoOutput(pixelBufferAttributes: nil)
            output.suppressesPlayerRendering = false
            videoItem?.add(output); self.output = output
        case .web: webView = web
        case .image:
            self.imageLayer = imageLayer
            if let image { publish(CIImage(cgImage: image), label: "image", gravity: Self.gravity(imageLayer?.contentsGravity ?? .resizeAspectFill)) }
        case .file(let url):
            pending = true
            let epoch = epoch
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let source = CGImageSourceCreateWithURL(url as CFURL, nil)
                let options = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 2048] as CFDictionary
                let image = source.flatMap { CGImageSourceCreateThumbnailAtIndex($0, 0, options) }
                DispatchQueue.main.async {
                    guard let self, self.epoch == epoch else { return }
                    self.pending = false
                    if let image { self.publish(CIImage(cgImage: image), label: "image", gravity: .resizeAspectFill) }
                }
            }
        default: break
        }
    }

    private func publish(_ image: CIImage, label: String, gravity: AVLayerVideoGravity) {
        revision &+= 1
        frame = Frame(image: image, gravity: gravity, revision: revision, label: label)
    }
    private static func video(in layer: CALayer?) -> AVPlayerLayer? {
        guard let layer else { return nil }
        if let layer = layer as? AVPlayerLayer, layer.player != nil { return layer }
        return layer.sublayers?.lazy.compactMap { video(in: $0) }.first
    }
    private static func imageLayer(in layer: CALayer?) -> CALayer? {
        guard let layer else { return nil }
        if let contents = layer.contents, CFGetTypeID(contents as CFTypeRef) == CGImage.typeID { return layer }
        return layer.sublayers?.lazy.compactMap { imageLayer(in: $0) }.first
    }
    private static func gravity(_ gravity: CALayerContentsGravity) -> AVLayerVideoGravity {
        if gravity == .resizeAspect { return .resizeAspect }
        if gravity == .resize { return .resize }
        return .resizeAspectFill
    }
    deinit { if let output { videoItem?.remove(output) } }
}
