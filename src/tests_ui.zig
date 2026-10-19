//! The app through its views, in ui.Tester (offscreen, no window): the
//! home screen lists the library's recording, a click opens it in the
//! editor, the preview shows its frame, the inspector's tabs switch, S
//! splits the clip under the playhead, and Export writes the file.
//! HOME is a temporary folder; nothing records the screen.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const App = @import("app.zig").App;
const view = @import("view.zig");
const theme = @import("theme.zig");
const testvideo = @import("testvideo.zig");

test "the library, the editor, a split and an export, through the views" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const home = "/tmp/nanostudio-test-ui";
    std.Io.Dir.cwd().deleteTree(io, home) catch {};
    const dir = home ++ "/Movies/Shitty Screen Studio/recording-1792477920";
    try testvideo.recording(gpa, io, dir, 3);
    theme.apply(true);
    var a = try App.init(gpa, io, home);
    defer a.deinit();
    var t: ui.Tester = undefined;
    try t.init(gpa, .init(&a, view.view), .{ .width = 1240, .height = 820, .theme = theme.ui() });
    defer t.deinit();
    t.settle(0.3);
    try std.testing.expect(t.hasText("Ready when you are."));
    try std.testing.expect(t.hasText("Start recording"));
    try std.testing.expectEqual(@as(usize, 1), a.entries.len);
    try t.screenshot("/tmp/nanostudio-home.png");

    // The recording, by when it was made: opened in the editor.
    try t.clickText(a.entries[0].when);
    t.settle(0.3);
    try std.testing.expect(a.project != null);
    try std.testing.expect(t.hasText("Export…") and t.hasText("VIDEO") and t.hasText("ZOOMS"));
    // Its click at 1.5 s made a zoom.
    try std.testing.expectEqual(@as(usize, 1), a.project.?.zooms.items.len);
    a.player.?.seek(1.8, a.project.?.timeline);
    t.settle(0.3);
    try t.screenshot("/tmp/nanostudio-editor.png");
    try t.clickText("Motion & Cursor");
    t.settle(0.2);
    try std.testing.expect(t.hasText("Cursor smoothing") and t.hasText("Auto from Clicks"));
    try t.screenshot("/tmp/nanostudio-editor-motion.png");

    // S splits the clip under the playhead (1.8 s).
    t.typeText("s");
    t.settle(0.1);
    try std.testing.expectEqual(@as(usize, 2), a.project.?.timeline.slices.items.len);
    try std.testing.expect(t.hasText("Clip 2 of 2") or t.containsText("CLIP 2 OF 2"));
    // ⌘Z undoes it.
    _ = t.shortcut(.{ .key = 'z', .cmd = true });
    t.settle(0.1);
    try std.testing.expectEqual(@as(usize, 1), a.project.?.timeline.slices.items.len);

    // Export, run to its end.
    try t.clickText("Export…");
    var waited: f64 = 0;
    while (a.exporting != null) : (waited += 0.02) {
        if (waited > 60) return error.Timeout;
        nanoui.runFor(0.02);
        t.frame();
    }
    try std.testing.expectEqual(@as(?[]const u8, null), a.export_failed);
    try std.testing.expect(a.exported != null);
    t.settle(0.1);
    try std.testing.expect(t.hasText("Export finished"));
    try std.Io.Dir.cwd().access(io, dir ++ "/export.mp4", .{});

    // Back to the library: the edits were saved.
    try t.clickText("Library");
    t.settle(0.2);
    try std.testing.expect(a.project == null and t.hasText("Ready when you are."));
}
