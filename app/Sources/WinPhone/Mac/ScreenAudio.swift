import AVFoundation
import WinPhoneCore

/// Plays the phone's sound while its screen is shown: takes the encoded frames as they
/// arrive, decodes them and hands them to the output.
@MainActor
final class ScreenAudio {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var decoder: OpusDecoder?
    private var format: NanoAudioFormat?
    private var attached = false
    private(set) var framesPlayed = 0, failures = 0

    /// Gets ready for a stream in this format. Returns false for a format this cannot play.
    @discardableResult
    func start(_ format: NanoAudioFormat) -> Bool {
        stop()
        // Codec 0 is Opus.
        guard format.codec == 0, format.sampleRate > 0, (1...2).contains(format.channels),
              let output = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(format.sampleRate), channels: AVAudioChannelCount(format.channels), interleaved: false) else { return false }
        self.format = format
        if !attached {
            engine.attach(player)
            attached = true
        }
        engine.connect(player, to: engine.mainMixerNode, format: output)
        do { try engine.start() } catch { return false }
        player.play()
        framesPlayed = 0
        failures = 0
        return true
    }

    /// Decodes one frame and queues it. Returns false when it could not be decoded.
    @discardableResult
    func play(_ frame: Data) -> Bool {
        guard let format, engine.isRunning else { return false }
        // The length of a frame is in its first byte; the decoder is made for that length.
        guard let samples = OpusDecoder.samples(inPacket: frame, sampleRate: Int(format.sampleRate)) else {
            failures += 1
            return false
        }
        if decoder?.samplesPerPacket != samples { decoder = OpusDecoder(sampleRate: Int(format.sampleRate), channels: Int(format.channels), samplesPerPacket: samples) }
        guard let sound = decoder?.decode(frame) else {
            failures += 1
            return false
        }
        player.scheduleBuffer(sound)
        framesPlayed += 1
        return true
    }

    func stop() {
        guard format != nil else { return }
        player.stop()
        engine.stop()
        decoder = nil
        format = nil
    }
}

/// Decodes Opus packets of one length with the system's decoder.
final class OpusDecoder {
    let samplesPerPacket: Int
    private let converter: AVAudioConverter
    private let input: AVAudioFormat
    private let output: AVAudioFormat

    init?(sampleRate: Int, channels: Int, samplesPerPacket: Int) {
        var description = AudioStreamBasicDescription(mSampleRate: Double(sampleRate), mFormatID: kAudioFormatOpus, mFormatFlags: 0, mBytesPerPacket: 0,
                                                      mFramesPerPacket: UInt32(samplesPerPacket), mBytesPerFrame: 0, mChannelsPerFrame: UInt32(channels),
                                                      mBitsPerChannel: 0, mReserved: 0)
        guard let input = AVAudioFormat(streamDescription: &description),
              let output = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(sampleRate), channels: AVAudioChannelCount(channels), interleaved: false),
              let converter = AVAudioConverter(from: input, to: output) else { return nil }
        self.samplesPerPacket = samplesPerPacket
        self.input = input
        self.output = output
        self.converter = converter
    }

    /// How many samples a packet holds, from its first byte: the kind of frame gives the
    /// length of one, and the byte's low bits say how many frames there are.
    static func samples(inPacket packet: Data, sampleRate: Int) -> Int? {
        guard let first = packet.first else { return nil }
        let configuration = Int(first >> 3)
        // In tenths of a millisecond.
        let frame: Int
        switch configuration {
        case 0..<12: frame = [100, 200, 400, 600][configuration % 4]
        case 12..<16: frame = [100, 200][configuration % 2]
        default: frame = [25, 50, 100, 200][configuration % 4]
        }
        let count: Int
        switch first & 3 {
        case 0: count = 1
        case 1, 2: count = 2
        default:
            guard packet.count >= 2 else { return nil }
            count = Int(packet[packet.startIndex + 1] & 0x3F)
        }
        guard count > 0, frame * count <= 1200 else { return nil }
        return sampleRate * frame * count / 10_000
    }

    func decode(_ packet: Data) -> AVAudioPCMBuffer? {
        guard !packet.isEmpty else { return nil }
        let compressed = AVAudioCompressedBuffer(format: input, packetCapacity: 1, maximumPacketSize: packet.count)
        packet.withUnsafeBytes { compressed.data.copyMemory(from: $0.baseAddress!, byteCount: packet.count) }
        compressed.byteLength = UInt32(packet.count)
        compressed.packetCount = 1
        compressed.packetDescriptions?.pointee = AudioStreamPacketDescription(mStartOffset: 0, mVariableFramesInPacket: 0, mDataByteSize: UInt32(packet.count))
        guard let decoded = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: AVAudioFrameCount(samplesPerPacket * 2)) else { return nil }
        var given = false
        var error: NSError?
        let status = converter.convert(to: decoded, error: &error) { _, state in
            if given {
                state.pointee = .noDataNow
                return nil
            }
            given = true
            state.pointee = .haveData
            return compressed
        }
        guard status != .error, decoded.frameLength > 0 else { return nil }
        return decoded
    }
}
