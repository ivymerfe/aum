import CoreGraphics
import Foundation

@MainActor final class BetterMouseScrolling {
  static let shared = BetterMouseScrolling()

  private static let linesPerTick: Int64 = 3
  private static let pixelsPerLine: Int64 = 10

  private static let axes: [(CGEventField, CGEventField, CGEventField)] = [
    (
      .scrollWheelEventDeltaAxis1, .scrollWheelEventPointDeltaAxis1,
      .scrollWheelEventFixedPtDeltaAxis1
    ),
    (
      .scrollWheelEventDeltaAxis2, .scrollWheelEventPointDeltaAxis2,
      .scrollWheelEventFixedPtDeltaAxis2
    ),
  ]

  func handleEvent(type: CGEventType, event: CGEvent) -> Bool {
    guard Config.shared.betterMouseScrolling else { return false }
    guard type == .scrollWheel else { return false }
    guard event.getIntegerValueField(.scrollWheelEventIsContinuous) == 0 else { return false }
    guard event.getIntegerValueField(.scrollWheelEventScrollPhase) == 0,
      event.getIntegerValueField(.scrollWheelEventMomentumPhase) == 0
    else { return false }

    for (deltaField, pointField, fixedField) in Self.axes {
      let d = event.getIntegerValueField(deltaField)
      let f = event.getDoubleValueField(fixedField)
      let sign: Int64 = d != 0 ? (d > 0 ? 1 : -1) : (f > 0 ? 1 : (f < 0 ? -1 : 0))
      guard sign != 0 else { continue }

      let lines = -sign * Self.linesPerTick
      event.setIntegerValueField(deltaField, value: lines)
      event.setIntegerValueField(pointField, value: lines * Self.pixelsPerLine)
      event.setDoubleValueField(fixedField, value: Double(lines))
    }
    return false
  }
}
