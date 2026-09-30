import Foundation

protocol DefaultsValue {
  static func decode(_ any: Any) -> Self?
  var stored: Any { get }
}

extension DefaultsValue {
  static func decode(_ any: Any) -> Self? { any as? Self }
  var stored: Any { self }
}

extension Bool: DefaultsValue {}
extension String: DefaultsValue {}
extension Int: DefaultsValue {}
extension Double: DefaultsValue {}
extension Float: DefaultsValue {}
extension [String]: DefaultsValue {}

extension Set<String>: DefaultsValue {
  static func decode(_ any: Any) -> Set<String>? { (any as? [String]).map(Set.init) }
  var stored: Any { Array(self) }
}

extension DefaultsValue where Self: RawRepresentable, RawValue: DefaultsValue {
  static func decode(_ any: Any) -> Self? { RawValue.decode(any).flatMap(Self.init(rawValue:)) }
  var stored: Any { rawValue.stored }
}

@MainActor protocol KeyAssignable: AnyObject {
  var key: String? { get set }
}

@MainActor @propertyWrapper
final class UserDefault<T: DefaultsValue>: KeyAssignable {
  var key: String?
  private let defaultValue: T?
  private let lazyDefault: (() -> T)?
  private let transformGet: (T) -> T
  private var cached: T?
  private var listeners: [UUID: (T) -> Void] = [:]

  init(
    wrappedValue: T,
    _ key: String? = nil,
    transformGet: @escaping (T) -> T = { $0 },
  ) {
    self.key = key
    self.defaultValue = wrappedValue
    self.lazyDefault = nil
    self.transformGet = transformGet
  }

  init(
    wrappedValue: @escaping () -> T,
    _ key: String? = nil,
    transformGet: @escaping (T) -> T = { $0 },
  ) {
    self.key = key
    self.defaultValue = nil
    self.lazyDefault = wrappedValue
    self.transformGet = transformGet
  }

  var wrappedValue: T {
    get {
      if let cached { return cached }
      let raw = UserDefaults.standard.object(forKey: key!).flatMap(T.decode)
      let result = transformGet(raw ?? defaultValue ?? lazyDefault!())
      cached = result
      return result
    }
    set {
      cached = transformGet(newValue)
      UserDefaults.standard.set(newValue.stored, forKey: key!)
      notify(newValue)
    }
  }

  var projectedValue: UserDefault<T> { self }

  @discardableResult
  func onSet(_ listener: @escaping (T) -> Void) -> UUID {
    let id = UUID()
    listeners[id] = listener
    return id
  }

  func removeListener(_ id: UUID) {
    listeners[id] = nil
  }

  func delete(reset: Bool = true) {
    UserDefaults.standard.removeObject(forKey: key!)
    cached = nil
    if reset { notify(wrappedValue) }
  }

  private func notify(_ value: T) {
    for listener in listeners.values { listener(value) }
  }
}

@MainActor open class Singleton {
  private static var instances: [ObjectIdentifier: Any] = [:]

  public static var shared: Self {
    let id = ObjectIdentifier(self)
    if let existing = instances[id] as? Self { return existing }
    let instance = self.init()
    instances[id] = instance
    return instance
  }

  required public init() {}
}

@MainActor open class ConfigCore: Singleton {
  required public init() {
    super.init()
    for child in Mirror(reflecting: self).children {
      guard let userDefault = child.value as? KeyAssignable, userDefault.key == nil else {
        continue
      }
      guard let label = child.label else { fatalError("ConfigCore: no label") }
      userDefault.key = String(label.dropFirst())
    }
  }
}
