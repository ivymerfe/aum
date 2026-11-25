import CoreGraphics
import Foundation
import QuartzCore

@MainActor final class SmoothScrolling {
  static let shared = SmoothScrolling()

  private static let fps = 280.0
  private static let maxInstantRate = 50.0
  private static let rateTau = 0.08
  private static let idleDecayTau = 0.12
  private static let followSpeed = 14.0

  private var timer: Timer?
  private var remaining = [0.0, 0.0]
  private var carry = [0.0, 0.0]
  private var lastTickTime: [Double?] = [nil, nil]
  private var smoothedEventRate = [0.0, 0.0]
  private var speed = [0.0, 0.0]

  private var lastSign = [0.0, 0.0]
  private var flags = CGEventFlags()

  private var trackpadMomentum = false
  private var momentumKilled = false

  private static func getDelta(rate: Double) -> Double {
    if rate < 22 {
      return 90
    }
    if rate < 28 {
      return 300
    }
    return 2000
  }

  private static func getDuration(rate: Double) -> Double {
    if rate < 22 {
      return 0.16
    }
    return 0.1
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

      if sign != lastSign[i] {
        lastSign[i] = sign
        lastTickTime[i] = nil
        smoothedEventRate[i] = 0
      }

      let instantRate: Double
      if let prev = lastTickTime[i] {
        let dt = max(now - prev, 1.0 / Self.maxInstantRate)
        smoothedEventRate[i] *= exp(-dt / Self.idleDecayTau)
        instantRate = min(1.0 / dt, Self.maxInstantRate)
      } else {
        instantRate = 1.0
      }
      lastTickTime[i] = now

      let tickDt = 1.0 / max(instantRate, 1.0)
      let alpha = 1.0 - exp(-tickDt / Self.rateTau)
      smoothedEventRate[i] += alpha * (instantRate - smoothedEventRate[i])

      let rate = smoothedEventRate[i]

      let delta = Self.getDelta(rate: rate)
      let duration = Self.getDuration(rate: rate)
      remaining[i] += -sign * delta
      self.speed[i] = remaining[i] / duration
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
      if abs(remaining[i]) + abs(carry[i]) < 1 {
        remaining[i] = 0
        carry[i] = 0
        continue
      }
      var s = speed[i] * dt
      if abs(s) >= abs(remaining[i]) { s = remaining[i] }
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
    lastTickTime = [nil, nil]
    smoothedEventRate = [0.0, 0.0]
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
