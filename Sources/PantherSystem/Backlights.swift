import CoreGraphics
import Darwin
import Foundation
import ObjectiveC

/// Built-in panel brightness through private DisplayServices (signatures recovered in
/// docs/03-re-findings.md). Loaded at runtime with dlsym, so a missing symbol degrades to "no-op".
public enum DisplayBacklight {
    private typealias GetFn = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetFn = @convention(c) (CGDirectDisplayID, Float) -> Int32

    nonisolated(unsafe) private static let handle =
        dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_NOW)
    private static let getFn: GetFn? = symbol("DisplayServicesGetBrightness")
    private static let setFn: SetFn? = symbol("DisplayServicesSetBrightness")

    private static func symbol<T>(_ name: String) -> T? {
        guard let handle, let raw = dlsym(handle, name) else { return nil }
        return unsafeBitCast(raw, to: T.self)
    }

    public static func builtInDisplay() -> CGDirectDisplayID? {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return nil }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &ids, &count) == .success else { return nil }
        return ids.prefix(Int(count)).first { CGDisplayIsBuiltin($0) != 0 }
    }

    public static func brightness(of display: CGDirectDisplayID) -> Float? {
        guard let getFn else { return nil }
        var value: Float = -1
        guard getFn(display, &value) == 0, value >= 0 else { return nil }
        return value
    }

    @discardableResult
    public static func setBrightness(_ value: Float, of display: CGDirectDisplayID) -> Bool {
        guard let setFn else { return false }
        return setFn(display, min(max(value, 0), 1)) == 0
    }

    public static func isAsleep(_ display: CGDirectDisplayID) -> Bool { CGDisplayIsAsleep(display) != 0 }
}

/// Keyboard backlight through private CoreBrightness `KeyboardBrightnessClient` (methods recovered
/// with tools/objcdump). Called through the Objective-C runtime; absent class = no-op.
public final class KeyboardBacklight {
    private let client: NSObject?

    public init() {
        _ = dlopen("/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness", RTLD_NOW)
        client = (NSClassFromString("KeyboardBrightnessClient") as? NSObject.Type)?.init()
    }

    /// IDs of built-in keyboards with a backlight.
    public func builtInKeyboards() -> [UInt64] {
        guard let client, client.responds(to: Sel.ids),
              let array = client.perform(Sel.ids)?.takeRetainedValue() as? [NSNumber] else { return [] }
        return array.map(\.uint64Value).filter { call(Sel.isBuiltIn, $0, as: BoolGetter.self) ?? false }
    }

    public func brightness(_ id: UInt64) -> Float? { call(Sel.brightness, id, as: FloatGetter.self) }
    public func isAutoBrightness(_ id: UInt64) -> Bool? { call(Sel.isAuto, id, as: BoolGetter.self) }

    @discardableResult
    public func setBrightness(_ value: Float, _ id: UInt64) -> Bool {
        guard let client, let imp = implementation(Sel.setBrightness) else { return false }
        return unsafeBitCast(imp, to: FloatSetter.self)(client, Sel.setBrightness, min(max(value, 0), 1), id)
    }

    @discardableResult
    public func setAutoBrightness(_ on: Bool, _ id: UInt64) -> Bool {
        guard let client, let imp = implementation(Sel.setAuto) else { return false }
        return unsafeBitCast(imp, to: BoolSetter.self)(client, Sel.setAuto, on, id)
    }

    // MARK: - Runtime plumbing

    private typealias FloatGetter = @convention(c) (AnyObject, Selector, UInt64) -> Float
    private typealias BoolGetter = @convention(c) (AnyObject, Selector, UInt64) -> Bool
    private typealias FloatSetter = @convention(c) (AnyObject, Selector, Float, UInt64) -> Bool
    private typealias BoolSetter = @convention(c) (AnyObject, Selector, Bool, UInt64) -> Bool

    private enum Sel {
        static let ids = NSSelectorFromString("copyKeyboardBacklightIDs")
        static let isBuiltIn = NSSelectorFromString("isKeyboardBuiltIn:")
        static let brightness = NSSelectorFromString("brightnessForKeyboard:")
        static let isAuto = NSSelectorFromString("isAutoBrightnessEnabledForKeyboard:")
        static let setBrightness = NSSelectorFromString("setBrightness:forKeyboard:")
        static let setAuto = NSSelectorFromString("enableAutoBrightness:forKeyboard:")
    }

    private func implementation(_ sel: Selector) -> IMP? {
        guard let client, let method = class_getInstanceMethod(type(of: client), sel) else { return nil }
        return method_getImplementation(method)
    }

    private func call<F, R>(_ sel: Selector, _ id: UInt64, as type: F.Type) -> R? {
        guard let client, let imp = implementation(sel) else { return nil }
        if F.self == FloatGetter.self { return unsafeBitCast(imp, to: FloatGetter.self)(client, sel, id) as? R }
        if F.self == BoolGetter.self { return unsafeBitCast(imp, to: BoolGetter.self)(client, sel, id) as? R }
        return nil
    }
}
