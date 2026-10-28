import Foundation

/// Values worked out from the whole library (album groups, what's owned), remembered until the
/// library's contents change, so views that redraw often don't redo them.
@MainActor
enum LibraryMemo {
    private static var values: [String: (version: String, value: Any)] = [:]

    static func value<T>(_ name: String, version: String, _ make: () -> T) -> T {
        if let entry = values[name], entry.version == version, let value = entry.value as? T { return value }
        let value = make()
        values[name] = (version, value)
        return value
    }
}
