//! The library's recordings as the home screen lists them: each folder's
//! name, when it was made, how long it runs, and a small picture of it
//! (AVAssetImageGenerator, 320 pixels wide, made when first shown).
const std = @import("std");
const av = @import("av.zig");
const rec = @import("recording.zig");
const objc = av.objc;

pub const Entry = struct {
    dir: []const u8,
    /// "Oct 20, 14:32", from the folder's name (recording-<unix seconds>).
    when: []const u8,
    duration: f64,
    width: u32,
    height: u32,
    thumb: ?Thumb = null,
    thumb_tried: bool = false,
};

pub const Thumb = struct { bgra: []u8, width: u32, height: u32 };

const months = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };

const Tm = extern struct { sec: c_int, min: c_int, hour: c_int, mday: c_int, mon: c_int, year: c_int, wday: c_int, yday: c_int, isdst: c_int, gmtoff: c_long, zone: ?[*:0]const u8 };
extern "c" fn localtime_r(t: *const i64, out: *Tm) ?*Tm;
extern "c" fn time(t: ?*i64) i64;

/// This machine's offset from UTC now, in seconds.
pub fn localOffset() i64 {
    const now = time(null);
    var tm: Tm = undefined;
    _ = localtime_r(&now, &tm) orelse return 0;
    return tm.gmtoff;
}

/// "Oct 20, 14:32" for a recording-<seconds> folder (`offset` seconds
/// from UTC), else its name.
pub fn when(arena: std.mem.Allocator, dir: []const u8, offset: i64) []const u8 {
    const name = std.fs.path.basename(dir);
    const prefix = "recording-";
    if (!std.mem.startsWith(u8, name, prefix)) return name;
    const secs = std.fmt.parseInt(i64, name[prefix.len..], 10) catch return name;
    const es: std.time.epoch.EpochSeconds = .{ .secs = @intCast(@max(0, secs + offset)) };
    const day = es.getEpochDay().calculateYearDay();
    const md = day.calculateMonthDay();
    const ds = es.getDaySeconds();
    return std.fmt.allocPrint(arena, "{s} {d}, {d:0>2}:{d:0>2}", .{ months[@intFromEnum(md.month) - 1], md.day_index + 1, ds.getHoursIntoDay(), ds.getMinutesIntoHour() }) catch name;
}

/// The library's recordings, newest first (their metadata read now).
pub fn load(arena: std.mem.Allocator, io: std.Io, dir: []const u8) ![]Entry {
    const dirs = try rec.list(arena, io, dir);
    const offset = localOffset();
    var out: std.ArrayList(Entry) = .empty;
    for (dirs) |d| {
        const r = rec.load(arena, io, d) catch continue;
        try out.append(arena, .{ .dir = d, .when = when(arena, d, offset), .duration = r.duration, .width = r.width, .height = r.height });
    }
    return out.items;
}

extern "c" fn CGImageGetWidth(img: *anyopaque) usize;
extern "c" fn CGImageGetHeight(img: *anyopaque) usize;
extern "c" fn CGColorSpaceCreateDeviceRGB() ?*anyopaque;
extern "c" fn CGBitmapContextCreate(data: ?*anyopaque, w: usize, h: usize, bits: usize, row: usize, space: ?*anyopaque, info: u32) ?*anyopaque;
extern "c" fn CGContextDrawImage(ctx: *anyopaque, rect: av.CGRect, img: *anyopaque) void;

/// A picture of the video at `path` a second in, 320 pixels wide at most.
pub fn thumbnail(gpa: std.mem.Allocator, path: []const u8, duration: f64) ?Thumb {
    const pool = objc.Pool.push();
    defer pool.pop();
    const asset = objc.msg(av.Object, objc.class("AVURLAsset"), "URLAssetWithURL:options:", .{ av.fileUrl(path), @as(?av.Object, null) });
    const gen = objc.msg(av.Object, objc.class("AVAssetImageGenerator"), "assetImageGeneratorWithAsset:", .{asset});
    objc.msg(void, gen, "setMaximumSize:", .{av.CGSize{ .width = 320, .height = 320 }});
    objc.msg(void, gen, "setAppliesPreferredTrackTransform:", .{true});
    var actual: av.CMTime = undefined;
    var err: ?av.Object = null;
    const img = objc.msg(?*anyopaque, gen, "copyCGImageAtTime:actualTime:error:", .{ av.CMTime.of(@min(1, duration / 2)), &actual, &err }) orelse return null;
    defer av.CFRelease(img);
    const w = CGImageGetWidth(img);
    const h = CGImageGetHeight(img);
    const bgra = gpa.alloc(u8, w * h * 4) catch return null;
    const space = CGColorSpaceCreateDeviceRGB();
    defer if (space) |s| av.CFRelease(s);
    const ctx = CGBitmapContextCreate(bgra.ptr, w, h, 8, w * 4, space, 2 | (2 << 12)) orelse {
        gpa.free(bgra);
        return null;
    };
    defer av.CFRelease(ctx);
    CGContextDrawImage(ctx, .{ .origin = .{ .x = 0, .y = 0 }, .size = .{ .width = @floatFromInt(w), .height = @floatFromInt(h) } }, img);
    return .{ .bgra = bgra, .width = @intCast(w), .height = @intCast(h) };
}

test "a recording's folder name says when it was made" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    // 2026-10-20 06:32 UTC.
    try std.testing.expectEqualStrings("Oct 20, 06:32", when(arena.allocator(), "/x/recording-1792477920", 0));
    try std.testing.expectEqualStrings("Oct 20, 14:32", when(arena.allocator(), "/x/recording-1792477920", 8 * 3600));
    try std.testing.expectEqualStrings("my take", when(arena.allocator(), "/x/my take", 0));
}
