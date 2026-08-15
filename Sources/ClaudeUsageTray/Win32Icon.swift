#if os(Windows)
import WinSDK

/// `RGB` is a C preprocessor macro (`(BYTE)(r) | ((WORD)(g) << 8) |
/// ((DWORD)(b) << 16)` from wingdi.h) — macros do not import into Swift, so
/// the WinSDK overlay does not expose one. Reimplemented directly.
private func RGB(_ r: BYTE, _ g: BYTE, _ b: BYTE) -> COLORREF {
    COLORREF(r) | (COLORREF(g) << 8) | (COLORREF(b) << 16)
}

/// `Shell_NotifyIcon` gives you a 16x16 icon and a tooltip — there is no
/// equivalent of NSStatusItem's title, so Windows cannot show "37%" as text
/// beside an icon. It draws the number into the icon instead, which is what
/// every battery and CPU percentage tray app on Windows does.
///
/// The caller owns the returned HICON and MUST DestroyIcon it once replaced.
/// This runs once a minute; leaking one GDI handle per call would matter
/// within hours.
enum Win32Icon {
    static let size: Int32 = 32

    static func make(percent: Int?, critical: Bool, stale: Bool) -> HICON? {
        let screen = GetDC(nil)
        defer { _ = ReleaseDC(nil, screen) }
        guard let memDC = CreateCompatibleDC(screen) else { return nil }
        defer { _ = DeleteDC(memDC) }

        var info = BITMAPINFO()
        info.bmiHeader.biSize = DWORD(MemoryLayout<BITMAPINFOHEADER>.size)
        info.bmiHeader.biWidth = size
        info.bmiHeader.biHeight = -size          // top-down
        info.bmiHeader.biPlanes = 1
        info.bmiHeader.biBitCount = 32
        info.bmiHeader.biCompression = DWORD(BI_RGB)

        var bits: UnsafeMutableRawPointer?
        guard let colour = CreateDIBSection(memDC, &info, UINT(DIB_RGB_COLORS), &bits, nil, 0)
        else { return nil }
        defer { _ = DeleteObject(colour) }

        // A 1bpp AND-mask is required by CreateIconIndirect. CreateBitmap's
        // documented contract is that when lpvBits is NULL the bitmap's
        // initial contents are UNDEFINED, not zeroed — passing NULL (as an
        // earlier version of this code did) hands CreateIconIndirect garbage
        // AND-mask bits that punch out or invert arbitrary pixels,
        // differently per allocation. Pass an explicitly zeroed buffer
        // instead, so every mask bit is 0 ("not masked out") and the alpha
        // channel in the colour bitmap does all the transparency work.
        // Scanlines for a 1bpp bitmap are WORD-aligned: at `size` == 32,
        // that's 32 bits == 4 bytes per row already, so no row padding is
        // needed beyond the natural byte count.
        let maskStride = ((Int(size) + 15) / 16) * 2
        let maskBytes = [UInt8](repeating: 0, count: maskStride * Int(size))
        guard let mask = maskBytes.withUnsafeBytes({ raw in
            CreateBitmap(size, size, 1, 1, raw.baseAddress)
        }) else { return nil }
        defer { _ = DeleteObject(mask) }

        let old = SelectObject(memDC, colour)

        let text: String
        if let percent { text = String(percent) } else { text = "—" }

        let font = CreateFontW(
            /* height */ -20, 0, 0, 0, FW_SEMIBOLD, 0, 0, 0,
            DWORD(DEFAULT_CHARSET), DWORD(OUT_DEFAULT_PRECIS), DWORD(CLIP_DEFAULT_PRECIS),
            DWORD(CLEARTYPE_QUALITY), DWORD(DEFAULT_PITCH) | DWORD(FF_DONTCARE),
            "Segoe UI".wide
        )
        defer { _ = DeleteObject(font) }
        let oldFont = SelectObject(memDC, font)
        defer { _ = SelectObject(memDC, oldFont) }

        SetBkMode(memDC, TRANSPARENT)
        // Critical wins over stale: a near-limit warning must not be softened.
        let colourRef: COLORREF = critical ? RGB(232, 74, 74)
            : (stale ? RGB(140, 140, 140) : RGB(255, 255, 255))
        SetTextColor(memDC, colourRef)

        var rect = RECT(left: 0, top: 0, right: size, bottom: size)
        _ = DrawTextW(
            memDC, text.wide, -1, &rect,
            UINT(DT_CENTER) | UINT(DT_VCENTER) | UINT(DT_SINGLELINE)
        )

        // GDI batches drawing calls per thread rather than executing them
        // immediately, and CreateDIBSection's documented contract is that
        // callers who read or write the bitmap's bits directly (as the alpha
        // loop below does) MUST call GdiFlush() first — otherwise DrawTextW's
        // writes may not yet be visible to this process's own memory reads.
        // Whether that race is observable depends on the GDI batch limit, the
        // thread's pending-call count, and timing, none of which this
        // environment's CI can exercise: it would compile and link fine, and
        // could still render a blank icon on a real machine.
        GdiFlush()

        // DrawTextW leaves alpha at 0 on a 32bpp DIB, which renders the glyph
        // fully transparent. Force alpha opaque wherever a pixel was written.
        if let bits {
            let pixels = bits.assumingMemoryBound(to: UInt32.self)
            for i in 0..<Int(size * size) where pixels[i] & 0x00FF_FFFF != 0 {
                pixels[i] |= 0xFF00_0000
            }
        }

        // CreateIconIndirect copies from hbmColor/hbmMask by value, but a
        // bitmap still selected into a DC is not a valid source for that copy
        // — deselect `colour` from `memDC` (restoring the DC's original
        // bitmap) before handing it to CreateIconIndirect, rather than
        // leaving that to the `defer` below, which would only run AFTER
        // CreateIconIndirect has already read (or failed to read) the
        // bitmap.
        _ = SelectObject(memDC, old)

        var iconInfo = ICONINFO(
            fIcon: true, xHotspot: 0, yHotspot: 0, hbmMask: mask, hbmColor: colour
        )
        return CreateIconIndirect(&iconInfo)
    }
}

extension String {
    /// UTF-16, NUL-terminated, for the -W Win32 entry points. `public`: also
    /// used from `WindowsLoginItem` in the `ClaudeUsageBar` target.
    public var wide: [UInt16] { Array(utf16) + [0] }
}
#endif
