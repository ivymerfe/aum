import MultitouchSupport

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
