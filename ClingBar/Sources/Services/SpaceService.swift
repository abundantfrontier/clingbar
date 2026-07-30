import AppKit
import CoreGraphics
import Darwin

/// Space identity + switch via private SkyLight/CGS symbols (dlsym).
/// System Mission Control still says "Desktop N"; ClingBar keeps project names separately.
///
/// Jump path rule: **switch the Space**, never pull windows here via AX raise.
@MainActor
final class SpaceService {
    static let shared = SpaceService()

    /// CGS space id (e.g. "10"), stable for the life of the Space.
    private(set) var currentSpaceID: String = "unknown"
    /// 1-based index among user desktops on the main display (best-effort).
    private(set) var currentDesktopNumber: Int?
    /// Ordered user desktop space ids on the main display.
    private(set) var desktopSpaceIDs: [String] = []

    private var connection: Int32 = 0
    private var mainConnectionID: (() -> Int32)?
    private var getActiveSpace: ((Int32) -> UInt64)?
    private var copyManagedDisplaySpaces: ((Int32) -> Unmanaged<CFArray>?)?
    private var setCurrentSpace: ((Int32, CFString, UInt64) -> Int32)?
    private var copySpacesForWindows: ((Int32, Int32, CFArray) -> Unmanaged<CFArray>?)?
    private var copyWindowsWithOptionsAndTags: ((
        Int32, UInt32, CFArray, UInt32,
        UnsafeMutablePointer<UInt64>, UnsafeMutablePointer<UInt64>
    ) -> Unmanaged<CFArray>?)?
    private var windowQueryWindows: ((Int32, CFArray, Int32) -> Unmanaged<CFTypeRef>?)?
    private var windowQueryResultCopyWindows: ((CFTypeRef) -> Unmanaged<CFTypeRef>?)?
    private var windowIteratorAdvance: ((CFTypeRef) -> Bool)?
    private var windowIteratorGetWindowID: ((CFTypeRef) -> UInt32)?
    private var observer: NSObjectProtocol?

    private var spaceChangedHandlers: [UUID: () -> Void] = [:]
    private var simpleSpaceChangedID: UUID?

    @discardableResult
    func addSpaceChangedHandler(_ handler: @escaping () -> Void) -> UUID {
        let id = UUID()
        spaceChangedHandlers[id] = handler
        return id
    }

    func removeSpaceChangedHandler(_ id: UUID) {
        spaceChangedHandlers.removeValue(forKey: id)
    }

    var onSpaceChanged: (() -> Void)? {
        didSet {
            if let simpleSpaceChangedID {
                spaceChangedHandlers.removeValue(forKey: simpleSpaceChangedID)
                self.simpleSpaceChangedID = nil
            }
            if let onSpaceChanged {
                let id = UUID()
                simpleSpaceChangedID = id
                spaceChangedHandlers[id] = onSpaceChanged
            }
        }
    }

    private init() {
        loadSymbols()
        refresh()
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.refresh()
                self?.notifySpaceChanged()
            }
        }
    }

    private func notifySpaceChanged() {
        for handler in spaceChangedHandlers.values {
            handler()
        }
    }

    deinit {
        if let observer {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
    }

    func refreshCurrentSpace() { refresh() }

    func refresh() {
        guard connection != 0 || loadConnection() else {
            currentSpaceID = fingerprintFallback()
            currentDesktopNumber = nil
            desktopSpaceIDs = [currentSpaceID]
            return
        }

        if let getActiveSpace {
            currentSpaceID = String(getActiveSpace(connection))
        } else {
            currentSpaceID = fingerprintFallback()
        }

        let (ids, _) = managedDesktopIDs()
        desktopSpaceIDs = ids
        if let idx = ids.firstIndex(of: currentSpaceID) {
            currentDesktopNumber = idx + 1
        } else {
            currentDesktopNumber = nil
        }
    }

    var canSwitchSpaces: Bool {
        setCurrentSpace != nil && connection != 0 && !desktopSpaceIDs.isEmpty
    }

    func systemDesktopLabel(forSpaceID id: String) -> String? {
        guard let idx = desktopSpaceIDs.firstIndex(of: id) else { return nil }
        return "Desktop \(idx + 1)"
    }

    /// Switch Mission Control to the given user desktop. Does **not** move windows.
    @discardableResult
    func switchToSpace(id: String) -> Bool {
        guard let setCurrentSpace, connection != 0, let sid = UInt64(id) else {
            return false
        }
        let (_, displayStr) = managedDesktopIDs()
        let display = (displayStr ?? mainDisplayUUIDString() ?? "") as CFString
        guard CFStringGetLength(display) > 0 else { return false }

        let before = getActiveSpace?(connection)
        let result = setCurrentSpace(connection, display, sid)
        // Success is usually 0; also accept if active space actually changed.
        let after = getActiveSpace?(connection)
        let changed = after.map { String($0) == id } ?? false
        let ok = result == 0 || changed || (before != after && after != nil)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            self?.refresh()
            self?.notifySpaceChanged()
        }
        if ok {
            currentSpaceID = id
            if let idx = desktopSpaceIDs.firstIndex(of: id) {
                currentDesktopNumber = idx + 1
            }
        }
        return ok
    }

    // MARK: - Window ↔ Space (for jump without pulling windows)

    /// Space IDs that contain `windowID` (best-effort).
    func spaceIDs(forWindowID windowID: CGWindowID) -> [String] {
        guard connection != 0 || loadConnection() else { return [] }

        // Fast path: SLSCopySpacesForWindows
        if let copySpacesForWindows {
            let arr = [NSNumber(value: windowID)] as CFArray
            if let unmanaged = copySpacesForWindows(connection, 0x7, arr) {
                let spaces = unmanaged.takeRetainedValue() as? [NSNumber] ?? []
                let ids = spaces.map { String($0.uint64Value) }.filter { !$0.isEmpty && $0 != "0" }
                if !ids.isEmpty { return ids }
            }
        }

        // Reverse map via windows-on-space query
        if let sid = windowToSpaceMap()[windowID] {
            return [sid]
        }
        return []
    }

    /// Best Space for a window: first non-empty mapping.
    func preferredSpaceID(forWindowID windowID: CGWindowID) -> String? {
        spaceIDs(forWindowID: windowID).first
    }

    /// Best Space for an app: Space where it has the most window area.
    /// Prefers a Space other than the current one when the app isn’t meaningfully here.
    func preferredSpaceID(forBundleIdentifier bundleID: String) -> String? {
        let selfPID = ProcessInfo.processInfo.processIdentifier
        let windows = WindowEnumerator.allWindows(excludingPID: selfPID)
            .filter { $0.bundleIdentifier == bundleID }
        guard !windows.isEmpty else { return nil }

        let map = windowToSpaceMap()
        var areaBySpace: [String: CGFloat] = [:]
        for w in windows {
            guard let sid = map[w.id] ?? preferredSpaceID(forWindowID: w.id) else { continue }
            areaBySpace[sid, default: 0] += w.bounds.width * w.bounds.height
        }
        guard !areaBySpace.isEmpty else { return nil }

        // Prefer the Space with the most real UI for this app.
        return areaBySpace.max(by: { $0.value < $1.value })?.key
    }

    /// CG window IDs known to live on `spaceID`.
    func windowIDs(onSpace spaceID: String) -> [CGWindowID] {
        guard let sid = UInt64(spaceID), connection != 0 || loadConnection() else { return [] }
        return windowsOnSpace(sid)
    }

    // MARK: - Private

    @discardableResult
    private func loadConnection() -> Bool {
        if connection != 0 { return true }
        loadSymbols()
        return connection != 0
    }

    private func loadSymbols() {
        // SkyLight first (real home of modern CGS/SLS); CoreGraphics re-exports many.
        let paths = [
            "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight",
            "/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics",
        ]
        var handle: UnsafeMutableRawPointer?
        for path in paths {
            handle = dlopen(path, RTLD_LAZY)
            if handle != nil { break }
        }
        guard handle != nil else { return }

        func load<T>(_ name: String, _ type: T.Type) -> T? {
            guard let s = dlsym(handle, name) else { return nil }
            return unsafeBitCast(s, to: T.self)
        }

        // Prefer SLS* names; fall back to CGS*
        if let f: (@convention(c) () -> Int32) =
            load("SLSMainConnectionID", (@convention(c) () -> Int32).self)
            ?? load("CGSMainConnectionID", (@convention(c) () -> Int32).self) {
            mainConnectionID = f
            connection = f()
        }
        getActiveSpace =
            load("SLSGetActiveSpace", (@convention(c) (Int32) -> UInt64).self)
            ?? load("CGSGetActiveSpace", (@convention(c) (Int32) -> UInt64).self)
        copyManagedDisplaySpaces =
            load("SLSCopyManagedDisplaySpaces", (@convention(c) (Int32) -> Unmanaged<CFArray>?).self)
            ?? load("CGSCopyManagedDisplaySpaces", (@convention(c) (Int32) -> Unmanaged<CFArray>?).self)
        setCurrentSpace =
            load("SLSManagedDisplaySetCurrentSpace", (@convention(c) (Int32, CFString, UInt64) -> Int32).self)
            ?? load("CGSManagedDisplaySetCurrentSpace", (@convention(c) (Int32, CFString, UInt64) -> Int32).self)
        copySpacesForWindows =
            load("SLSCopySpacesForWindows", (@convention(c) (Int32, Int32, CFArray) -> Unmanaged<CFArray>?).self)
            ?? load("CGSCopySpacesForWindows", (@convention(c) (Int32, Int32, CFArray) -> Unmanaged<CFArray>?).self)
        copyWindowsWithOptionsAndTags =
            load(
                "SLSCopyWindowsWithOptionsAndTags",
                (@convention(c) (
                    Int32, UInt32, CFArray, UInt32,
                    UnsafeMutablePointer<UInt64>, UnsafeMutablePointer<UInt64>
                ) -> Unmanaged<CFArray>?).self
            )
            ?? load(
                "CGSCopyWindowsWithOptionsAndTags",
                (@convention(c) (
                    Int32, UInt32, CFArray, UInt32,
                    UnsafeMutablePointer<UInt64>, UnsafeMutablePointer<UInt64>
                ) -> Unmanaged<CFArray>?).self
            )
        windowQueryWindows =
            load("SLSWindowQueryWindows", (@convention(c) (Int32, CFArray, Int32) -> Unmanaged<CFTypeRef>?).self)
        windowQueryResultCopyWindows =
            load("SLSWindowQueryResultCopyWindows", (@convention(c) (CFTypeRef) -> Unmanaged<CFTypeRef>?).self)
        windowIteratorAdvance =
            load("SLSWindowIteratorAdvance", (@convention(c) (CFTypeRef) -> Bool).self)
        windowIteratorGetWindowID =
            load("SLSWindowIteratorGetWindowID", (@convention(c) (CFTypeRef) -> UInt32).self)
    }

    private func managedDesktopIDs() -> (ids: [String], display: String?) {
        guard let copyManagedDisplaySpaces, connection != 0,
              let unmanaged = copyManagedDisplaySpaces(connection) else {
            return ([], nil)
        }
        let arr = unmanaged.takeRetainedValue() as? [[String: Any]] ?? []
        guard let display = arr.first else { return ([], nil) }
        let displayID = display["Display Identifier"] as? String
        var ids: [String] = []
        if let spaces = display["Spaces"] as? [[String: Any]] {
            for sp in spaces {
                let type = sp["type"] as? Int ?? 0
                if type != 0 { continue }
                if let id64 = sp["id64"] as? UInt64 {
                    ids.append(String(id64))
                } else if let id = sp["ManagedSpaceID"] as? UInt64 {
                    ids.append(String(id))
                }
            }
        }
        return (ids, displayID)
    }

    private func mainDisplayUUIDString() -> String? {
        guard let screen = NSScreen.main,
              let num = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        else { return nil }
        let did = CGDirectDisplayID(num.uint32Value)
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(did)?.takeRetainedValue() else { return nil }
        return CFUUIDCreateString(nil, uuid) as String
    }

    /// Map CGWindowID → space id string for all user desktops.
    private func windowToSpaceMap() -> [CGWindowID: String] {
        guard connection != 0 || loadConnection() else { return [:] }
        var map: [CGWindowID: String] = [:]
        for sidStr in desktopSpaceIDs.isEmpty ? managedDesktopIDs().ids : desktopSpaceIDs {
            guard let sid = UInt64(sidStr) else { continue }
            for wid in windowsOnSpace(sid) {
                // First write wins; windows can appear on multiple spaces if sticky —
                // prefer keeping earlier (leftmost) mapping is fine for sticky.
                if map[wid] == nil {
                    map[wid] = sidStr
                }
            }
        }
        return map
    }

    private func windowsOnSpace(_ spaceID: UInt64) -> [CGWindowID] {
        guard let copyWindowsWithOptionsAndTags,
              let windowQueryWindows,
              let windowQueryResultCopyWindows,
              let windowIteratorAdvance,
              let windowIteratorGetWindowID,
              connection != 0
        else { return [] }

        let spaceArr = [NSNumber(value: spaceID)] as CFArray
        var setTags: UInt64 = 0
        var clearTags: UInt64 = 0
        // 0x7 = include minimized-ish; 0x2 = visible only
        guard let unmanaged = copyWindowsWithOptionsAndTags(
            connection, 0, spaceArr, 0x7, &setTags, &clearTags
        ) else { return [] }

        let windowList = unmanaged.takeRetainedValue()
        let count = CFArrayGetCount(windowList)
        guard count > 0,
              let q = windowQueryWindows(connection, windowList, Int32(count)) else {
            return []
        }
        let query = q.takeRetainedValue()
        guard let it = windowQueryResultCopyWindows(query) else { return [] }
        let iterator = it.takeRetainedValue()

        var ids: [CGWindowID] = []
        while windowIteratorAdvance(iterator) {
            ids.append(windowIteratorGetWindowID(iterator))
        }
        return ids
    }

    private func fingerprintFallback() -> String {
        let ids = WindowEnumerator.onscreenWindows().map(\.id).sorted()
        return "fp-" + ids.prefix(16).map(String.init).joined(separator: ".")
    }
}
