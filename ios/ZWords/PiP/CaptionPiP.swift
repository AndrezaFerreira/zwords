import AVFoundation
import AVKit
import CoreMedia
import UIKit

/// Floating captions over any app, using Picture in Picture with a
/// sample-buffer layer whose frames are rendered caption text. iOS does not
/// allow third-party overlays, so PiP is the closest system-sanctioned option.
final class CaptionPiP: NSObject, ObservableObject {
    struct Content: Equatable {
        var primary: String
        var secondary: String?
    }

    @Published private(set) var isPossible = false
    @Published private(set) var isActive = false

    /// Whether some capture is running (drives the PiP play/pause button).
    var isActiveCapture: () -> Bool = { false }
    var onSetPlaying: (Bool) -> Void = { _ in }

    let displayLayer = AVSampleBufferDisplayLayer()
    private var controller: AVPictureInPictureController?
    private var possibleObservation: NSKeyValueObservation?
    private var content = Content(primary: "ZWords", secondary: nil)
    private var renderedContent: Content?
    private var renderScheduled = false
    private var lastPixelBuffer: CVPixelBuffer?
    private var refreshTimer: Timer?
    private let size = CGSize(width: 1080, height: 360)

    func setup() {
        guard controller == nil, AVPictureInPictureController.isPictureInPictureSupported() else { return }
        displayLayer.videoGravity = .resizeAspect
        var timebase: CMTimebase?
        CMTimebaseCreateWithSourceClock(allocator: kCFAllocatorDefault,
                                        sourceClock: CMClockGetHostTimeClock(),
                                        timebaseOut: &timebase)
        if let timebase {
            CMTimebaseSetTime(timebase, time: CMClockGetTime(CMClockGetHostTimeClock()))
            CMTimebaseSetRate(timebase, rate: 1)
            displayLayer.controlTimebase = timebase
        }

        let source = AVPictureInPictureController.ContentSource(sampleBufferDisplayLayer: displayLayer,
                                                                playbackDelegate: self)
        let controller = AVPictureInPictureController(contentSource: source)
        controller.delegate = self
        controller.canStartPictureInPictureAutomaticallyFromInline = true
        controller.requiresLinearPlayback = true
        possibleObservation = controller.observe(\.isPictureInPicturePossible, options: [.initial, .new]) { [weak self] controller, _ in
            let possible = controller.isPictureInPicturePossible
            DispatchQueue.main.async { self?.isPossible = possible }
        }
        self.controller = controller
        render()
    }

    func toggle() {
        guard let controller else { return }
        if controller.isPictureInPictureActive {
            controller.stopPictureInPicture()
        } else {
            controller.startPictureInPicture()
        }
    }

    func invalidatePlaybackState() {
        controller?.invalidatePlaybackState()
    }

    func show(_ newContent: Content) {
        content = newContent
        guard !renderScheduled else { return }
        renderScheduled = true
        // Coalesce bursts of updates (≤ 8 frames per second).
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            self?.renderScheduled = false
            self?.render()
        }
    }

    // MARK: - Rendering

    private func render() {
        guard controller != nil else { return }
        if content != renderedContent || lastPixelBuffer == nil {
            renderedContent = content
            lastPixelBuffer = makePixelBuffer(for: content)
        }
        enqueue()
    }

    private func enqueue() {
        guard let pixelBuffer = lastPixelBuffer,
              let sampleBuffer = makeSampleBuffer(from: pixelBuffer) else { return }
        let renderer = displayLayer.sampleBufferRenderer
        if renderer.status == .failed { renderer.flush() }
        renderer.enqueue(sampleBuffer)
    }

    private func makePixelBuffer(for content: Content) -> CVPixelBuffer? {
        let width = Int(size.width), height = Int(size.height)
        let attributes: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as [CFString: Any],
        ]
        var buffer: CVPixelBuffer?
        guard CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
                                  attributes as CFDictionary, &buffer) == kCVReturnSuccess,
              let buffer else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                          | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        context.translateBy(x: 0, y: size.height)
        context.scaleBy(x: 1, y: -1)
        UIGraphicsPushContext(context)
        draw(content, in: CGRect(origin: .zero, size: size))
        UIGraphicsPopContext()
        return buffer
    }

    private func draw(_ content: Content, in rect: CGRect) {
        UIColor.black.setFill()
        UIRectFill(rect)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byWordWrapping
        let inset = rect.insetBy(dx: 48, dy: 28)

        var blocks: [NSAttributedString] = []
        let hasSecondary = content.secondary != nil
        let primaryText = Self.tail(content.primary, maxCharacters: hasSecondary ? 80 : 120)
        blocks.append(NSAttributedString(string: primaryText, attributes: [
            .font: UIFont.systemFont(ofSize: hasSecondary ? 50 : 58, weight: .semibold),
            .foregroundColor: UIColor.white,
            .paragraphStyle: paragraph,
        ]))
        if let secondary = content.secondary {
            blocks.append(NSAttributedString(string: Self.tail(secondary, maxCharacters: 80), attributes: [
                .font: UIFont.systemFont(ofSize: 44, weight: .regular),
                .foregroundColor: UIColor(red: 1, green: 0.84, blue: 0.4, alpha: 1),
                .paragraphStyle: paragraph,
            ]))
        }
        let options: NSStringDrawingOptions = [.usesLineFragmentOrigin, .truncatesLastVisibleLine]
        let spacing: CGFloat = 14
        let heights = blocks.map { ceil($0.boundingRect(with: CGSize(width: inset.width, height: .greatestFiniteMagnitude),
                                                        options: options, context: nil).height) }
        let total = min(heights.reduce(0, +) + spacing * CGFloat(blocks.count - 1), inset.height)
        var y = inset.midY - total / 2
        for (block, height) in zip(blocks, heights) {
            let available = min(height, inset.maxY - y)
            guard available > 0 else { break }
            block.draw(with: CGRect(x: inset.minX, y: y, width: inset.width, height: available),
                       options: options, context: nil)
            y += height + spacing
        }
    }

    /// Keeps the end of a long live sentence (what is being said right now).
    static func tail(_ text: String, maxCharacters: Int) -> String {
        guard text.count > maxCharacters else { return text }
        let suffix = text.suffix(maxCharacters)
        if let space = suffix.firstIndex(of: " ") {
            return "…" + suffix[suffix.index(after: space)...]
        }
        return "…" + suffix
    }

    private func makeSampleBuffer(from pixelBuffer: CVPixelBuffer) -> CMSampleBuffer? {
        var format: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer,
                                                           formatDescriptionOut: &format) == noErr,
              let format else { return nil }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30),
                                        presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
                                        decodeTimeStamp: .invalid)
        var sampleBuffer: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer,
                                                       formatDescription: format, sampleTiming: &timing,
                                                       sampleBufferOut: &sampleBuffer) == noErr,
              let sampleBuffer else { return nil }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let dictionary = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dictionary,
                                 Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        return sampleBuffer
    }

    private func setRefreshTimer(active: Bool) {
        refreshTimer?.invalidate()
        refreshTimer = nil
        guard active else { return }
        // Re-present the current frame occasionally so PiP never shows a stall.
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            self?.enqueue()
        }
    }
}

extension CaptionPiP: AVPictureInPictureControllerDelegate {
    func pictureInPictureControllerDidStartPictureInPicture(_ controller: AVPictureInPictureController) {
        DispatchQueue.main.async {
            self.isActive = true
            self.setRefreshTimer(active: true)
        }
    }

    func pictureInPictureControllerDidStopPictureInPicture(_ controller: AVPictureInPictureController) {
        DispatchQueue.main.async {
            self.isActive = false
            self.setRefreshTimer(active: false)
        }
    }

    func pictureInPictureController(_ controller: AVPictureInPictureController,
                                    failedToStartPictureInPictureWithError error: Error) {
        DispatchQueue.main.async { self.isActive = false }
    }
}

extension CaptionPiP: AVPictureInPictureSampleBufferPlaybackDelegate {
    func pictureInPictureController(_ controller: AVPictureInPictureController, setPlaying playing: Bool) {
        DispatchQueue.main.async {
            self.onSetPlaying(playing)
            controller.invalidatePlaybackState()
        }
    }

    func pictureInPictureControllerTimeRangeForPlayback(_ controller: AVPictureInPictureController) -> CMTimeRange {
        // Live content.
        CMTimeRange(start: .negativeInfinity, duration: .positiveInfinity)
    }

    func pictureInPictureControllerIsPlaybackPaused(_ controller: AVPictureInPictureController) -> Bool {
        if Thread.isMainThread { return !isActiveCapture() }
        return DispatchQueue.main.sync { !isActiveCapture() }
    }

    func pictureInPictureController(_ controller: AVPictureInPictureController,
                                    didTransitionToRenderSize newRenderSize: CMVideoDimensions) {}

    func pictureInPictureController(_ controller: AVPictureInPictureController,
                                    skipByInterval skipInterval: CMTime,
                                    completion completionHandler: @escaping () -> Void) {
        completionHandler()
    }
}
