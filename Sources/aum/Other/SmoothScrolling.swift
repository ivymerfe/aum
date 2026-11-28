import CoreGraphics
import Foundation
import QuartzCore
import os

final class SmoothScrolling: @unchecked Sendable {
  static let shared = SmoothScrolling()

  private static let fps = 360.0
  private static let maxInstantRate = 50.0
  private static let rateTau = 0.08
  private static let idleDecayTau = 0.12

  private var lastTickTime: [Double?] = [nil, nil]
  private var smoothedEventRate = [0.0, 0.0]
  private var lastSign = [0.0, 0.0]
  private var flags = CGEventFlags()

  private var trackpadMomentum = false
  private var momentumKilled = false

  private let lock = OSAllocatedUnfairLock()
  private let wake = DispatchSemaphore(value: 0)
  private var thread: Thread?
  private var running = false
  private var startTime = 0.0
  private var lastStep = 0.0

  private static func getDelta(rate: Double) -> Double {
    return 30 * pow(2, rate / 6)
  }

  private struct Impulse {
    var start: Double
    var delta: Double
    var done: Double
    var duration: Double
  }
  private static let minDuration = 0.20
  private static let maxDuration = 0.40

  private static func getDuration(delta: Double) -> Double {
    let n = min(sqrt(abs(delta) / 3000), 1)
    return maxDuration + (minDuration - maxDuration) * n
  }

  private var impulses: [[Impulse]] = [[], []]
  private var acc = [0.0, 0.0]

  private static func shape(_ u: Double) -> Double {
    let w = 0.6 * (1 - (1 - u) * (1 - u)) + 0.4 * u
    return w * w * (3 - 2 * w)
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
        impulses[i].removeAll(keepingCapacity: true)
        acc[i] = 0
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

      let delta = -sign * Self.getDelta(rate: smoothedEventRate[i])
      impulses[i].append(
        Impulse(start: now, delta: delta, done: 0, duration: Self.getDuration(delta: delta)))
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
        let now = mach_absolute_time()
        if now > next + period { next = now }
        if step() { break }
      }
    }
  }

  private func step() -> Bool {
    lock.lock()
    let now = CACurrentMediaTime()
    var o0: Int32 = 0
    var o1: Int32 = 0
    for i in 0..<2 {
      var j = 0
      while j < impulses[i].count {
        let u = min((now - impulses[i][j].start) / impulses[i][j].duration, 1)
        let k = Self.shape(u)
        acc[i] += impulses[i][j].delta * (k - impulses[i][j].done)
        impulses[i][j].done = k
        if u >= 1 {
          impulses[i].remove(at: j)
        } else {
          j += 1
        }
      }
      let whole = acc[i].rounded(.towardZero)
      acc[i] -= whole
      if i == 0 { o0 = Int32(whole) } else { o1 = Int32(whole) }
      if impulses[i].isEmpty { acc[i] = 0 }
    }
    let f = flags
    let idle = impulses[0].isEmpty && impulses[1].isEmpty
    if idle { running = false }
    lock.unlock()

    if o0 != 0 || o1 != 0,
      let e = CGEvent(
        scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
        wheel1: o0, wheel2: o1, wheel3: 0)
    {
      e.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
      e.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: Double(o0) / 10)
      e.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: Double(o1) / 10)
      e.flags = f
      markSynthetic(e)
      e.post(tap: .cghidEventTap)
    }
    return idle
  }

  private func cancel() {
    impulses[0].removeAll(keepingCapacity: true)
    impulses[1].removeAll(keepingCapacity: true)
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
