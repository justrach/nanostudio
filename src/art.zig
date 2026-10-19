//! What the canvas draws besides the video, made once as pixels: the
//! cursor (the reference's arrow, its outline and shadow) in each style, a
//! background's gradient along the canvas's diagonal, and macOS wallpapers
//! decoded with ImageIO (HEIC included). All BGRA, premultiplied.
const std = @import("std");
const nanoui = @import("nanoui");
const style = @import("style.zig");
const av = @import("av.zig");

/// The arrow, in points, its tip at (0, 0) (the reference's cursor_path).
const arrow = [_][2]f32{ .{ 0, 0 }, .{ 0, 16.8 }, .{ 4, 13 }, .{ 6.9, 19.4 }, .{ 9.7, 18.2 }, .{ 6.9, 11.9 }, .{ 12.2, 11.9 } };
/// The cursor's art: pixels per point, and room around the arrow.
pub const cursor_px: f32 = 8;
pub const cursor_margin: f32 = 3;
pub const cursor_w: usize = @intFromFloat((12.2 + 2 * cursor_margin) * cursor_px);
pub const cursor_h: usize = @intFromFloat((19.4 + 2 * cursor_margin) * cursor_px);

fn inside(x: f32, y: f32) bool {
    var in = false;
    var j = arrow.len - 1;
    for (arrow, 0..) |p, i| {
        const q = arrow[j];
        if ((p[1] > y) != (q[1] > y) and x < (q[0] - p[0]) * (y - p[1]) / (q[1] - p[1]) + p[0]) in = !in;
        j = i;
    }
    return in;
}

fn edgeDistance(x: f32, y: f32) f32 {
    var best: f32 = 1e9;
    var j = arrow.len - 1;
    for (arrow, 0..) |p, i| {
        const q = arrow[j];
        const dx = q[0] - p[0];
        const dy = q[1] - p[1];
        const t = std.math.clamp(((x - p[0]) * dx + (y - p[1]) * dy) / (dx * dx + dy * dy), 0, 1);
        best = @min(best, std.math.hypot(x - (p[0] + t * dx), y - (p[1] + t * dy)));
        j = i;
    }
    return best;
}

fn over(dst: *[4]f32, rgb: [3]f32, a: f32) void {
    for (0..3) |k| dst[k] = rgb[k] * a + dst[k] * (1 - a);
    dst[3] = a + dst[3] * (1 - a);
}

/// The cursor in `which` style: `cursor_w` × `cursor_h`, the tip at
/// (`cursor_margin`, `cursor_margin`) points.
pub fn cursor(gpa: std.mem.Allocator, which: style.CursorStyle) ![]u8 {
    const fill: [3]f32 = switch (which) {
        .black => .{ 0, 0, 0 },
        .white => .{ 1, 1, 1 },
        .amber => .{ 232.0 / 255.0, 163.0 / 255.0, 61.0 / 255.0 },
    };
    const outline: [3]f32 = if (which == .black) .{ 1, 1, 1 } else .{ 0, 0, 0 };
    const out = try gpa.alloc(u8, cursor_w * cursor_h * 4);
    const ss = 3;
    for (0..cursor_h) |py| for (0..cursor_w) |px| {
        var acc: [4]f32 = .{ 0, 0, 0, 0 };
        for (0..ss) |sy| for (0..ss) |sx| {
            const x = (@as(f32, @floatFromInt(px)) + (@as(f32, @floatFromInt(sx)) + 0.5) / ss) / cursor_px - cursor_margin;
            const y = (@as(f32, @floatFromInt(py)) + (@as(f32, @floatFromInt(sy)) + 0.5) / ss) / cursor_px - cursor_margin;
            var c: [4]f32 = .{ 0, 0, 0, 0 };
            if (inside(x - 0.4, y - 1.2) or edgeDistance(x - 0.4, y - 1.2) < 1.2) over(&c, .{ 0, 0, 0 }, 0.28);
            if (edgeDistance(x, y) < 1.2) over(&c, outline, 1);
            if (inside(x, y)) over(&c, fill, 1);
            for (0..4) |k| acc[k] += c[k] / (ss * ss);
        };
        const i = (py * cursor_w + px) * 4;
        out[i + 0] = @intFromFloat(@round(acc[2] * 255));
        out[i + 1] = @intFromFloat(@round(acc[1] * 255));
        out[i + 2] = @intFromFloat(@round(acc[0] * 255));
        out[i + 3] = @intFromFloat(@round(acc[3] * 255));
    };
    return out;
}

pub const gradient_size = 64;

/// A gradient from `bg.from` at the top left to `bg.to` at the bottom
/// right of a `w` × `h` canvas, as the reference's shader mixes it.
pub fn gradient(buf: *[gradient_size * gradient_size * 4]u8, bg: style.Background, w: f32, h: f32) void {
    const from = nanoui.ui.Color.hex(bg.from);
    const to = nanoui.ui.Color.hex(bg.to);
    const n: f32 = gradient_size - 1;
    for (0..gradient_size) |y| for (0..gradient_size) |x| {
        const u = @as(f32, @floatFromInt(x)) / n;
        const v = @as(f32, @floatFromInt(y)) / n;
        const k = std.math.clamp((u * w * w + v * h * h) / (w * w + h * h), 0, 1);
        const c = from.mix(to, k);
        const i = (y * gradient_size + x) * 4;
        buf[i + 0] = @intFromFloat(@round(c.b * 255));
        buf[i + 1] = @intFromFloat(@round(c.g * 255));
        buf[i + 2] = @intFromFloat(@round(c.r * 255));
        buf[i + 3] = 255;
    };
}

extern "c" fn CGImageSourceCreateWithURL(url: av.Object, options: ?av.Object) ?*anyopaque;
extern "c" fn CGImageSourceCreateThumbnailAtIndex(src: *anyopaque, index: usize, options: ?av.Object) ?*anyopaque;
extern "c" fn CGImageGetWidth(img: *anyopaque) usize;
extern "c" fn CGImageGetHeight(img: *anyopaque) usize;
extern "c" fn CGColorSpaceCreateDeviceRGB() ?*anyopaque;
extern "c" fn CGBitmapContextCreate(data: ?*anyopaque, w: usize, h: usize, bits: usize, row: usize, space: ?*anyopaque, info: u32) ?*anyopaque;
extern "c" fn CGContextDrawImage(ctx: *anyopaque, rect: av.CGRect, img: *anyopaque) void;
extern "c" const kCGImageSourceCreateThumbnailFromImageAlways: av.Object;
extern "c" const kCGImageSourceThumbnailMaxPixelSize: av.Object;
extern "c" const kCGImageSourceCreateThumbnailWithTransform: av.Object;

pub const Picture = struct { bgra: []u8, width: u32, height: u32 };

/// The picture at `path` (any format ImageIO reads), its long side at
/// most `max`.
pub fn decode(gpa: std.mem.Allocator, path: []const u8, max: usize) !Picture {
    const objc = av.objc;
    const pool = objc.Pool.push();
    defer pool.pop();
    const src = CGImageSourceCreateWithURL(av.fileUrl(path), null) orelse return error.Unreadable;
    defer av.CFRelease(src);
    const opts = av.dict(&.{ kCGImageSourceCreateThumbnailFromImageAlways, kCGImageSourceThumbnailMaxPixelSize, kCGImageSourceCreateThumbnailWithTransform }, &.{ av.number(true), av.number(max), av.number(true) });
    const img = CGImageSourceCreateThumbnailAtIndex(src, 0, opts) orelse return error.Undecodable;
    defer av.CFRelease(img);
    const w = CGImageGetWidth(img);
    const h = CGImageGetHeight(img);
    const bgra = try gpa.alloc(u8, w * h * 4);
    errdefer gpa.free(bgra);
    const space = CGColorSpaceCreateDeviceRGB();
    defer if (space) |s| av.CFRelease(s);
    // Premultiplied first, little endian: BGRA in memory.
    const ctx = CGBitmapContextCreate(bgra.ptr, w, h, 8, w * 4, space, 2 | (2 << 12)) orelse return error.Context;
    defer av.CFRelease(ctx);
    CGContextDrawImage(ctx, .{ .origin = .{ .x = 0, .y = 0 }, .size = .{ .width = @floatFromInt(w), .height = @floatFromInt(h) } }, img);
    return .{ .bgra = bgra, .width = @intCast(w), .height = @intCast(h) };
}

test "the cursor's art: its fill inside, its outline at the edge, clear outside" {
    const gpa = std.testing.allocator;
    for (style.CursorStyle.all) |which| {
        const px = try cursor(gpa, which);
        defer gpa.free(px);
        // Inside the arrow's body, at (3, 9) points.
        const ix: usize = @intFromFloat((3 + cursor_margin) * cursor_px);
        const iy: usize = @intFromFloat((9 + cursor_margin) * cursor_px);
        const in = px[(iy * cursor_w + ix) * 4 ..][0..4];
        try std.testing.expectEqual(@as(u8, 255), in[3]);
        switch (which) {
            .black => try std.testing.expect(in[2] < 10),
            .white => try std.testing.expect(in[2] > 245),
            .amber => try std.testing.expect(in[2] > 220 and in[0] < 80),
        }
        // Far from it (bottom right corner): clear.
        try std.testing.expectEqual(@as(u8, 0), px[(cursor_w * cursor_h - 1) * 4 + 3]);
    }
}
