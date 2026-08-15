import Testing
@testable import ClaudeUsageCore
@testable import ClaudeUsageTray

/// `Win32MenuLine.compose` is the piece of Windows display logic that
/// escaped the tested core once already — it silently dropped `row.bar`
/// until this review caught it. It is pulled out of `Win32Tray` (which is
/// `#if os(Windows)`-only, and therefore invisible to `@testable import` on
/// the platforms these tests actually run on) precisely so it can be
/// covered here on every CI job.
struct Win32MenuLineTests {
    @Test func fullRowIncludesAllFields() {
        let row = MenuRow(label: "Session (5h)", percent: 37, bar: "███░░░░░░░", reset: "resets 2:15 PM")
        let line = Win32MenuLine.compose(row)

        #expect(line == "Session (5h)   37%   ███░░░░░░░   resets 2:15 PM")
    }

    @Test func indentedRowPrefixesTheLabel() {
        let row = MenuRow(label: "Opus", percent: 12, bar: "█░░░░░░░░░", reset: "resets Mon", isIndented: true)
        let line = Win32MenuLine.compose(row)

        #expect(line == "    Opus   12%   █░░░░░░░░░   resets Mon")
    }

    @Test func messageOnlyRowOmitsAbsentFields() {
        let row = MenuRow(label: "Loading…")
        let line = Win32MenuLine.compose(row)

        #expect(line == "Loading…")
    }

    /// A section header row (`isSectionHeader`) carries no percent, bar or
    /// reset — same shape as a message-only row — so it must pass through
    /// `compose` as its bare label, unchanged, with no stray padding or
    /// separators. This is what lets `Win32Tray.showMenu` add it with plain
    /// `MF_STRING | MF_GRAYED` and no special-casing.
    @Test func sectionHeaderRowPassesThroughUnchanged() {
        let row = MenuRow(label: "CODEX · Free", isSectionHeader: true)
        let line = Win32MenuLine.compose(row)

        #expect(line == "CODEX · Free")
    }
}
