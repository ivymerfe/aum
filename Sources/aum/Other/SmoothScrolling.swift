import CoreGraphics
import Foundation
import QuartzCore

@MainActor final class SmoothScrolling {
  static let shared = SmoothScrolling()

  private static let omega = 35.0
  private static let zeta = 1.3

  private static let window = 0.25

  private var remaining = [0.0, 0.0]
  private var velocity = [0.0, 0.0]
  private var carry = [0.0, 0.0]
  private var history: [[Double]] = [[], []]
  private var lastSign = [0.0, 0.0]
  private var flags = CGEventFlags()

  private var trackpadMomentum = false
  private var momentumKilled = false

  private static let fps = 227.0
  private var lastTime = 0.0
  private var timer: Timer?

  private static func speed(for r: Double) -> Double {
    return max(200, r / 0.09)
  }

  private static func getDelta(rate: Double) -> Double {
    return 120 + 40 * floor(pow(1.175, max(0, rate - 4)) - 1)
  }

  func handleEvent(type: CGEventType, event: CGEvent) -> Bool {
    guard Config.shared.smoothScrolling, type == .scrollWheel else { return false }
    let phase = event.getIntegerValueField(.scrollWheelEventScrollPhase)
    let momentum = event.getIntegerValueField(.scrollWheelEventMomentumPhase)
    let isContinuous = event.getIntegerValueField(.scrollWheelEventIsContinuous) != 0

    if isContinuous || phase != 0 || momentum != 0 {
      if momentum != 0 {
        if momentumKilled {
          if momentum == 3 { momentumKilled = false }
          return true
        }
        trackpadMomentum = momentum != 3
        return false
      }
      if phase == 1 || phase == 128 {
        momentumKilled = false
        trackpadMomentum = false
        cancel()
      }
      return false
    }

    if trackpadMomentum { stopMomentum() }

    let fields: [(CGEventField, CGEventField)] = [
      (.scrollWheelEventDeltaAxis1, .scrollWheelEventFixedPtDeltaAxis1),
      (.scrollWheelEventDeltaAxis2, .scrollWheelEventFixedPtDeltaAxis2),
    ]
    let now = CACurrentMediaTime()
    var any = false
    for (i, (deltaField, fixedField)) in fields.enumerated() {
      let d = event.getIntegerValueField(deltaField)
      let f = event.getDoubleValueField(fixedField)
      let sign: Double = d != 0 ? (d > 0 ? 1 : -1) : (f > 0 ? 1 : (f < 0 ? -1 : 0))
      guard sign != 0 else { continue }

      if sign != lastSign[i] { history[i].removeAll() }
      lastSign[i] = sign
      history[i].append(now)
      history[i].removeAll { now - $0 > Self.window }

      let rate = Double(history[i].count) / Self.window
      remaining[i] += -sign * Self.getDelta(rate: rate)
      any = true
    }
    if any {
      flags = event.flags
      start()
    }
    return true
  }

  private func start() {
    guard timer == nil else { return }
    lastTime = CACurrentMediaTime()
    let t = Timer(timeInterval: 1 / Self.fps, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { self?.step() }
    }
    RunLoop.main.add(t, forMode: .common)
    timer = t
  }

  private func stopTimer() {
    timer?.invalidate()
    timer = nil
  }

  private func step() {
    let dt = 1.0 / Self.fps

    var out = [Int32(0), Int32(0)]
    for i in 0..<2 {
      if abs(remaining[i]) + abs(carry[i]) < 20 {
        remaining[i] = 0
        carry[i] = 0
        continue
      }
      let r = abs(remaining[i])
      let dir: Double = remaining[i] < 0 ? -1 : 1
      let s = min(r, Self.speed(for: r) * dt) * dir
      remaining[i] -= s
      carry[i] += s
      let whole = carry[i].rounded(.towardZero)
      carry[i] -= whole
      out[i] = Int32(whole)
    }

    if out[0] != 0 || out[1] != 0,
      let e = CGEvent(
        scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
        wheel1: out[0], wheel2: out[1], wheel3: 0)
    {
      e.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
      e.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: Double(out[0]) / 10)
      e.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: Double(out[1]) / 10)
      e.flags = flags
      markSynthetic(e)
      e.post(tap: .cghidEventTap)
    }

    if remaining.allSatisfy({ $0 == 0 }) {
      carry = [0, 0]
      stopTimer()
    }
  }

  private func cancel() {
    remaining = [0, 0]
    carry = [0, 0]
    history = [[], []]
    stopTimer()
  }

  private func stopMomentum() {
    trackpadMomentum = false
    momentumKilled = true
    postPhase(scroll: 0, momentum: 3)
    postPhase(scroll: 1, momentum: 0)
    postPhase(scroll: 4, momentum: 0)
  }

  private func postPhase(scroll: Int64, momentum: Int64) {
    guard
      let e = CGEvent(
        scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
        wheel1: 0, wheel2: 0, wheel3: 0)
    else { return }
    e.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
    e.setIntegerValueField(.scrollWheelEventScrollPhase, value: scroll)
    e.setIntegerValueField(.scrollWheelEventMomentumPhase, value: momentum)
    markSynthetic(e)
    e.post(tap: .cghidEventTap)
  }
}
