//! Videos made for the tests, never captured: frames whose gray tells the
//! time (it lightens second by second: gray survives the codec's 4:2:0
//! colors, where a saturated red does not) with a white square sliding across,
//! written with the app's own writer, and a recording.json beside them.
//! With sound: a 440 Hz tone whose loudness tells the time the same way.
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

/// The tone's loudness (RMS, 0 to 1) at time `t`.
pub fn loudnessOf(t: f64) f64 {
    return (0.1 + 0.2 * t) / std.math.sqrt2;
}

/// The tone from `t` for `frames` samples (48 kHz stereo), as a sample buffer.
fn tone(format: *anyopaque, t: f64, frames: usize) !av.CMSampleBufferRef {
    var pcm: [1600 * 2]i16 = undefined;
    for (0..frames) |i| {
        const s = t + @as(f64, @floatFromInt(i)) / 48000;
        const v: i16 = @intFromFloat(@sin(s * 440 * 2 * std.math.pi) * (0.1 + 0.2 * s) * 32767);
        pcm[2 * i] = v;
        pcm[2 * i + 1] = v;
    }
    var block: ?*anyopaque = null;
    if (av.CMBlockBufferCreateWithMemoryBlock(null, null, frames * 4, null, null, 0, frames * 4, 1, &block) != 0) return error.Audio;
    defer av.CFRelease(block.?);
    if (av.CMBlockBufferReplaceDataBytes(&pcm, block.?, 0, frames * 4) != 0) return error.Audio;
    var sb: ?av.CMSampleBufferRef = null;
    if (av.CMAudioSampleBufferCreateReadyWithPacketDescriptions(null, block.?, format, @intCast(frames), av.CMTime.of(t), null, &sb) != 0) return error.Audio;
    return sb.?;
}

const Feed = struct {
    w: *writer.Writer,
    format: *anyopaque,
    t: f64 = 0,
    until: f64 = 0,
    end: f64,
    forced: bool = false,

    /// Appends the next buffer up to `until` (or past it when the writer asks).
    fn more(f: *Feed) bool {
        if (f.t >= f.end - 0.5 / @as(f64, fps)) return false;
        if (f.t >= f.until and !f.forced) return false;
        const sb = tone(f.format, f.t, 48000 / fps) catch return false;
        defer av.CFRelease(sb);
        if (!f.w.appendAudio(0, sb)) return false;
        f.t += 1.0 / @as(f64, fps);
        return true;
    }

    fn call(ctx: *anyopaque) bool {
        const f: *Feed = @ptrCast(@alignCast(ctx));
        f.forced = true;
        defer f.forced = false;
        return f.more();
    }
};

/// screen.mp4 of `seconds` in `dir`.
pub fn video(gpa: std.mem.Allocator, dir: []const u8, seconds: f64) !void {
    return videoWith(gpa, dir, seconds, false);
}

/// screen.mp4 of `seconds` in `dir`, with the tone when `sound`.
pub fn videoWith(gpa: std.mem.Allocator, dir: []const u8, seconds: f64, sound: bool) !void {
    const path = try std.fs.path.join(gpa, &.{ dir, "screen.mp4" });
    defer gpa.free(path);
    var w = try writer.Writer.create(path, .{ .width = width, .height = height, .fps = fps, .audio_tracks = @intFromBool(sound) });
    defer w.deinit();
    const asbd: av.AudioStreamBasicDescription = .{ .sample_rate = 48000, .format_id = av.lpcm, .format_flags = 4 | 8, .bytes_per_packet = 4, .frames_per_packet = 1, .bytes_per_frame = 4, .channels_per_frame = 2, .bits_per_channel = 16 };
    var format: ?*anyopaque = null;
    if (av.CMAudioFormatDescriptionCreate(null, &asbd, 0, null, 0, null, null, &format) != 0) return error.Audio;
    defer av.CFRelease(format.?);
    const buf = try gpa.alloc(u8, width * height * 4);
    defer gpa.free(buf);
    const n: usize = @intFromFloat(seconds * fps);
    // The tone, a little ahead of the frames, and more when the writer asks.
    var feed: Feed = .{ .w = &w, .format = format.?, .end = seconds };
    if (sound) w.feeder = .{ .ctx = &feed, .more = Feed.call };
    for (0..n) |i| {
        const t = @as(f64, @floatFromInt(i)) / fps;
        frame(buf, t);
        if (sound) {
            w.startAt(0);
            feed.until = t + 0.2;
            while (feed.more()) {}
        }
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
