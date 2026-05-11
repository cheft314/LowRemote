import Foundation

/// macOS CGKeyCode 常量，与 Mac 服务端 InputSimulator 对齐
enum MacKeyCode {
    // 常用字母
    static let c: UInt16    = 8
    static let v: UInt16    = 9
    static let x: UInt16    = 7
    static let z: UInt16    = 6
    static let a: UInt16    = 0
    static let f: UInt16    = 3

    // 功能键
    static let escape: UInt16    = 53
    static let `return`: UInt16  = 36
    static let delete: UInt16    = 51      // Backspace
    static let forwardDelete: UInt16 = 117
    static let tab: UInt16       = 48
    static let space: UInt16     = 49

    // 方向键
    static let leftArrow: UInt16  = 123
    static let rightArrow: UInt16 = 124
    static let downArrow: UInt16  = 125
    static let upArrow: UInt16    = 126

    // 功能 F 键
    static let f1: UInt16 = 122
    static let f2: UInt16 = 120
    static let f3: UInt16 = 99
    static let f4: UInt16 = 118
    static let f5: UInt16 = 96
    static let f11: UInt16 = 103

    // 修饰键
    static let command: UInt16  = 55
    static let shift: UInt16    = 56
    static let option: UInt16   = 58
    static let control: UInt16  = 59
}

/// 修饰键标识符字符串（与 Mac InputSimulator.parseMods 对齐）
enum MacModifier: String {
    case cmd   = "cmd"
    case ctrl  = "ctrl"
    case alt   = "alt"
    case shift = "shift"
}
