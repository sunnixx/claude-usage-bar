#if os(Windows)
import WinSDK

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

        // A 1bpp mask is required by CreateIconIndirect. Left all-zero so every
        // pixel is opaque and the alpha in the colour bitmap does the work.
        guard let mask = CreateBitmap(size, size, 1, 1, nil) else { return nil }
        defer { _ = DeleteObject(mask) }

        let old = SelectObject(memDC, colour)
        defer { _ = SelectObject(memDC, old) }

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

        // DrawTextW leaves alpha at 0 on a 32bpp DIB, which renders the glyph
        // fully transparent. Force alpha opaque wherever a pixel was written.
        if let bits {
            let pixels = bits.assumingMemoryBound(to: UInt32.self)
            for i in 0..<Int(size * size) where pixels[i] & 0x00FF_FFFF != 0 {
                pixels[i] |= 0xFF00_0000
            }
        }

        var iconInfo = ICONINFO(
            fIcon: true, xHotspot: 0, yHotspot: 0, hbmMask: mask, hbmColor: colour
        )
        return CreateIconIndirect(&iconInfo)
    }
}

extension String {
    /// UTF-16, NUL-terminated, for the -W Win32 entry points.
    var wide: [UInt16] { Array(utf16) + [0] }
}
#endif
