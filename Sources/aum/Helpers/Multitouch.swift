import IOKit
import MultitouchSupport

enum IOKitUtils {
  static func releaseIterator(_ iterator: io_iterator_t) {
    while case let ioService = IOIteratorNext(iterator), ioService != 0 {
      IOObjectRelease(ioService)
    }
  }
}

final class IOMultitouchManager: PointerableObject {
  let deviceAddedCallback: () -> Void
  init(deviceAddedCallback: @escaping () -> Void) {
    self.deviceAddedCallback = deviceAddedCallback
  }

  func setupMultitouchListener() {
    let port = IONotificationPortCreate(kIOMainPortDefault)

    CFRunLoopAddSource(
      CFRunLoopGetCurrent(),
      IONotificationPortGetRunLoopSource(port).takeUnretainedValue(),
      .defaultMode
    )

    var handle: io_iterator_t = 0
    let err = IOServiceAddMatchingNotification(
      port,
      kIOFirstMatchNotification,
      IOServiceMatching("AppleMultitouchDevice"),
      {
        (userData, iterator) in
        IOKitUtils.releaseIterator(iterator)
        IOMultitouchManager.from(pointer: userData).deviceAddedCallback()
      },
      rawPointer,
      &handle
    )

    if err != KERN_SUCCESS {
      print(
        "Failed to register notification for touchpad attach: \(err), will not handle newly attached devices"
      )
      IONotificationPortDestroy(port)
      return
    }

    IOKitUtils.releaseIterator(handle)
  }
}

@_silgen_name("MTDeviceCreateList")
func MTDeviceCreateList() -> Unmanaged<CFMutableArray>?

extension MTDevice {
  public func registerAndStart(_ callback: MTFrameCallbackFunction) {
    self.register(contactFrameCallback: callback)
    self.start(runMode: 0)
  }

  public func unregisterAndStop(_ callback: MTFrameCallbackFunction) {
    self.unregister(contactFrameCallback: callback)
    self.stop()
    self.release()
  }

  public static func createList() -> [MTDevice] {
    return MTDeviceCreateList()?.takeUnretainedValue() as? [MTDevice] ?? []
  }
}

protocol Pointerable: AnyObject {}
extension Pointerable {
  static func from(pointer: UnsafeMutableRawPointer?) -> Self {
    guard let pointer = pointer else {
      fatalError("Attempted to obtain Controller from nil pointer. This should never happen.")
    }

    return Unmanaged<Self>.fromOpaque(pointer).takeUnretainedValue()
  }

  /// Gets the instance as an opaque pointer.
  ///
  /// Remember to add this line to `YourClass: Pointerable`, to avoid multiple initializations (non-critical)
  /// ```swift
  /// lazy var rawPointer = rawPointer
  /// ```
  var rawPointer: UnsafeMutableRawPointer {
    return Unmanaged.passUnretained(self).toOpaque()
  }
}

class PointerableObject: Pointerable {
  lazy var rawPointer = rawPointer
}
