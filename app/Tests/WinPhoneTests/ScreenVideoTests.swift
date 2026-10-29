import AppKit
import AVFoundation
import VideoToolbox
import XCTest
@testable import WinPhone
@testable import WinPhoneCore

/// The picture end to end with real H.264, made here with the Mac's own encoder: shown,
/// followed when its size changes, and read back for a screenshot.
final class ScreenVideoTests: XCTestCase {
    /// One whole frame of a plain colour, as a stream with start codes: parameter sets, then the picture.
    func keyframe(width: Int32, height: Int32) throws -> Data {
        var session: VTCompressionSession?
        guard VTCompressionSessionCreate(allocator: nil, width: width, height: height, codecType: kCMVideoCodecType_H264, encoderSpecification: nil,
                                         imageBufferAttributes: nil, compressedDataAllocator: nil, outputCallback: nil, refcon: nil, compressionSessionOut: &session) == noErr,
              let session else { throw XCTSkip("no H.264 encoder here") }
        defer { VTCompressionSessionInvalidate(session) }
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, Int(width), Int(height), kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer)
        guard let buffer else { throw XCTSkip("no picture buffer") }
        CVPixelBufferLockBaseAddress(buffer, [])
        memset(CVPixelBufferGetBaseAddress(buffer), 0x80, CVPixelBufferGetDataSize(buffer))
        CVPixelBufferUnlockBaseAddress(buffer, [])
        let done = expectation(description: "encoded")
        nonisolated(unsafe) var stream = Data()
        let status = VTCompressionSessionEncodeFrame(session, imageBuffer: buffer, presentationTimeStamp: .zero, duration: .invalid, frameProperties: nil, infoFlagsOut: nil) { status, _, sample in
            defer { done.fulfill() }
            guard status == noErr, let sample, let format = CMSampleBufferGetFormatDescription(sample), let block = CMSampleBufferGetDataBuffer(sample) else { return }
            let code = Data([0, 0, 0, 1])
            for index in 0..<2 {
                var pointer: UnsafePointer<UInt8>?
                var size = 0
                guard CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: index, parameterSetPointerOut: &pointer, parameterSetSizeOut: &size,
                                                                         parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil) == noErr, let pointer else { return }
                stream += code + Data(bytes: pointer, count: size)
            }
            var length = 0
            var bytes: UnsafeMutablePointer<CChar>?
            guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &bytes) == noErr, let bytes else { return }
            let all = Data(bytes: bytes, count: length)
            // Units come with their length in front; the stream wants start codes.
            var offset = 0
            while offset + 4 <= all.count {
                let size = Int(all[offset]) << 24 | Int(all[offset + 1]) << 16 | Int(all[offset + 2]) << 8 | Int(all[offset + 3])
                guard size > 0, offset + 4 + size <= all.count else { break }
                stream += code + all.subdata(in: (offset + 4)..<(offset + 4 + size))
                offset += 4 + size
            }
        }
        guard status == noErr else { throw XCTSkip("the encoder would not take a frame") }
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
        wait(for: [done], timeout: 10)
        guard !stream.isEmpty else { throw XCTSkip("the encoder gave nothing") }
        return stream
    }

    func waitUntil(timeout: TimeInterval, _ condition: @escaping () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    final class Sizes: @unchecked Sendable {
        private let lock = NSLock()
        private var list: [[Int]] = []
        func add(_ size: [Int]) { lock.withLock { list.append(size) } }
        var all: [[Int]] { lock.withLock { list } }
    }

    func testThePacingClockFollowsTheFramesWithoutRushingThem() {
        var pacer = FramePacer()
        pacer.span = 10
        // The first frame sets the clock a little behind it.
        XCTAssertEqual(try XCTUnwrap(pacer.place(capture: 100.0, clock: 0)), 100.0 - pacer.delay, accuracy: 1e-9)
        // A steady stream with the room it should have: the clock is left alone.
        var clock = 100.0 - pacer.delay
        for frame in 1...30 {
            let capture = 100.0 + Double(frame) / 60
            clock = capture - (pacer.target + 0.002)
            XCTAssertNil(pacer.place(capture: capture, clock: clock))
        }
        // Frames start coming late: the clock is held back at once, by as much as needed.
        var setting: Double?
        for frame in 31...40 {
            let capture = 100.0 + Double(frame) / 60
            clock = capture + 0.004
            if let new = pacer.place(capture: capture, clock: clock) { setting = new }
        }
        XCTAssertEqual(try XCTUnwrap(setting) - clock, -(0.004 + pacer.target), accuracy: 1e-9)
        XCTAssertGreaterThan(pacer.late, 0)
        // Frames come with far more room than needed: the clock moves closer, half the way.
        setting = nil
        for frame in 41...50 {
            let capture = 100.0 + Double(frame) / 60
            clock = capture - 0.050
            if let new = pacer.place(capture: capture, clock: clock) { setting = new }
        }
        XCTAssertEqual(try XCTUnwrap(setting) - clock, (0.050 - pacer.target) / 2, accuracy: 1e-9)
        // The phone's clock jumps (a new stream): the clock starts afresh.
        XCTAssertEqual(try XCTUnwrap(pacer.place(capture: 5_000, clock: clock)), 5_000 - pacer.delay, accuracy: 1e-9)
    }

    /// 2026-10-16: the phone does not send lost video again, and holding everything after a
    /// loss until a whole picture came stalled animations. Frames go on being drawn.
    @MainActor
    func testAFrameAfterAMissingOneIsDrawnNotHeldBack() async throws {
        let video = ScreenVideo()
        video.show(NanoVideoFrame(id: 1, timestamp: 0, isKeyframe: true, data: try keyframe(width: 360, height: 800)))
        let first = await waitUntil(timeout: 5) { video.counts().shown == 1 }
        XCTAssertTrue(first)
        // Frames 2 to 4 never came; frame 5 builds on them.
        video.show(NanoVideoFrame(id: 5, timestamp: 64_000, isKeyframe: false, data: Data([0, 0, 0, 1, 0x41, 0x9A, 0x02, 0x0C, 0x80])))
        let drawn = await waitUntil(timeout: 5) { video.counts().shown == 2 }
        XCTAssertTrue(drawn)
        XCTAssertEqual(video.counts().held, 0)
        XCTAssertEqual(video.counts().pastGaps, 1)
    }

    @MainActor
    func testARealStreamIsShownFollowedThroughAChangeOfSizeAndReadBack() async throws {
        let upright = try keyframe(width: 360, height: 800), lying = try keyframe(width: 800, height: 360)
        XCTAssertNotNil(ScreenVideo.description(of: H264.units(in: upright)), "the encoder's parameter sets describe a picture")
        let video = ScreenVideo()
        // In a window, as in the app: the system keeps the displayed picture only for a layer it draws.
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 400), styleMask: [.borderless], backing: .buffered, defer: false)
        let view = MirrorNSView(frame: NSRect(x: 0, y: 0, width: 400, height: 400))
        window.contentView = view
        view.attach(video.layer)
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        let sizes = Sizes()
        video.whenPictureSizeChanges { width, height in sizes.add([width, height]) }
        video.show(NanoVideoFrame(id: 1, timestamp: 0, isKeyframe: true, data: upright))
        let shown = await waitUntil(timeout: 5) { video.counts().shown == 1 }
        XCTAssertTrue(shown)
        XCTAssertEqual(sizes.all, [], "the first size is the one the phone announced")
        // The phone was turned: the stream goes on with pictures of another shape.
        video.show(NanoVideoFrame(id: 2, timestamp: 16_000, isKeyframe: true, data: lying))
        let followed = await waitUntil(timeout: 5) { sizes.all == [[800, 360]] }
        XCTAssertTrue(followed, "the new size is told once")
        XCTAssertEqual(video.counts().shown, 2)
        // What is on show can be read back, where the system allows it.
        var image: CGImage?
        // The picture on show lags the stream by a frame or two: wait for the new shape.
        for _ in 0..<60 where image?.width != 800 {
            image = video.currentImage()
            if image?.width != 800 { try await Task.sleep(for: .milliseconds(50)) }
        }
        guard let image else { throw XCTSkip("the system hands over no displayed picture while the display sleeps") }
        XCTAssertEqual([image.width, image.height], [800, 360])
        let turned = try XCTUnwrap(ScreenShots.turned(image, turns: 1))
        XCTAssertEqual([turned.width, turned.height], [360, 800])
        XCTAssertNotNil(ScreenShots.png(turned))
    }
}
