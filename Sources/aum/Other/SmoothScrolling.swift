import CoreGraphics
import Foundation
import QuartzCore

@MainActor final class SmoothScrolling {
  static let shared = SmoothScrolling()

  private static let fps = 120.0
  private static let window = 0.4

  private var remaining = [0.0, 0.0]
  private var carry = [0.0, 0.0]
  private var history: [[Double]] = [[], []]
  private var lastSign = [0.0, 0.0]
  private var lastTime = 0.0
  private var timer: Timer?

  private static let baseSpeed = 30.0  // 10*lines
  private static let rateScale = 10.0
  private static let rateExponent = 2.25

  private static func speed(rate: Double) -> Double {
    return baseSpeed * pow(1 + rate / rateScale, rateExponent)
  }

  private var trackpadMomentum = false
  private var momentumKilled = false

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
      remaining[i] += -sign * Self.speed(rate: rate)
      any = true
    }
    if any { start() }
    return true
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

  private func stopMomentum() {
    trackpadMomentum = false
    momentumKilled = true
    postPhase(scroll: 0, momentum: 3)
    postPhase(scroll: 1, momentum: 0)
    postPhase(scroll: 4, momentum: 0)
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

  private static let omega = 30.0
  private static let zeta = 1.1

  private var velocity = [0.0, 0.0]

  private func cancel() {
    remaining = [0, 0]
    velocity = [0, 0]
    carry = [0, 0]
    history = [[], []]
    timer?.invalidate()
    timer = nil
  }

  private func step() {
    let now = CACurrentMediaTime()
    let dt = min(now - lastTime, 0.05)
    lastTime = now

    var out = [Int32(0), Int32(0)]
    for i in 0..<2 {
      let accel = Self.omega * Self.omega * remaining[i] - 2 * Self.zeta * Self.omega * velocity[i]
      velocity[i] += accel * dt
      var s = velocity[i] * dt
      if abs(remaining[i]) < 0.5 && abs(velocity[i]) < 20 {
        s = remaining[i]
        velocity[i] = 0
      }
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
      markSynthetic(e)
      e.post(tap: .cghidEventTap)
    }

    if remaining.allSatisfy({ $0 == 0 }) && carry.allSatisfy({ abs($0) < 1 }) {
      carry = [0, 0]
      velocity = [0, 0]
      timer?.invalidate()
      timer = nil
    }
  }
}
