//! Video out and in: a video written with the app's writer reads back with
//! its reader, the right size, rate and length, each frame at its time.
const std = @import("std");
const av = @import("av.zig");
const reader = @import("reader.zig");
const testvideo = @import("testvideo.zig");

fn redAt(pb: av.CVPixelBufferRef, x: usize, y: usize) u8 {
    _ = av.CVPixelBufferLockBaseAddress(pb, 1);
    defer _ = av.CVPixelBufferUnlockBaseAddress(pb, 1);
    const base = av.CVPixelBufferGetBaseAddress(pb).?;
    return base[y * av.CVPixelBufferGetBytesPerRow(pb) + x * 4 + 2];
}

fn near(got: u8, want: u8) !void {
    if (@abs(@as(i32, got) - want) > 8) {
        std.debug.print("red {d}, wanted {d}\n", .{ got, want });
        return error.TestUnexpectedResult;
    }
}

test "a video written reads back, each frame at its time" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const dir = "/tmp/nanostudio-test-video";
    std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    try std.Io.Dir.cwd().createDirPath(io, dir);
    try testvideo.video(gpa, dir, 2);
    const path = dir ++ "/screen.mp4";
    const i = try reader.info(path);
    try std.testing.expectEqual(@as(u32, testvideo.width), i.width);
    try std.testing.expectEqual(@as(u32, testvideo.height), i.height);
    try std.testing.expectApproxEqAbs(@as(f32, 30), i.fps, 0.5);
    try std.testing.expectApproxEqAbs(@as(f64, 2), i.duration, 0.05);

    var r = try reader.Reader.open(path, 0);
    defer r.deinit();
    // Red tells the time (testvideo.redOf), to the codec's rounding.
    const early = r.at(0.5) orelse return error.NoFrame;
    try near(redAt(early, 4, 4), testvideo.redOf(0.5));
    const later = r.at(1.5) orelse return error.NoFrame;
    try near(redAt(later, 4, 4), testvideo.redOf(1.5));
    // Behind where it read: it can't go back.
    try std.testing.expect(!r.reaches(0.5));

    // Opened at 1.0 s: the first frame is there.
    var r2 = try reader.Reader.open(path, 1.0);
    defer r2.deinit();
    const at1 = r2.at(1.0) orelse return error.NoFrame;
    try near(redAt(at1, 4, 4), testvideo.redOf(1.0));
}
