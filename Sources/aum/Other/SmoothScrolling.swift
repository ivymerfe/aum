import CoreGraphics
import Foundation
import QuartzCore

final class SmoothScrolling: @unchecked Sendable {
  static let shared = SmoothScrolling()

  private static let fps = 360.0
  private static let maxInstantRate = 50.0
  private static let rateTau = 0.08
  private static let idleDecayTau = 0.12
  private static let targetTau = 0.06

  private var pending = [0.0, 0.0]
  private var remaining = [0.0, 0.0]
  private var velocity = [0.0, 0.0]
  private var acc = [0.0, 0.0]
  private var omega = [0.0, 0.0]

  private var lastTickTime: [Double?] = [nil, nil]
  private var smoothedEventRate = [0.0, 0.0]
  private var lastSign = [0.0, 0.0]
  private var flags = CGEventFlags()

  private var trackpadMomentum = false
  private var momentumKilled = false

  private let lock = NSLock()
  private let wake = DispatchSemaphore(value: 0)
  private var thread: Thread?
  private var running = false
  private var startTime = 0.0
  private var lastStep = 0.0

  private static func getDelta(rate: Double) -> Double {
    let t = min(max((rate - 20) / 12, 0), 1)
    return 100 * pow(16, t)
  }

  private static func getOmega(rate: Double) -> Double {
    let alpha = min(1, max(0, rate - 4) / 12)
    return 40.0 * alpha + 12.0 * (1 - alpha)
  }

  func handleEvent(type: CGEventType, event: CGEvent) -> Bool {
    let enabled = MainActor.assumeIsolated { Config.shared.smoothScrolling }
    guard enabled, type == .scrollWheel else { return false }
    lock.lock()
    defer { lock.unlock() }

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
        remaining[i] = 0
        velocity[i] = 0
        acc[i] = 0
        pending[i] = 0
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

      pending[i] -= sign * Self.getDelta(rate: smoothedEventRate[i])
      omega[i] = Self.getOmega(rate: smoothedEventRate[i])
      any = true
    }
    if any {
      flags = event.flags
      start()
    }
    return true
  }

  private func start() {
    guard !running else { return }
    running = true
    startTime = CACurrentMediaTime()
    lastStep = startTime
    if thread == nil {
      let t = Thread { [weak self] in self?.loop() }
      t.qualityOfService = .userInteractive
      thread = t
      t.start()
    }
    wake.signal()
  }

  private func loop() {
    var tb = mach_timebase_info_data_t()
    mach_timebase_info(&tb)
    let period = UInt64(1e9 / Self.fps) * UInt64(tb.denom) / UInt64(tb.numer)
    var policy = thread_time_constraint_policy_data_t(
      period: UInt32(period),
      computation: UInt32(period / 4),
      constraint: UInt32(period / 2),
      preemptible: 1)
    let count = mach_msg_type_number_t(
      MemoryLayout<thread_time_constraint_policy_data_t>.size / MemoryLayout<integer_t>.size)
    withUnsafeMutablePointer(to: &policy) {
      $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
        _ = thread_policy_set(
          mach_thread_self(), thread_policy_flavor_t(THREAD_TIME_CONSTRAINT_POLICY), $0, count)
      }
    }
    while true {
      wake.wait()
      var next = mach_absolute_time()
      while true {
        next += period
        mach_wait_until(next)
        if step() { break }
      }
    }
  }

  private func step() -> Bool {
    lock.lock()
    let dt = 1.0 / Self.fps
    let kt = 1.0 - exp(-dt / Self.targetTau)

    var out = [Int32(0), Int32(0)]
    for i in 0..<2 {
      if remaining[i] == 0 && velocity[i] == 0 && pending[i] == 0 { continue }

      let shift = pending[i] * kt
      pending[i] -= shift
      remaining[i] += shift
      if abs(pending[i]) < 0.5 {
        remaining[i] += pending[i]
        pending[i] = 0
      }

      let w = omega[i]
      let decay = exp(-w * dt)
      let x0 = -remaining[i]
      let c = velocity[i] + w * x0
      let x = (x0 + c * dt) * decay
      velocity[i] = (velocity[i] - w * c * dt) * decay
      remaining[i] = -x
      acc[i] += x - x0

      let whole = acc[i].rounded(.towardZero)
      acc[i] -= whole
      out[i] = Int32(whole)

      if abs(remaining[i]) < 0.5 && abs(velocity[i]) < 5 && pending[i] == 0 {
        remaining[i] = 0
        velocity[i] = 0
        acc[i] = 0
      }
    }
    let f = flags
    let idle = remaining[0] == 0 && remaining[1] == 0 && pending[0] == 0 && pending[1] == 0
    if idle { running = false }
    lock.unlock()

    if out[0] != 0 || out[1] != 0,
      let e = CGEvent(
        scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
        wheel1: out[0], wheel2: out[1], wheel3: 0)
    {
      e.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
      e.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: Double(out[0]) / 10)
      e.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: Double(out[1]) / 10)
      e.flags = f
      markSynthetic(e)
      e.post(tap: .cghidEventTap)
    }
    return idle
  }

  private func cancel() {
    remaining = [0, 0]
    pending = [0, 0]
    velocity = [0, 0]
    acc = [0, 0]
    lastTickTime = [nil, nil]
    smoothedEventRate = [0.0, 0.0]
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
