//! Videos made for the tests, never captured: frames whose gray tells the
//! time (it lightens second by second: gray survives the codec's 4:2:0
//! colors, where a saturated red does not) with a white square sliding across,
//! written with the app's own writer, and a recording.json beside them.
const std = @import("std");
const av = @import("av.zig");
const writer = @import("writer.zig");
const rec = @import("recording.zig");

pub const width = 320;
pub const height = 200;
pub const fps = 30;

/// The level that tells time `t`: 40, and 60 more a second.
pub fn redOf(t: f64) u8 {
    return @intFromFloat(@min(255, 40 + t * 60));
}

/// The frame at time `t`.
pub fn frame(buf: []u8, t: f64) void {
    const red = redOf(t);
    const box_x: usize = @intFromFloat(@mod(t * 60, width - 40));
    for (0..height) |y| for (0..width) |x| {
        const i = (y * width + x) * 4;
        const white = x >= box_x and x < box_x + 40 and y >= 80 and y < 120;
        buf[i + 0] = if (white) 255 else red;
        buf[i + 1] = if (white) 255 else red;
        buf[i + 2] = if (white) 255 else red;
        buf[i + 3] = 255;
    };
}

/// screen.mp4 of `seconds` in `dir`.
pub fn video(gpa: std.mem.Allocator, dir: []const u8, seconds: f64) !void {
    const path = try std.fs.path.join(gpa, &.{ dir, "screen.mp4" });
    defer gpa.free(path);
    var w = try writer.Writer.create(path, .{ .width = width, .height = height, .fps = fps });
    defer w.deinit();
    const buf = try gpa.alloc(u8, width * height * 4);
    defer gpa.free(buf);
    const n: usize = @intFromFloat(seconds * fps);
    for (0..n) |i| {
        const t = @as(f64, @floatFromInt(i)) / fps;
        frame(buf, t);
        if (!w.appendBgra(buf, width * 4, t)) return error.Append;
    }
    try w.finish();
}

/// A recording folder: the video and a recording.json whose cursor moves
/// to (0.25, 0.4), clicks at 1.5 s, and rests.
pub fn recording(gpa: std.mem.Allocator, io: std.Io, dir: []const u8, seconds: f64) !void {
    std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    try std.Io.Dir.cwd().createDirPath(io, dir);
    try video(gpa, dir, seconds);
    var cursor: std.ArrayList(rec.CursorSample) = .empty;
    defer cursor.deinit(gpa);
    var t: f64 = 0;
    while (t < seconds) : (t += 1.0 / 60.0) {
        const k: f32 = @floatCast(@min(1, t / 1.2));
        try cursor.append(gpa, .{ .t = t, .x = 0.5 - 0.25 * k, .y = 0.5 - 0.1 * k, .down = t >= 1.5 and t < 1.6 });
    }
    try rec.save(gpa, io, dir, .{ .width = width, .height = height, .fps = fps, .duration = seconds, .points_width = width / 2, .cursor = cursor.items });
}
