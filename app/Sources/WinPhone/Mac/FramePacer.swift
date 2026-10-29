import Foundation

/// When each frame of the phone's screen is to be shown. Shown the moment it arrived, the
/// picture moved unevenly at 50 frames a second, since the network delivers frames with
/// uneven gaps. Instead the frames play on a clock of their own that runs a little behind
/// the phone's capture times (`delay`), so that each is shown at the refresh it belongs to.
/// The clock follows: frames arriving late push it back, frames arriving with more room than
/// needed bring it closer. Times are in seconds.
struct FramePacer {
    /// How far behind the phone the picture runs at first.
    var delay = 0.020
    /// The least room the earliest frames of a while should have before they are due.
    var target = 0.006
    /// How many frames a judgement is made on.
    var span = 30
    /// A frame this far from where the clock expects it starts the clock afresh: a new
    /// stream, or the phone's clock jumped.
    var jumpLimit = 1.0

    private var anchored = false
    private var slacks: [Double] = []
    private(set) var late = 0, judged = 0
    private var slackSum = 0.0

    /// Average room a frame had before it was due, for the log.
    var averageSlack: Double { judged > 0 ? slackSum / Double(judged) : 0 }

    mutating func reset() {
        anchored = false
        slacks.removeAll()
    }

    /// A frame captured at `capture` (the phone's clock) arrives while the playing clock
    /// reads `clock`. Returns the reading the playing clock is to be set to, when it is to
    /// change.
    mutating func place(capture: Double, clock: Double) -> Double? {
        let slack = capture - clock
        guard anchored, abs(slack) < jumpLimit else {
            anchored = true
            slacks.removeAll()
            return capture - delay
        }
        judged += 1
        slackSum += slack
        if slack < 0 { late += 1 }
        slacks.append(slack)
        guard slacks.count >= span else { return nil }
        let least = slacks.min() ?? target
        slacks.removeAll()
        // Positive: the clock may move on (less delay); negative: it must hold back (more).
        let shift = least - target
        guard abs(shift) > 0.003 else { return nil }
        // Back at once when frames came late; forward only half the way, to stay calm.
        return clock + (shift < 0 ? shift : shift / 2)
    }
}
