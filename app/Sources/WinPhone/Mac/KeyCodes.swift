import Carbon.HIToolbox

/// Keys of the Mac's keyboard as the numbers the mirrored phone takes: the usage numbers of
/// a USB keyboard.
enum KeyCodes {
    /// By the Mac's virtual key code. Command is given as Control, so that the shortcuts in
    /// the fingers (copy, paste, select all) do on the phone what they do here.
    static let usage: [Int: UInt8] = [
        kVK_ANSI_A: 0x04, kVK_ANSI_B: 0x05, kVK_ANSI_C: 0x06, kVK_ANSI_D: 0x07, kVK_ANSI_E: 0x08, kVK_ANSI_F: 0x09, kVK_ANSI_G: 0x0A, kVK_ANSI_H: 0x0B,
        kVK_ANSI_I: 0x0C, kVK_ANSI_J: 0x0D, kVK_ANSI_K: 0x0E, kVK_ANSI_L: 0x0F, kVK_ANSI_M: 0x10, kVK_ANSI_N: 0x11, kVK_ANSI_O: 0x12, kVK_ANSI_P: 0x13,
        kVK_ANSI_Q: 0x14, kVK_ANSI_R: 0x15, kVK_ANSI_S: 0x16, kVK_ANSI_T: 0x17, kVK_ANSI_U: 0x18, kVK_ANSI_V: 0x19, kVK_ANSI_W: 0x1A, kVK_ANSI_X: 0x1B,
        kVK_ANSI_Y: 0x1C, kVK_ANSI_Z: 0x1D,
        kVK_ANSI_1: 0x1E, kVK_ANSI_2: 0x1F, kVK_ANSI_3: 0x20, kVK_ANSI_4: 0x21, kVK_ANSI_5: 0x22, kVK_ANSI_6: 0x23, kVK_ANSI_7: 0x24, kVK_ANSI_8: 0x25,
        kVK_ANSI_9: 0x26, kVK_ANSI_0: 0x27,
        kVK_Return: 0x28, kVK_Escape: 0x29, kVK_Delete: 0x2A, kVK_Tab: 0x2B, kVK_Space: 0x2C,
        kVK_ANSI_Minus: 0x2D, kVK_ANSI_Equal: 0x2E, kVK_ANSI_LeftBracket: 0x2F, kVK_ANSI_RightBracket: 0x30, kVK_ANSI_Backslash: 0x31,
        kVK_ANSI_Semicolon: 0x33, kVK_ANSI_Quote: 0x34, kVK_ANSI_Grave: 0x35, kVK_ANSI_Comma: 0x36, kVK_ANSI_Period: 0x37, kVK_ANSI_Slash: 0x38,
        kVK_CapsLock: 0x39,
        kVK_F1: 0x3A, kVK_F2: 0x3B, kVK_F3: 0x3C, kVK_F4: 0x3D, kVK_F5: 0x3E, kVK_F6: 0x3F, kVK_F7: 0x40, kVK_F8: 0x41, kVK_F9: 0x42, kVK_F10: 0x43,
        kVK_F11: 0x44, kVK_F12: 0x45,
        kVK_Home: 0x4A, kVK_PageUp: 0x4B, kVK_ForwardDelete: 0x4C, kVK_End: 0x4D, kVK_PageDown: 0x4E,
        kVK_RightArrow: 0x4F, kVK_LeftArrow: 0x50, kVK_DownArrow: 0x51, kVK_UpArrow: 0x52,
        kVK_ANSI_KeypadEnter: 0x58,
        kVK_Control: 0xE0, kVK_Shift: 0xE1, kVK_Option: 0xE2, kVK_Command: 0xE0,
        kVK_RightControl: 0xE4, kVK_RightShift: 0xE5, kVK_RightOption: 0xE6, kVK_RightCommand: 0xE4,
    ]

    /// A character as the key that types it on a US keyboard, and whether Shift is held for
    /// it; nil for what such a keyboard cannot type.
    static func typing(_ character: Character) -> (usage: UInt8, shift: Bool)? {
        guard let scalar = character.unicodeScalars.first, character.unicodeScalars.count == 1, scalar.isASCII else { return nil }
        let value = scalar.value
        switch value {
        case 0x61...0x7A: return (UInt8(0x04 + value - 0x61), false)        // a to z
        case 0x41...0x5A: return (UInt8(0x04 + value - 0x41), true)         // A to Z
        case 0x31...0x39: return (UInt8(0x1E + value - 0x31), false)        // 1 to 9
        case 0x30: return (0x27, false)                                      // 0
        default: break
        }
        let plain: [Character: UInt8] = [" ": 0x2C, "-": 0x2D, "=": 0x2E, "[": 0x2F, "]": 0x30, "\\": 0x31, ";": 0x33, "'": 0x34, "`": 0x35, ",": 0x36, ".": 0x37, "/": 0x38]
        let shifted: [Character: UInt8] = ["!": 0x1E, "@": 0x1F, "#": 0x20, "$": 0x21, "%": 0x22, "^": 0x23, "&": 0x24, "*": 0x25, "(": 0x26, ")": 0x27,
                                           "_": 0x2D, "+": 0x2E, "{": 0x2F, "}": 0x30, "|": 0x31, ":": 0x33, "\"": 0x34, "~": 0x35, "<": 0x36, ">": 0x37, "?": 0x38]
        if let usage = plain[character] { return (usage, false) }
        if let usage = shifted[character] { return (usage, true) }
        return nil
    }
}
