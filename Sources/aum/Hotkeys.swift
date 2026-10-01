import CoreGraphics

@_silgen_name("SLSSetDisplayRotation")
private func SLSSetDisplayRotation(_ display: CGDirectDisplayID, _ rotation: Int32) -> Int32

@MainActor enum Hotkeys {
    private static let bindings: [Int64: Int32] = [34: 270, 31: 0, 35: 90]
    private static let modifiers: CGEventFlags = [
        .maskAlternate, .maskCommand, .maskControl, .maskShift,
    ]

    static func handle(_ event: CGEvent) -> Bool {
        guard event.flags.intersection(modifiers) == .maskAlternate,
            let degrees = bindings[event.getIntegerValueField(.keyboardEventKeycode)]
        else { return false }
        if event.getIntegerValueField(.keyboardEventAutorepeat) == 0 {
            _ = SLSSetDisplayRotation(CGMainDisplayID(), degrees)
        }
        return true
    }
}
