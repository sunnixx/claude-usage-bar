#if os(Windows)
import ClaudeUsageCore
import Foundation
import WinSDK

private let kTrayMessage = UINT(WM_APP + 1)
private let kUpdateMessage = UINT(WM_APP + 2)
private let kMenuBase: UINT = 1000
private let kMenuRefresh: UINT = 1
private let kMenuLogin: UINT = 2
private let kMenuQuit: UINT = 3

/// `HWND_MESSAGE` is a C macro (`((HWND)-3)` from winuser.h), which — like
/// `RGB` in Win32Icon.swift — does not import into Swift. Reimplemented
/// directly: a message-only window's parent, recognised by its exact bit
/// pattern rather than by any real window handle.
private let HWND_MESSAGE = HWND(bitPattern: -3)

/// Windows tray via Shell_NotifyIcon on a message-only window.
///
/// Win32 UI objects belong to the thread that created them, so every call below
/// happens on the thread that called `run`; `update` reaches it by PostMessage.
public final class Win32Tray: TrayBackend, @unchecked Sendable {
    /// A `static let` has program-lifetime storage, so the buffer this points
    /// into stays alive for as long as `RegisterClassExW`/`CreateWindowExW`
    /// (and anything else that dereferences `wc.lpszClassName` later) could
    /// need it — unlike a local `let` captured only inside one
    /// `withUnsafeBufferPointer` closure, whose backing storage is not
    /// guaranteed to survive the closure returning.
    private static let className = "ClaudeUsageBarWindow".wide

    private var window: HWND?
    private var icon: HICON?
    private var handlers: TrayHandlers?

    private let lock = NSLock()
    private var pending: TrayContent?
    private var shown: TrayContent?

    /// The thread that calls `run` and owns the message-only window. Recorded
    /// so `update` can tell whether it is already executing there (e.g.
    /// called synchronously from inside `WndProc` via `menuWillOpen`) versus
    /// from the background poll task.
    private var uiThread: Thread?

    public init() {}

    public func run(handlers: TrayHandlers) -> Never {
        self.handlers = handlers
        uiThread = Thread.current

        let instance = GetModuleHandleW(nil)

        var wc = WNDCLASSEXW()
        wc.cbSize = UINT(MemoryLayout<WNDCLASSEXW>.size)
        wc.lpfnWndProc = { hwnd, msg, wparam, lparam in
            Win32Tray.dispatch(hwnd, msg, wparam, lparam)
        }
        wc.hInstance = instance

        Self.className.withUnsafeBufferPointer { buffer in
            wc.lpszClassName = buffer.baseAddress
            _ = RegisterClassExW(&wc)
        }

        // HWND_MESSAGE: a message-only window, so nothing appears on screen.
        window = Self.className.withUnsafeBufferPointer { buffer in
            CreateWindowExW(
                0, buffer.baseAddress, buffer.baseAddress, 0, 0, 0, 0, 0,
                HWND_MESSAGE, nil, instance, nil
            )
        }
        // Route WndProc callbacks back to this instance. Unretained: the
        // instance outlives the window, which lives for the process.
        _ = SetWindowLongPtrW(
            window, GWLP_USERDATA,
            LONG_PTR(Int(bitPattern: Unmanaged.passUnretained(self).toOpaque()))
        )

        var data = notifyData()
        data.uFlags = UINT(NIF_ICON) | UINT(NIF_MESSAGE) | UINT(NIF_TIP)
        data.uCallbackMessage = kTrayMessage
        _ = Shell_NotifyIconW(DWORD(NIM_ADD), &data)

        applyPending()

        // GetMessageW's BOOL return imports as Swift Bool, not Int32, under
        // the WinSDK overlay — it collapses the C tri-state (-1 error / 0
        // WM_QUIT / nonzero message) to true/false, so the rare -1 "invalid
        // window handle" case is indistinguishable here from an ordinary
        // WM_QUIT. That is an acceptable simplification: this loop's only job
        // is to keep pumping until quit, and -1 is not a case this app's own
        // window handle should ever produce.
        var msg = MSG()
        while GetMessageW(&msg, nil, 0, 0) {
            TranslateMessage(&msg)
            DispatchMessageW(&msg)
        }
        // GetMessageW returns 0 once PostQuitMessage's WM_QUIT has been
        // pumped — the ordinary, expected way this loop ends (Quit menu item
        // or WM_DESTROY), not a failure. Trapping here would turn every
        // user-initiated quit into a crash report, which is exactly the bug
        // the Linux backend shipped and had to fix: gtk_main_quit() returning
        // into a fatalError() made every quit look like a crash. Clean up and
        // exit normally instead.
        cleanUp()
        exit(0)
    }

    public func update(_ content: TrayContent) {
        lock.lock()
        pending = content
        lock.unlock()

        // Drain inline when already on the UI thread — notably when `update`
        // is invoked synchronously from `menuWillOpen`, via the driver's
        // forced republish while `showMenu` is about to run inside the same
        // `WndProc` call. Posting a message in that case would queue the
        // refresh to be applied AFTER `showMenu` has already read `shown` and
        // built the menu — the same stale-menu-on-open bug the macOS and
        // Linux backends fixed by draining inline on their own UI threads.
        // Off the UI thread (the background poll task), PostMessage is one of
        // the few thread-safe Win32 calls, and — unlike SendMessage — it does
        // not block waiting for WndProc to process it, so it cannot re-enter
        // the driver synchronously, satisfying the TrayBackend.update
        // contract.
        if Thread.current === uiThread {
            applyPending()
            return
        }
        if let window { _ = PostMessageW(window, kUpdateMessage, 0, 0) }
    }

    // MARK: - UI thread only

    private static func dispatch(
        _ hwnd: HWND?, _ msg: UINT, _ wparam: WPARAM, _ lparam: LPARAM
    ) -> LRESULT {
        let raw = UnsafeMutableRawPointer(
            bitPattern: Int(GetWindowLongPtrW(hwnd, GWLP_USERDATA))
        )
        guard let raw else { return DefWindowProcW(hwnd, msg, wparam, lparam) }
        let tray = Unmanaged<Win32Tray>.fromOpaque(raw).takeUnretainedValue()

        switch msg {
        case kUpdateMessage:
            tray.applyPending()
            return 0
        case kTrayMessage:
            let event = UINT(lparam & 0xFFFF)
            if event == UINT(WM_RBUTTONUP) || event == UINT(WM_LBUTTONUP) {
                tray.handlers?.menuWillOpen()
                tray.showMenu()
            }
            return 0
        case UINT(WM_COMMAND):
            tray.handleCommand(UINT(wparam & 0xFFFF))
            return 0
        case UINT(WM_DESTROY):
            PostQuitMessage(0)
            return 0
        default:
            return DefWindowProcW(hwnd, msg, wparam, lparam)
        }
    }

    private func handleCommand(_ id: UINT) {
        switch id {
        case kMenuBase + kMenuRefresh: handlers?.refresh()
        case kMenuBase + kMenuLogin: handlers?.toggleLoginItem()
        case kMenuBase + kMenuQuit: PostQuitMessage(0)
        default: break
        }
    }

    private func applyPending() {
        lock.lock()
        let next = pending
        pending = nil
        lock.unlock()

        guard let next, next != shown else { return }
        shown = next

        let fresh = Win32Icon.make(
            percent: next.title.percent,
            critical: next.title.isCritical,
            stale: next.title.isStale
        )
        var data = notifyData()
        data.uFlags = UINT(NIF_ICON) | UINT(NIF_TIP)
        data.hIcon = fresh
        withUnsafeMutableBytes(of: &data.szTip) { buffer in
            let tip = next.title.text.wide
            let dest = buffer.bindMemory(to: UInt16.self)
            for (i, unit) in tip.prefix(dest.count - 1).enumerated() { dest[i] = unit }
            dest[min(tip.count, dest.count - 1)] = 0
        }
        _ = Shell_NotifyIconW(DWORD(NIM_MODIFY), &data)

        // Replace only after the shell has taken the new one, then free the old
        // handle — otherwise this leaks a GDI object every minute.
        if let icon { DestroyIcon(icon) }
        icon = fresh
    }

    private func showMenu() {
        lock.lock()
        let content = shown
        lock.unlock()
        guard let content, let window, let menu = CreatePopupMenu() else { return }
        defer { _ = DestroyMenu(menu) }

        for row in content.rows {
            // Win32 menus use the system proportional font, so the padded
            // monospace line would render ragged. Compose from the fields.
            _ = AppendMenuW(menu, UINT(MF_STRING) | UINT(MF_GRAYED), 0, Self.line(row).wide)
        }
        _ = AppendMenuW(menu, UINT(MF_SEPARATOR), 0, nil)
        _ = AppendMenuW(
            menu, UINT(MF_STRING), UINT_PTR(kMenuBase + kMenuRefresh), "Refresh Now".wide
        )
        _ = AppendMenuW(
            menu,
            UINT(MF_STRING) | UINT(content.loginItemEnabled ? MF_CHECKED : MF_UNCHECKED),
            UINT_PTR(kMenuBase + kMenuLogin), "Launch at Login".wide
        )
        _ = AppendMenuW(menu, UINT(MF_SEPARATOR), 0, nil)
        _ = AppendMenuW(menu, UINT(MF_STRING), UINT_PTR(kMenuBase + kMenuQuit), "Quit".wide)

        var point = POINT()
        GetCursorPos(&point)
        // Required or the menu will not dismiss when the user clicks elsewhere.
        SetForegroundWindow(window)
        _ = TrackPopupMenu(
            menu, UINT(TPM_RIGHTBUTTON), point.x, point.y, 0, window, nil
        )
        _ = PostMessageW(window, UINT(WM_NULL), 0, 0)
    }

    /// Windows lays the fields out for a proportional font rather than using
    /// `MenuModel.monospaceLine`, which is built for a fixed-width menu.
    static func line(_ row: MenuRow) -> String {
        var parts: [String] = [row.isIndented ? "    \(row.label)" : row.label]
        if let percent = row.percent { parts.append("\(percent)%") }
        if let reset = row.reset { parts.append(reset) }
        return parts.joined(separator: "   ")
    }

    private func notifyData() -> NOTIFYICONDATAW {
        var data = NOTIFYICONDATAW()
        data.cbSize = DWORD(MemoryLayout<NOTIFYICONDATAW>.size)
        data.hWnd = window
        data.uID = 1
        return data
    }

    private func cleanUp() {
        var data = notifyData()
        _ = Shell_NotifyIconW(DWORD(NIM_DELETE), &data)
        if let icon { DestroyIcon(icon) }
    }
}
#endif
