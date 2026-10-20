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

    // Design: the Color tab, a color behind the screen.
    try t.clickText("Design");
    t.settle(0.1);
    try t.clickText("Color");
    t.settle(0.1);
    try std.testing.expect(t.hasText("Background") or t.containsText("BACKGROUND"));
    // The first color's swatch: a click picks it.
    a.project.?.edit();
    a.project.?.style.background_color = 0x3b6fb0;
    a.project.?.changed();
    t.settle(0.1);
    try t.screenshot("/tmp/nanostudio-editor-color.png");
    // Presets: Minimal's look.
    try t.clickText("Presets");
    t.settle(0.1);
    try std.testing.expect(t.hasText("Minimal") and t.hasText("Social vertical"));
    try t.clickText("Minimal");
    t.settle(0.1);
    try std.testing.expectEqual(@as(?u24, 0x16140f), a.project.?.style.background_color);
    try std.testing.expectEqual(@as(f32, 40), a.project.?.style.padding);
    // An empty zoom track: a click adds a zoom there.
    a.project.?.zooms.clearRetainingCapacity();
    a.project.?.changed();
    t.settle(0.1);
    try std.testing.expect(t.hasText("Click or drag to add zoom on cursor"));
    const hint = t.findText("Click or drag to add zoom on cursor").?;
    t.click(hint.x - 200, hint.y + hint.h / 2);
    t.settle(0.1);
    try std.testing.expectEqual(@as(usize, 1), a.project.?.zooms.items.len);
    a.project.?.undo();
    a.project.?.undo();

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

test "the capture bar: Display or Window; a window picked from the list" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const home = "/tmp/nanostudio-test-bar";
    std.Io.Dir.cwd().deleteTree(io, home) catch {};
    theme.apply(false);
    var a = try App.init(gpa, io, home);
    defer a.deinit();
    var t: ui.Tester = undefined;
    try t.init(gpa, .init(&a, @import("view_bar.zig").view), .{ .width = 800, .height = 376, .theme = theme.ui() });
    defer t.deinit();
    t.settle(0.1);
    try std.testing.expect(t.hasText("Display") and t.hasText("Window") and t.hasText("Record") and t.hasText("System audio"));
    try t.clickText("System audio");
    t.settle(0.1);
    try std.testing.expect(!a.recorder.system_audio);
    try t.screenshot("/tmp/nanostudio-bar.png");
    // Windows as ScreenCaptureKit would list them (no capture here).
    for ([_][2][]const u8{ .{ "Safari", "nanoui on GitHub" }, .{ "Zed", "capture.zig" } }, 0..) |w, i| {
        try a.recorder.windows.append(gpa, .{ .id = @intCast(100 + i), .app = try gpa.dupe(u8, w[0]), .title = try gpa.dupe(u8, w[1]), .width = 1200, .height = 800 });
    }
    a.bar_mode = .window;
    t.settle(0.1);
    try std.testing.expect(t.hasText("Pick a window below") and t.hasText("capture.zig"));
    try t.clickText("capture.zig");
    t.settle(0.1);
    try std.testing.expectEqual(@as(?u32, 101), a.bar_window);
    try std.testing.expectEqualStrings("Zed", a.barWindow().?.app);
    try t.screenshot("/tmp/nanostudio-bar-window.png");
}

test "a take that couldn't start says why across the card, in a narrow window too" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const home = "/tmp/nanostudio-test-failed";
    std.Io.Dir.cwd().deleteTree(io, home) catch {};
    theme.apply(false);
    var a = try App.init(gpa, io, home);
    defer a.deinit();
    a.screen_access = false;
    a.recorder.state = .failed;
    a.recorder.failure = "Screen Recording is off for nanostudio: allow it in System Settings, Privacy & Security, Screen & System Audio Recording.";
    var t: ui.Tester = undefined;
    try t.init(gpa, .init(&a, view.view), .{ .width = 900, .height = 760, .theme = theme.ui() });
    defer t.deinit();
    t.settle(0.2);
    try t.screenshot("/tmp/nanostudio-home-failed.png");
    // Words, not a column of letters; and the access card's buttons fit.
    const why = t.findText(a.recorder.failure) orelse return error.NoFailure;
    try std.testing.expect(why.w > 200 and why.h < 80);
    const again = t.findText("Check Again") orelse return error.NoButton;
    try std.testing.expect(again.x + again.w <= 900);
}
