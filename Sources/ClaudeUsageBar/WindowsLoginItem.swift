#if os(Windows)
import ClaudeUsageCore
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
            exe.withUnsafeBufferPointer { buffer in
                buffer.baseAddress?.withMemoryRebound(
                    to: BYTE.self, capacity: buffer.count * 2
                ) { bytes in
                    _ = RegSetValueExW(
                        key, Self.valueName.wide, 0, DWORD(REG_SZ),
                        bytes, DWORD(buffer.count * 2)
                    )
                }
            }
        } else {
            _ = RegDeleteValueW(key, Self.valueName.wide)
        }
    }

    private func exePath() -> String {
        var buffer = [UInt16](repeating: 0, count: Int(MAX_PATH))
        let length = GetModuleFileNameW(nil, &buffer, DWORD(MAX_PATH))
        return String(decoding: buffer.prefix(Int(length)), as: UTF16.self)
    }
}
#endif
