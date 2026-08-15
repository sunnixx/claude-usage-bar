#if os(Windows)
import ClaudeUsageCore
import ClaudeUsageTray
import Foundation
import WinSDK

/// HKCU\Software\Microsoft\Windows\CurrentVersion\Run — per-user, so it needs
/// no elevation.
struct WindowsLoginItem: LoginItemControlling {
    private static let subKey = #"Software\Microsoft\Windows\CurrentVersion\Run"#
    private static let valueName = "ClaudeUsageBar"

    var isEnabled: Bool {
        var size: DWORD = 0
        let status = RegGetValueW(
            HKEY_CURRENT_USER, Self.subKey.wide, Self.valueName.wide,
            DWORD(RRF_RT_REG_SZ), nil, nil, &size
        )
        return status == ERROR_SUCCESS
    }

    func setEnabled(_ enabled: Bool) {
        var key: HKEY?
        guard RegOpenKeyExW(
            HKEY_CURRENT_USER, Self.subKey.wide, 0, DWORD(KEY_SET_VALUE), &key
        ) == ERROR_SUCCESS, let key else { return }
        defer { RegCloseKey(key) }

        if enabled {
            // Registry Run values are read directly by the shell, not parsed
            // by a Desktop Entry-style tokeniser, but quoting still matters
            // once cmd-style argument parsing sees this string: an install
            // path containing a space (e.g. under "C:\Program Files\") would
            // otherwise be misread as multiple arguments.
            let exe = "\"\(exePath())\"".wide
            // RegSetValueExW's byte-length argument counts UTF-16 CODE UNITS
            // * 2 (bytes), INCLUDING the trailing NUL that `.wide` already
            // appended — REG_SZ values must be NUL-terminated, and a length
            // that stops one UInt16 short would truncate the last character
            // instead of the terminator.
            // Explicit closure parameter/return types below: without them the
            // type checker times out on this nested
            // withUnsafeBufferPointer/withMemoryRebound/RegSetValueExW chain
            // ("unable to type-check this expression in reasonable time").
            exe.withUnsafeBufferPointer { (buffer: UnsafeBufferPointer<UInt16>) -> Void in
                guard let base = buffer.baseAddress else { return }
                let byteCount = DWORD(buffer.count * 2)
                base.withMemoryRebound(
                    to: BYTE.self, capacity: buffer.count * 2
                ) { (bytes: UnsafePointer<BYTE>) -> Void in
                    _ = RegSetValueExW(
                        key, Self.valueName.wide, 0, DWORD(REG_SZ), bytes, byteCount
                    )
                }
            }
        } else {
            _ = RegDeleteValueW(key, Self.valueName.wide)
        }
    }

    private func exePath() -> String {
        // GetModuleFileNameW does not report the size actually needed when
        // the buffer is too small: it just fills the buffer, NUL-terminates
        // within it, and returns a value equal to the buffer's own capacity
        // (with the last error set to ERROR_INSUFFICIENT_BUFFER) — silent
        // truncation rather than "here's how big to make it." A fixed
        // MAX_PATH (260) buffer is exactly the case that bites on any
        // install path using the long-path opt-in, so grow and retry
        // instead of trusting a single MAX_PATH-sized attempt. Capped so a
        // pathological environment cannot spin this forever.
        var capacity = DWORD(MAX_PATH)
        while capacity <= 1 << 16 {
            var buffer = [UInt16](repeating: 0, count: Int(capacity))
            let written = GetModuleFileNameW(nil, &buffer, capacity)
            if written == 0 { return "" }
            if written < capacity {
                return String(decoding: buffer.prefix(Int(written)), as: UTF16.self)
            }
            capacity *= 2
        }
        return ""
    }
}
#endif
