import AVFoundation
import XCTest
@testable import WinPhone

/// The phone's sound arrives as Opus packets. These tests make such packets with the
/// system's own encoder and run them through the decoder the app plays sound with.
final class ScreenAudioTests: XCTestCase {
    /// A second of a tone, encoded to Opus packets of the given length.
    func packets(samplesPerPacket: Int, channels: Int = 2) throws -> [Data] {
        let rate = 48_000.0
        let pcm = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: AVAudioChannelCount(channels), interleaved: false))
        var description = AudioStreamBasicDescription(mSampleRate: rate, mFormatID: kAudioFormatOpus, mFormatFlags: 0, mBytesPerPacket: 0, mFramesPerPacket: UInt32(samplesPerPacket),
                                                      mBytesPerFrame: 0, mChannelsPerFrame: UInt32(channels), mBitsPerChannel: 0, mReserved: 0)
        let opus = try XCTUnwrap(AVAudioFormat(streamDescription: &description))
        let encoder = try XCTUnwrap(AVAudioConverter(from: pcm, to: opus))
        let source = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: pcm, frameCapacity: 48_000))
        source.frameLength = 48_000
        for channel in 0..<channels {
            let samples = try XCTUnwrap(source.floatChannelData?[channel])
            for index in 0..<48_000 { samples[index] = sinf(Float(index) * 2 * .pi * 440 / 48_000) * 0.4 }
        }
        var packets: [Data] = []
        var given = false
        for _ in 0..<200 {
            let out = AVAudioCompressedBuffer(format: opus, packetCapacity: 8, maximumPacketSize: 1500)
            var error: NSError?
            let status = encoder.convert(to: out, error: &error) { _, state in
                if given {
                    state.pointee = .endOfStream
                    return nil
                }
                given = true
                state.pointee = .haveData
                return source
            }
            for index in 0..<Int(out.packetCount) {
                let entry = try XCTUnwrap(out.packetDescriptions?[index])
                packets.append(Data(bytes: out.data + Int(entry.mStartOffset), count: Int(entry.mDataByteSize)))
            }
            if status == .endOfStream || status == .error || out.packetCount == 0 { break }
        }
        return packets
    }

    func testOpusPacketsBecomeSound() throws {
        for samples in [960, 1920] {
            let packets = try packets(samplesPerPacket: samples)
            guard packets.count > 10 else { throw XCTSkip("this system's encoder made no packets of \(samples) samples") }
            XCTAssertEqual(OpusDecoder.samples(inPacket: packets[3], sampleRate: 48_000), samples, "the length is read from the packet's first byte")
            let decoder = try XCTUnwrap(OpusDecoder(sampleRate: 48_000, channels: 2, samplesPerPacket: samples))
            var decoded = 0, loudest: Float = 0
            for packet in packets {
                guard let sound = decoder.decode(packet) else { continue }
                decoded += 1
                // The very first packet comes out a little short: the decoder's own lead-in.
                XCTAssertLessThanOrEqual(Int(sound.frameLength), samples)
                if decoded > 1 { XCTAssertEqual(Int(sound.frameLength), samples) }
                if let data = sound.floatChannelData?[0] { for index in 0..<Int(sound.frameLength) { loudest = max(loudest, abs(data[index])) } }
            }
            XCTAssertGreaterThan(decoded, packets.count - 3, "\(samples) samples a packet")
            XCTAssertGreaterThan(loudest, 0.1, "what comes out is the tone, not silence")
        }
    }

    func testThePacketLengthIsReadFromItsFirstByte() {
        // Kinds of frame by the first byte's top five bits; the low two say how many frames.
        XCTAssertEqual(OpusDecoder.samples(inPacket: Data([0xF8, 0xFF, 0xFE]), sampleRate: 48_000), 960, "20 ms, one frame: what a silent stretch looks like")
        XCTAssertEqual(OpusDecoder.samples(inPacket: Data([0xF9, 0, 0]), sampleRate: 48_000), 1920, "two frames of 20 ms")
        XCTAssertEqual(OpusDecoder.samples(inPacket: Data([0x78]), sampleRate: 48_000), 960)
        XCTAssertEqual(OpusDecoder.samples(inPacket: Data([0x10]), sampleRate: 48_000), 1920, "one frame of 40 ms")
        XCTAssertEqual(OpusDecoder.samples(inPacket: Data([0xFB, 0x02]), sampleRate: 48_000), 1920, "a count of frames in the second byte")
        XCTAssertNil(OpusDecoder.samples(inPacket: Data(), sampleRate: 48_000))
        XCTAssertNil(OpusDecoder.samples(inPacket: Data([0xFB]), sampleRate: 48_000))
    }
}
