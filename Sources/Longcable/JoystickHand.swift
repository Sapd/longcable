// Copyright 2026 Denis Arnst (Sapd) — https://github.com/Sapd
// Licensed under GPL-3.0-or-later; see LICENSE.
import Foundation

// Presentation only: never use a name heuristic to select or identify physical USB devices.
enum JoystickHand {
    case left, right
    static func detect(in name: String) -> JoystickHand? {
        let tokens = name.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
        guard !(tokens.contains("l") && tokens.contains("r")) else { return nil }
        let left = tokens.contains("left") || tokens.last == "l"
        let right = tokens.contains("right") || tokens.last == "r"
        guard left != right else { return nil }
        return left ? .left : .right
    }
    var symbol: String { self == .left ? "l.joystick" : "r.joystick" }
}
