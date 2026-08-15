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

/// WS_POPUP (0x80000000) and WS_EX_TOOLWINDOW (0x00000080), from winuser.h —
/// hardcoded as same-width unsigned literals rather than referencing the
/// WinSDK overlay's own `WS_POPUP`/`WS_EX_TOOLWINDOW` names. WS_POPUP's top
/// bit set makes it exactly Int32.min's bit pattern; depending on how the
/// overlay happened to type that macro, `DWORD(WS_POPUP)` risked either a
/// silent wraparound or a runtime trap converting a negative `Int32` to an
/// unsigned `DWORD`. A `DWORD`-typed literal sidesteps that ambiguity
/// entirely — 0x8000_0000 fits UInt32 exactly, so no conversion happens.
private let wsPopup: DWORD = 0x8000_0000
private let wsExToolWindow: DWORD = 0x0000_0080

/// Explorer (and therefore the taskbar and notification area) can restart at
/// any time — a crash, a shell update installing, or the user restarting it
/// by hand from Task Manager — and every process's `Shell_NotifyIcon` icon is
/// destroyed when that happens; `NIM_ADD` is never reissued automatically.
/// The documented way to recover is to register this well-known message at
/// startup and re-add the icon whenever it arrives. `RegisterWindowMessageW`
/// returns a plain `UINT`, not a pointer, so — unlike the `HWND` fields below,
/// which need `lock` — it is fine as ordinary global state under Swift 6
/// concurrency checking.
private let kTaskbarCreatedMessage: UINT = RegisterWindowMessageW("TaskbarCreated".wide)

/// Windows tray via Shell_NotifyIcon on a real (but never shown) top-level
/// window — see the comment on window creation in `run` for why it is not a
/// message-only (`HWND_MESSAGE`) window.
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

    private var icon: HICON?

    private let lock = NSLock()

    /// `window`, `uiThread` and `handlers` are written exactly once, during
    /// `run`'s startup, on the thread that calls `run`. But `main.swift`
    /// calls `driver.start()` — which can invoke `update` from the detached
    /// poll task — before it calls `tray.run(...)`, so a call to `update`
    /// arriving that early races those writes with its own reads of the same
    /// storage on a different thread with no synchronisation between them,
    /// which is undefined behaviour regardless of how unlikely the timing
    /// window is. `@unchecked Sendable` on this class only suppresses the
    /// compiler's static check; it does not make the race benign. All three
    /// are guarded by `lock` (shared with `pending` below — the two are
    /// never held across each other, so there is no nesting risk) via the
    /// private backing/computed-property pairs underneath.
    private var _window: HWND?
    private var _uiThread: Thread?
    private var _handlers: TrayHandlers?

    private var window: HWND? {
        get { lock.lock(); defer { lock.unlock() }; return _window }
        set { lock.lock(); _window = newValue; lock.unlock() }
    }
    private var uiThread: Thread? {
        get { lock.lock(); defer { lock.unlock() }; return _uiThread }
        set { lock.lock(); _uiThread = newValue; lock.unlock() }
    }
    private var handlers: TrayHandlers? {
        get { lock.lock(); defer { lock.unlock() }; return _handlers }
        set { lock.lock(); _handlers = newValue; lock.unlock() }
    }

    /// Guarded by `lock`; written from any thread via `update`.
    private var pending: TrayContent?
    /// UI thread only: every read and write — including in `showMenu`, which
    /// runs on this same thread via `dispatch` — happens there, so it needs
    /// no lock of its own.
    private var shown: TrayContent?
    /// UI thread only. True when `shown` has changed since the icon/tooltip
    /// were last actually rendered via `Shell_NotifyIconW`. Split from
    /// `shown` itself so the UI thread can update `shown` — cheap, pure Swift
    /// state — without also being forced to perform the render, which is not
    /// cheap and not safe to do from every calling context (see `update`).
    private var needsRender = false

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

        // A REAL top-level window (WS_POPUP, parent nil), NOT an
        // HWND_MESSAGE message-only window. This used to be HWND_MESSAGE,
        // which seemed right for a window that only ever needs to receive
        // WndProc callbacks and never appears on screen — but Explorer
        // publishes "TaskbarCreated" (used by addIcon()/dispatch() below to
        // recover the tray icon after an Explorer restart) as an
        // HWND_BROADCAST send, and Microsoft's documented contract for
        // message-only windows is that they do NOT receive broadcast
        // messages at all. With an HWND_MESSAGE parent, the TaskbarCreated
        // handling below compiled, looked complete, and was silently
        // unreachable — worse than not having it, since nothing about the
        // code made that obvious. A top-level window, by contrast, is a
        // valid HWND_BROADCAST recipient. It stays invisible because
        // ShowWindow is never called on it and it's created at zero size;
        // WS_EX_TOOLWINDOW additionally keeps it out of the Alt-Tab list.
        // Do not add a ShowWindow call here — that is the only thing that
        // would make it appear.
        let created = Self.className.withUnsafeBufferPointer { buffer in
            CreateWindowExW(
                wsExToolWindow, buffer.baseAddress, buffer.baseAddress, wsPopup,
                0, 0, 0, 0, nil, nil, instance, nil
            )
        }
        // If either RegisterClassExW or CreateWindowExW failed, `window`
        // stays nil: Shell_NotifyIconW(NIM_ADD) below would then silently
        // fail too (no icon, no error surfaced to the user), and — far
        // worse — GetMessageW blocks forever on a thread that owns no
        // window and therefore can never be the target of a WM_QUIT it
        // never receives. That reads as the whole app having silently
        // hung, with no tray icon and no way to tell why. Fail loudly and
        // exit instead of leaving that undiagnosable.
        guard let created else {
            FileHandle.standardError.write(Data(
                "claude-usage-bar: CreateWindowExW failed — could not create the tray's hidden window.\n".utf8
            ))
            exit(1)
        }
        window = created

        // Route WndProc callbacks back to this instance. Unretained: the
        // instance outlives the window, which lives for the process.
        _ = SetWindowLongPtrW(
            window, GWLP_USERDATA,
            LONG_PTR(Int(bitPattern: Unmanaged.passUnretained(self).toOpaque()))
        )

        addIcon()
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

        // On the UI thread — notably when `update` is invoked synchronously
        // from `menuWillOpen`, via the driver's forced republish while
        // `showMenu` is about to run inside the same WndProc call — merge
        // `pending` into `shown` right now, so `showMenu` reads fresh
        // content instead of what was there before this call. That merge is
        // pure Swift state (no GDI, no Shell_NotifyIconW) and is exactly
        // what menu-open freshness needs; it deliberately does NOT also
        // render the icon/tooltip here. Shell_NotifyIconW can perform a
        // blocking SendMessageTimeout to Explorer and stall for seconds —
        // and this call is running on the UI thread while the driver holds
        // its non-recursive publishLock across it. If that stall let some
        // other sent message reach WndProc's kTrayMessage or WM_COMMAND
        // arms, menuWillOpen/toggleLoginItem would call back into the
        // driver and try to re-acquire that same publishLock on this same
        // thread — a permanent deadlock with no timeout, which is exactly
        // the hazard TrayBackend.update's own contract names. Posting the
        // render instead guarantees it happens later, off this call stack,
        // strictly after `update` — and the driver's lock — has returned.
        if Thread.current === uiThread {
            applyShownOnly()
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
        case kTaskbarCreatedMessage where kTaskbarCreatedMessage != 0:
            // Explorer just (re)created the taskbar — our previous
            // Shell_NotifyIcon registration, and the icon that went with
            // it, are gone. Re-add using whatever we last rendered; no new
            // icon needs to be drawn, since the GDI handle in `icon` was
            // never invalidated by this — only the shell's record of it was.
            tray.addIcon()
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

    /// Merges `pending` into `shown` without touching the icon or calling
    /// Shell_NotifyIconW — see the long comment in `update` for why the
    /// inline (same-thread-as-UI) path must stop here and let the posted
    /// `kUpdateMessage` perform the actual render later. Left as a
    /// standalone step, not folded into `applyPending`, so both the inline
    /// caller and `applyPending` itself can trigger "needs a render" without
    /// duplicating the comparison logic.
    private func applyShownOnly() {
        lock.lock()
        let next = pending
        lock.unlock()
        guard let next, next != shown else { return }
        shown = next
        needsRender = true
    }

    private func applyPending() {
        lock.lock()
        let next = pending
        pending = nil
        lock.unlock()

        if let next, next != shown {
            shown = next
            needsRender = true
        }
        guard needsRender else { return }
        needsRender = false
        render(shown)
    }

    /// Performs the actual Shell_NotifyIconW(NIM_MODIFY) call — the part
    /// `update`'s inline path must never do directly; see its comment.
    private func render(_ content: TrayContent?) {
        guard let content else { return }

        let fresh = Win32Icon.make(
            percent: content.title.percent,
            critical: content.title.isCritical,
            stale: content.title.isStale
        )
        var data = notifyData()
        data.uFlags = UINT(NIF_ICON) | UINT(NIF_TIP)
        data.hIcon = fresh
        fill(tip: content.title.text, into: &data)
        _ = Shell_NotifyIconW(DWORD(NIM_MODIFY), &data)

        // Replace only after the shell has taken the new one, then free the old
        // handle — otherwise this leaks a GDI object every minute.
        if let icon { DestroyIcon(icon) }
        icon = fresh
    }

    /// `NIM_ADD`, shared by `run`'s startup and by the `TaskbarCreated`
    /// recovery path in `dispatch`. Uses whichever `HICON` is already
    /// current in `icon` (nil on the very first call, before the first
    /// `applyPending` has run — Shell_NotifyIcon accepts that and shows the
    /// system default icon until the first real render arrives) rather than
    /// rendering a new one, since a taskbar restart does not invalidate the
    /// GDI handle, only the shell's bookkeeping about it.
    private func addIcon() {
        var data = notifyData()
        data.uFlags = UINT(NIF_ICON) | UINT(NIF_MESSAGE) | UINT(NIF_TIP)
        data.uCallbackMessage = kTrayMessage
        data.hIcon = icon
        if let shown { fill(tip: shown.title.text, into: &data) }
        _ = Shell_NotifyIconW(DWORD(NIM_ADD), &data)
    }

    private func showMenu() {
        let content = shown
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
        // Required or the menu will not dismiss when the user clicks elsewhere
        // — this is Microsoft's own documented idiom for a notification-icon
        // popup menu (SetForegroundWindow before TrackPopupMenu, WM_NULL
        // after). It depends on `window` being a genuine top-level window
        // with real z-order/foreground-eligibility semantics, which only
        // became true once `window` stopped being HWND_MESSAGE (see the
        // comment on window creation in `run`) — a message-only window has
        // no z-order for SetForegroundWindow to act on, so this call was
        // very likely a silent no-op before that fix, and menu dismissal may
        // well have been unreliable as a result. Unverified either way: this
        // was never run.
        SetForegroundWindow(window)
        _ = TrackPopupMenu(
            menu, UINT(TPM_RIGHTBUTTON), point.x, point.y, 0, window, nil
        )
        _ = PostMessageW(window, UINT(WM_NULL), 0, 0)
    }

    /// See `Win32MenuLine` for why this composition lives in its own
    /// platform-independent type rather than here.
    static func line(_ row: MenuRow) -> String { Win32MenuLine.compose(row) }

    private func notifyData() -> NOTIFYICONDATAW {
        var data = NOTIFYICONDATAW()
        data.cbSize = DWORD(MemoryLayout<NOTIFYICONDATAW>.size)
        data.hWnd = window
        data.uID = 1
        return data
    }

    /// Shared tooltip-copying step between `render` (normal updates) and
    /// `addIcon` (startup / TaskbarCreated recovery).
    private func fill(tip text: String, into data: inout NOTIFYICONDATAW) {
        withUnsafeMutableBytes(of: &data.szTip) { buffer in
            let tip = text.wide
            let dest = buffer.bindMemory(to: UInt16.self)
            for (i, unit) in tip.prefix(dest.count - 1).enumerated() { dest[i] = unit }
            dest[min(tip.count, dest.count - 1)] = 0
        }
    }

    private func cleanUp() {
        var data = notifyData()
        _ = Shell_NotifyIconW(DWORD(NIM_DELETE), &data)
        if let icon { DestroyIcon(icon) }
    }
}
#endif
