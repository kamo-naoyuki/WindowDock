import AppKit
import ScreenCaptureKit

/// A visible page requests stills on demand. Serialize captures and keep only small images in memory.
actor WindowThumbnails {
    private var shareable: Task<[CGWindowID: SCWindow], Error>?
    private var tail: Task<CGImage?, Never>?
    private let cache = NSCache<NSNumber, CGImage>()

    init() { cache.countLimit = 40 }

    func image(for id: CGWindowID) async -> CGImage? {
        guard !Task.isCancelled, CGPreflightScreenCaptureAccess() else { return nil }
        if let image = cache.object(forKey: NSNumber(value: id)) { return image }
        let previous = tail
        let capture = Task {
            _ = await previous?.value
            guard !Task.isCancelled else { return nil as CGImage? }
            return await self.capture(id)
        }
        tail = capture
        return await withTaskCancellationHandler {
            await capture.value
        } onCancel: {
            capture.cancel()
        }
    }

    private func capture(_ id: CGWindowID) async -> CGImage? {
        let image: CGImage?
        if #available(macOS 14, *) {
            do {
                if shareable == nil {
                    shareable = Task {
                        let content = try await SCShareableContent.excludingDesktopWindows(true,
                                                                                           onScreenWindowsOnly: false)
                        return Dictionary(uniqueKeysWithValues: content.windows.map { ($0.windowID, $0) })
                    }
                }
                guard let window = try await shareable?.value[id], !Task.isCancelled else { return nil }
                let filter = SCContentFilter(desktopIndependentWindow: window)
                let size = filter.contentRect.size
                guard size.width > 0, size.height > 0 else { return nil }
                let scale = min(1, 320 / size.width, 200 / size.height)
                let config = SCStreamConfiguration()
                config.width = max(1, Int(size.width * scale))
                config.height = max(1, Int(size.height * scale))
                config.showsCursor = false
                config.ignoreShadowsSingleWindow = true
                image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            } catch {
                WindowAccess.logger.debug("Window preview unavailable: \(error.localizedDescription, privacy: .public)")
                return nil
            }
        } else {
            guard let full = CGWindowListCreateImage(.null, .optionIncludingWindow, id,
                                                     [.boundsIgnoreFraming, .nominalResolution]) else { return nil }
            let scale = min(1, 320 / Double(full.width), 200 / Double(full.height))
            let width = max(1, Int(Double(full.width) * scale)), height = max(1, Int(Double(full.height) * scale))
            guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return nil }
            context.draw(full, in: CGRect(x: 0, y: 0, width: width, height: height))
            image = context.makeImage()
        }
        if let image { cache.setObject(image, forKey: NSNumber(value: id)) }
        return image
    }
}
