import Foundation

// What a receiver tells the sender about the packets it got, as the phone's own receiving half
// does it (`protocol/specs/nano-wire-notes.md`, section 13):
//
// - A plain acknowledgement covers everything up to the number it names, so it only ever names
//   the last packet below the first missing one.
// - While a packet is missing, the receiver sends an acknowledgement vector instead: which of
//   the numbers from the first missing one up to the newest have arrived.
// - The sender sends lost content again under new numbers and says, in its "ack of acks", below
//   which number nothing is outstanding any more; the receiver stops waiting for those.

extension NanoRateHeader.AckVector {
    /// The most coded bytes a vector may carry.
    static let codedLimit = 21
    /// The most packets a vector can describe: every coded byte a full run.
    static let elementLimit = codedLimit * 63

    /// Codes the state of consecutive packets, true for "arrived", lowest number first.
    ///
    /// Eight or more equal states in a row become run bytes (bit 7 set, bit 6 the state, the
    /// length below); anything else goes seven to a bitmap byte, lowest number in bit 0. The
    /// result is cut at the limit, and then ends on a packet that arrived where it can.
    /// - Returns: The bytes and how many packets they describe.
    static func code(_ elements: [Bool]) -> (coded: [UInt8], count: Int) {
        var bytes: [UInt8] = []
        var index = 0
        while index < elements.count, bytes.count < codedLimit {
            let state = elements[index]
            var run = 1
            while index + run < elements.count, elements[index + run] == state { run += 1 }
            if run >= 8 {
                while run >= 8, bytes.count < codedLimit {
                    let taken = min(63, run)
                    bytes.append(0x80 | (state ? 0x40 : 0) | UInt8(taken))
                    run -= taken
                    index += taken
                }
                continue
            }
            let taken = min(7, elements.count - index)
            var byte: UInt8 = 0
            for bit in 0..<taken where elements[index + bit] { byte |= 1 << UInt8(bit) }
            bytes.append(byte)
            index += taken
        }
        if index < elements.count {
            // Cut short: a tail of missing packets says nothing the next vector will not say.
            var trimmed = bytes
            while let last = trimmed.last, last == 0 || last & 0xC0 == 0x80 { trimmed.removeLast() }
            if !trimmed.isEmpty { bytes = trimmed }
        }
        return (bytes, elementCount(of: bytes))
    }

    /// How many packets coded bytes describe. A final bitmap byte without its top bit ends
    /// at its highest set bit.
    static func elementCount(of coded: [UInt8]) -> Int {
        var count = 0
        for (position, byte) in coded.enumerated() {
            if byte & 0x80 != 0 {
                count += Int(byte & 0x3F)
            } else if position == coded.count - 1, byte < 0x40 {
                count += 8 - byte.leadingZeroBitCount
            } else {
                count += 7
            }
        }
        return count
    }

    /// The state of each packet from the base sequence number upwards, true for "arrived".
    var elements: [Bool] {
        var states: [Bool] = []
        for (position, byte) in coded.enumerated() {
            if byte & 0x80 != 0 {
                states.append(contentsOf: repeatElement(byte & 0x40 != 0, count: Int(byte & 0x3F)))
            } else {
                let bits = position == coded.count - 1 && byte < 0x40 ? 8 - byte.leadingZeroBitCount : 7
                for bit in 0..<bits { states.append(byte & (1 << UInt8(bit)) != 0) }
            }
        }
        return states
    }
}

/// The receiving half's book of sequence numbers: which arrived, what to acknowledge next,
/// and what is missing. Times are microseconds on the connection's own clock.
struct NanoInbound {
    enum Arrival: Equatable {
        /// Not seen before, at or above the first missing number.
        case new
        /// Below the first missing number: given up earlier, or a repeat.
        case late
        /// Already held above a missing one.
        case repeated
    }

    /// What tells one vector from the next: the phone treats a second vector with the same
    /// three values as "everything missing in it is lost".
    struct Signature: Equatable {
        var base: UInt64
        var count: Int
        var arrived: Int
    }

    /// The lowest number that has not arrived. Numbers are carried on from the wire's 16 bits.
    private(set) var next: UInt64
    /// `next` as of the last acknowledgement built.
    private(set) var acknowledged: UInt64
    /// The highest number that arrived, or `next - 1`.
    private(set) var highest: UInt64
    /// The numbers above `next` that arrived.
    private var above: Set<UInt64> = []
    private var times: [UInt64: Int64] = [:]
    private var late: [(number: UInt64, time: Int64)] = []
    /// Numbers the sender gave up, and in how many steps: for the log.
    private(set) var abandoned = 0, jumps = 0

    init(first: UInt16) {
        // A lap above zero, so that a number just below the start still has a place.
        next = 0x1_0000 + UInt64(first)
        acknowledged = next
        highest = next - 1
    }

    var hasHole: Bool { next <= highest }
    /// Numbers between the first missing one and the newest that have not arrived.
    var missing: Int { hasHole ? Int(highest - next) + 1 - above.count : 0 }

    private func extended(_ short: UInt16) -> UInt64 {
        let reference = max(next, highest)
        let candidate = (reference & ~0xFFFF) | UInt64(short)
        if candidate > reference + 0x8000 { return candidate - 0x1_0000 }
        if candidate + 0x8000 < reference { return candidate + 0x1_0000 }
        return candidate
    }

    /// The sender's "ack of acks": nothing below this number is outstanding any more. What has
    /// not arrived below it never will under that number.
    /// - Returns: How many numbers were given up.
    @discardableResult
    mutating func noteAckOfAcks(_ short: UInt16) -> Int {
        let limit = extended(short)
        // A value far ahead of everything seen is not believed.
        guard limit > next, limit <= max(next, highest) + 0x4000 else {
            if limit > acknowledged, limit <= next { acknowledged = limit }
            return 0
        }
        var given = 0
        for number in next..<limit {
            if above.remove(number) == nil { given += 1 }
            times[number] = nil
        }
        next = limit
        while above.remove(next) != nil { next += 1 }
        acknowledged = max(acknowledged, limit)
        highest = max(highest, next - 1)
        abandoned += given
        jumps += 1
        return given
    }

    mutating func noteData(_ short: UInt16, at time: Int64) -> Arrival {
        let number = extended(short)
        if number < next {
            if late.count < 32 { late.append((number, time)) }
            return .late
        }
        if number == next {
            times[number] = time
            next += 1
            while above.remove(next) != nil { next += 1 }
            highest = max(highest, next - 1)
            return .new
        }
        guard above.insert(number).inserted else { return .repeated }
        times[number] = time
        highest = max(highest, number)
        return .new
    }

    /// The acknowledgement owed, if any: for the last packet below the first missing one, with
    /// the arrival gaps of up to fifteen before it; failing that, for one late packet alone.
    mutating func takeAck(at now: Int64) -> NanoRateHeader.Ack? {
        if next != acknowledged {
            let newest = next - 1
            let from = acknowledged
            acknowledged = next
            defer { for number in from..<next { times[number] = nil } }
            guard let stamp = times[newest] else { return nil }
            var differences: [Int64] = []
            var later = stamp
            var number = newest
            while number > from, differences.count < 15, let time = times[number - 1] {
                differences.append(max(0, later - time) / 4)
                later = time
                number -= 1
            }
            // The differences are one byte each; a scale shifts them all when one does not fit.
            var scale: UInt8 = 0
            while scale < 15, differences.contains(where: { $0 >> Int64(scale) > 255 }) { scale += 1 }
            return NanoRateHeader.Ack(sequence: UInt16(truncatingIfNeeded: newest), timestamp: NanoInbound.stamp(stamp), timeGap: NanoInbound.gap(from: stamp, to: now),
                                      timeScale: scale, delayedTimeDifferences: differences.map { UInt8(truncatingIfNeeded: min(255, $0 >> Int64(scale))) })
        }
        guard !late.isEmpty else { return nil }
        let entry = late.removeFirst()
        return NanoRateHeader.Ack(sequence: UInt16(truncatingIfNeeded: entry.number), timestamp: NanoInbound.stamp(entry.time), timeGap: NanoInbound.gap(from: entry.time, to: now),
                                  timeScale: 0, delayedTimeDifferences: [])
    }

    /// While something is missing: the vector from the first missing number to the newest.
    func vector(at now: Int64) -> (vector: NanoRateHeader.AckVector, signature: Signature)? {
        guard hasHole else { return nil }
        let span = Int(min(highest - next + 1, UInt64(NanoRateHeader.AckVector.elementLimit)))
        var elements = [Bool](repeating: false, count: span)
        for index in 1..<max(1, span) where above.contains(next + UInt64(index)) { elements[index] = true }
        let (coded, count) = NanoRateHeader.AckVector.code(elements)
        let arrived = elements.prefix(count).reduce(0) { $0 + ($1 ? 1 : 0) }
        var vector = NanoRateHeader.AckVector(baseSequence: UInt16(truncatingIfNeeded: next), timestamp: nil, timeGap: nil, coded: coded)
        // The arrival time of the newest packet goes with a vector that reaches it.
        if UInt64(count) == highest - next + 1, let stamp = times[highest] {
            vector.timestamp = NanoInbound.stamp(stamp)
            vector.timeGap = NanoInbound.gap(from: stamp, to: now)
        }
        return (vector, Signature(base: next, count: count, arrived: arrived))
    }

    /// 24 bits of 4-microsecond units.
    private static func stamp(_ time: Int64) -> UInt32 { UInt32(truncatingIfNeeded: time / 4) & 0xFF_FFFF }
    /// Milliseconds between arrival and sending, one byte.
    private static func gap(from time: Int64, to now: Int64) -> UInt8 { UInt8(clamping: max(0, now - time) / 1000) }
}
