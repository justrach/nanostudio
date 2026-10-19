//! A recording opened, edited (a cut, a faster clip) and exported: the
//! file is the canvas's size and the timeline's length, and each frame
//! shows the source time the timeline maps it to. And undo, redo, save.
const std = @import("std");
const av = @import("av.zig");
const reader = @import("reader.zig");
const testvideo = @import("testvideo.zig");
const Project = @import("project.zig").Project;
const Export = @import("export.zig").Export;
const canvas = @import("canvas.zig");

fn redAt(pb: av.CVPixelBufferRef, x: usize, y: usize) u8 {
    _ = av.CVPixelBufferLockBaseAddress(pb, 1);
    defer _ = av.CVPixelBufferUnlockBaseAddress(pb, 1);
    const base = av.CVPixelBufferGetBaseAddress(pb).?;
    return base[y * av.CVPixelBufferGetBytesPerRow(pb) + x * 4 + 2];
}

test "an edited recording exports at the canvas's size and the timeline's length" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const dir = "/tmp/nanostudio-test-export";
    try testvideo.recording(gpa, io, dir, 3);
    const p = try Project.open(gpa, io, dir);
    defer p.deinit();
    // A fresh recording: zooms from its click (at 1.5 s), one clip.
    try std.testing.expectEqual(@as(usize, 1), p.zooms.items.len);
    try std.testing.expectEqual(@as(usize, 1), p.timeline.slices.items.len);
    // Cut 1.0 to 2.0, and play the last clip at 2x.
    p.edit();
    _ = p.timeline.split(gpa, 1.0);
    _ = p.timeline.split(gpa, 2.0);
    try std.testing.expect(p.timeline.remove(1));
    p.timeline.slices.items[1].speed = 2;
    p.style.padding = 0;
    p.style.radius = 0;
    p.style.cursor_visible = false;
    p.zooms.clearRetainingCapacity();
    p.changed();
    try std.testing.expectApproxEqAbs(@as(f64, 1.5), p.duration(), 1e-9);
    // Undo comes back to one clip; redo to the edit.
    p.undo();
    try std.testing.expectEqual(@as(usize, 1), p.timeline.slices.items.len);
    p.redo();
    try std.testing.expectEqual(@as(usize, 2), p.timeline.slices.items.len);
    try p.save();

    const out = dir ++ "/export.mp4";
    const e = try Export.start(gpa, p, out, 200);
    defer e.deinit();
    while (!e.step(10)) {}
    try std.testing.expectEqual(@as(?[]const u8, null), e.failed);
    const i = try reader.info(out);
    // The recording's shape (320 × 200) with a short side of 200.
    try std.testing.expectEqual(@as(u32, 320), i.width);
    try std.testing.expectEqual(@as(u32, 200), i.height);
    try std.testing.expectApproxEqAbs(@as(f64, 1.5), i.duration, 0.1);
    // Output 1.25 s is 0.25 into the 2x clip: source 2.5 s.
    var r = try reader.Reader.open(out, 1.25);
    defer r.deinit();
    const pb = r.at(1.25) orelse return error.NoFrame;
    const got = redAt(pb, 4, 4);
    try std.testing.expect(@abs(@as(i32, got) - testvideo.redOf(2.5)) <= 12);

    // Saved: opened again, the edit is there.
    const again = try Project.open(gpa, io, dir);
    defer again.deinit();
    try std.testing.expectEqual(@as(usize, 2), again.timeline.slices.items.len);
    try std.testing.expectEqual(@as(f64, 2), again.timeline.slices.items[1].speed);
    _ = canvas;
}
