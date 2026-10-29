import AppKit
import AVFoundation
import CoreImage
import CoreMedia
import WinPhoneCore

/// Shows the phone's screen: takes the frames of H.264 video as they arrive and hands them
/// to a layer that decodes and draws them. Frames come straight from the connection, on a
/// queue of their own, so that the picture does not wait on the rest of the app.
final class ScreenVideo: @unchecked Sendable {
    let layer = AVSampleBufferDisplayLayer()
    private let queue = DispatchQueue(label: "winphone.screen.video", qos: .userInteractive)
    // Everything below is used on the queue only.
    private var format: CMVideoFormatDescription?
    /// Nothing is shown until the next whole frame: at the start, and after one went missing,
    /// since frames that build on a missing one draw as garbage.
    private var needsKeyframe = true
    private var lastFrame: UInt32?
    private var shown = 0, held = 0, drawnPastGaps = 0
    private var pictureSize: CMVideoDimensions?
    /// Told, on the main thread, when the pictures in the stream change their size: the
    /// phone was turned, or what it shows took another shape.
    private var onPictureSize: (@MainActor @Sendable (_ width: Int, _ height: Int) -> Void)?

    func whenPictureSizeChanges(_ handler: @escaping @MainActor @Sendable (_ width: Int, _ height: Int) -> Void) {
        queue.async { [self] in onPictureSize = handler }
    }

    /// The clock the frames play on, behind the phone's capture times (see `FramePacer`).
    /// Off unless the default `screen.pacing` is set: tried on 2026-10-16 it held frames
    /// 49 ms on average (late frames pushed its clock back) and felt worse than showing each
    /// frame on arrival.
    private let timebase: CMTimebase?
    private var pacer = FramePacer()

    init(paced: Bool = UserDefaults.standard.bool(forKey: "screen.pacing")) {
        layer.videoGravity = .resizeAspect
        layer.backgroundColor = .black
        var timebase: CMTimebase?
        if paced, CMTimebaseCreateWithSourceClock(allocator: kCFAllocatorDefault, sourceClock: CMClockGetHostTimeClock(), timebaseOut: &timebase) == noErr, let timebase {
            CMTimebaseSetRate(timebase, rate: 1)
            layer.controlTimebase = timebase
        }
        self.timebase = timebase
    }

    /// How the pacing went, for the log: frames that came too late for their time, and the
    /// room an average frame had before it was due, in milliseconds.
    func pacingCounts() -> (late: Int, averageRoom: Int)? {
        queue.sync { timebase == nil ? nil : (pacer.late, Int(pacer.averageSlack * 1000)) }
    }

    /// Forgets the stream, as before a new one.
    func reset() {
        queue.async { [self] in
            format = nil
            needsKeyframe = true
            lastFrame = nil
            shown = 0
            held = 0
            drawnPastGaps = 0
            pictureSize = nil
            pacer.reset()
            layer.sampleBufferRenderer.flush(removingDisplayedImage: true, completionHandler: nil)
        }
    }

    /// Frames shown, frames held back while waiting for a whole one, and frames drawn
    /// although one before them was missing, for the log.
    func counts() -> (shown: Int, held: Int, pastGaps: Int) {
        queue.sync { (shown, held, drawnPastGaps) }
    }

    /// The parameter sets a stream starts with, as a description of its pictures.
    static func description(of units: [Data]) -> CMVideoFormatDescription? {
        guard let sequence = units.first(where: { ($0.first ?? 0) & 0x1F == H264.Kind.sequenceParameters }),
              let picture = units.first(where: { ($0.first ?? 0) & 0x1F == H264.Kind.pictureParameters }) else { return nil }
        var description: CMVideoFormatDescription?
        let status = sequence.withUnsafeBytes { (first: UnsafeRawBufferPointer) -> OSStatus in
            picture.withUnsafeBytes { (second: UnsafeRawBufferPointer) -> OSStatus in
                let pointers = [first.bindMemory(to: UInt8.self).baseAddress!, second.bindMemory(to: UInt8.self).baseAddress!]
                let sizes = [sequence.count, picture.count]
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(allocator: kCFAllocatorDefault, parameterSetCount: 2, parameterSetPointers: pointers,
                                                                           parameterSetSizes: sizes, nalUnitHeaderLength: 4, formatDescriptionOut: &description)
            }
        }
        return status == noErr ? description : nil
    }

    /// One frame as the layer wants it: each unit with its length in front instead of a start code.
    /// - Parameter at: when it is to be shown on the playing clock; without it, at once.
    static func sample(of units: [Data], format: CMVideoFormatDescription, at time: CMTime? = nil) -> CMSampleBuffer? {
        var bytes = Data()
        for unit in units {
            var length = UInt32(unit.count).bigEndian
            withUnsafeBytes(of: &length) { bytes.append(contentsOf: $0) }
            bytes.append(unit)
        }
        guard !bytes.isEmpty else { return nil }
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: bytes.count, blockAllocator: kCFAllocatorDefault,
                                                 customBlockSource: nil, offsetToData: 0, dataLength: bytes.count, flags: 0, blockBufferOut: &block) == noErr, let block,
              bytes.withUnsafeBytes({ CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: bytes.count) }) == noErr else { return nil }
        var sample: CMSampleBuffer?
        var size = bytes.count
        var timing = [CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: time ?? .invalid, decodeTimeStamp: .invalid)]
        let status = time == nil
            ? CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format, sampleCount: 1, sampleTimingEntryCount: 0,
                                        sampleTimingArray: nil, sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample)
            : CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format, sampleCount: 1, sampleTimingEntryCount: 1,
                                        sampleTimingArray: &timing, sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample)
        guard status == noErr, let sample else { return nil }
        // Without a time: shown as soon as it is decoded.
        if time == nil, let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true), CFArrayGetCount(attachments) > 0 {
            let first = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(first, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(), Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        return sample
    }

    /// The picture on show right now, as an image; nil before the first frame, or where the
    /// system cannot hand it over.
    func currentImage() -> CGImage? {
        guard #available(macOS 14.4, *), let buffer = layer.sampleBufferRenderer.displayedPixelBuffer() else { return nil }
        let image = CIImage(cvPixelBuffer: buffer)
        return CIContext().createCGImage(image, from: image.extent)
    }

    /// Takes a frame from any thread.
    func show(_ frame: NanoVideoFrame) {
        queue.async { [self] in display(frame) }
    }

    private func display(_ frame: NanoVideoFrame) {
        let units = H264.units(in: frame.data)
        if let description = ScreenVideo.description(of: units) {
            format = description
            let size = CMVideoFormatDescriptionGetDimensions(description)
            if size.width > 0, size.height > 0, size.width != pictureSize?.width || size.height != pictureSize?.height {
                // Not the first size of a stream: that one the phone has already announced.
                if pictureSize != nil, let onPictureSize {
                    Task { @MainActor in onPictureSize(Int(size.width), Int(size.height)) }
                }
                pictureSize = size
            }
        }
        let pictures = units.filter { [H264.Kind.slice, H264.Kind.keySlice].contains(($0.first ?? 0) & 0x1F) }
        defer { lastFrame = frame.id }
        guard !pictures.isEmpty, let format else { return }
        let isWhole = pictures.contains { ($0.first ?? 0) & 0x1F == H264.Kind.keySlice }
        // A frame is missing before this one. Drawn all the same, as Phone Link does: the
        // phone does not send lost video again, and holding everything until the whole
        // picture it sends on the loss report arrives stalled every animation (2026-10-16:
        // 156 of 1,819 frames held back). The decoder carries on from what it has; any smudge
        // goes with that whole picture. Counted, for the log.
        if let lastFrame, frame.id != lastFrame &+ 1, !isWhole { drawnPastGaps += 1 }
        let renderer = layer.sampleBufferRenderer
        if renderer.status == .failed {
            // The decoder gave up: start again from a whole frame.
            renderer.flush()
            needsKeyframe = true
        }
        if needsKeyframe, !isWhole {
            held += 1
            return
        }
        // On the playing clock: the phone's capture time, with the clock set where the pacer says.
        var time: CMTime?
        if let timebase {
            let capture = Double(frame.timestamp) / 1_000_000
            if let setting = pacer.place(capture: capture, clock: CMTimebaseGetTime(timebase).seconds) {
                CMTimebaseSetTime(timebase, time: CMTime(seconds: setting, preferredTimescale: 1_000_000))
            }
            time = CMTime(value: frame.timestamp, timescale: 1_000_000)
        }
        guard let sample = ScreenVideo.sample(of: pictures, format: format, at: time) else { return }
        needsKeyframe = false
        renderer.enqueue(sample)
        shown += 1
    }
}

/// Pictures taken of the phone's screen.
enum ScreenShots {
    /// The picture as it is shown: turned by quarter turns against the clock.
    static func turned(_ image: CGImage, turns: Int) -> CGImage? {
        let quarter = ((turns % 4) + 4) % 4
        guard quarter != 0 else { return image }
        let width = image.width, height = image.height
        let size = quarter % 2 == 1 ? (height, width) : (width, height)
        guard let context = CGContext(data: nil, width: size.0, height: size.1, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        // The drawing space counts upward, where a positive angle turns against the clock.
        switch quarter {
        case 1: context.translateBy(x: CGFloat(height), y: 0)
        case 2: context.translateBy(x: CGFloat(width), y: CGFloat(height))
        default: context.translateBy(x: 0, y: CGFloat(width))
        }
        context.rotate(by: CGFloat(quarter) * .pi / 2)
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    static func png(_ image: CGImage) -> Data? {
        NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }

    /// A name as the Mac gives its own screenshots, with the time in it.
    static func fileName(at date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return String(format: "Phone Screen %04d-%02d-%02d at %02d.%02d.%02d.png", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0, parts.hour ?? 0, parts.minute ?? 0, parts.second ?? 0)
    }

    /// Writes the picture into the folder under a name not yet taken.
    static func save(_ data: Data, in folder: URL, at date: Date = Date()) throws -> URL {
        let name = fileName(at: date)
        var target = folder.appendingPathComponent(name)
        var count = 2
        while FileManager.default.fileExists(atPath: target.path) {
            target = folder.appendingPathComponent(name.replacingOccurrences(of: ".png", with: " \(count).png"))
            count += 1
        }
        try data.write(to: target, options: .withoutOverwriting)
        return target
    }
}
