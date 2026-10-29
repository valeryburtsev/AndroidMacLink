import Foundation

/// The little of H.264 that showing a stream needs: cutting it into its units.
public enum H264 {
    /// Kinds of unit, by the low five bits of a unit's first byte.
    public enum Kind {
        public static let slice: UInt8 = 1
        public static let keySlice: UInt8 = 5
        public static let sequenceParameters: UInt8 = 7
        public static let pictureParameters: UInt8 = 8
    }

    /// The units of a stream in which each begins with a start code (00 00 01, with or
    /// without another 00 in front), without their start codes.
    public static func units(in stream: Data) -> [Data] {
        var units: [Data] = []
        let bytes = [UInt8](stream)
        var index = 0, start: Int?
        while index + 2 < bytes.count {
            if bytes[index] == 0, bytes[index + 1] == 0, bytes[index + 2] == 1 {
                if let begin = start {
                    // A zero just before the code belongs to the code, not to the unit.
                    var end = index
                    if end > begin, bytes[end - 1] == 0 { end -= 1 }
                    if end > begin { units.append(Data(bytes[begin..<end])) }
                }
                start = index + 3
                index += 3
            } else {
                index += 1
            }
        }
        if let begin = start, begin < bytes.count { units.append(Data(bytes[begin...])) }
        return units
    }
}
