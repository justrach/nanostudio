//! Video in: an AVAssetReader decoding a file's frames in order from a
//! start time, as BGRA pixel buffers Metal can wrap (so the preview shows
//! them without a copy). Going back means opening again where to start.
const std = @import("std");
const av = @import("av.zig");
const objc = av.objc;

pub const Info = struct { width: u32, height: u32, fps: f32, duration: f64 };

fn videoTrack(a: av.Object) ?av.Object {
    const tracks = objc.msg(av.Object, a, "tracksWithMediaType:", .{av.AVMediaTypeVideo});
    if (objc.msg(objc.NSUInteger, tracks, "count", .{}) == 0) return null;
    return objc.msg(av.Object, tracks, "objectAtIndex:", .{@as(objc.NSUInteger, 0)});
}

fn asset(path: []const u8) av.Object {
    return objc.msg(av.Object, objc.class("AVURLAsset"), "URLAssetWithURL:options:", .{ av.fileUrl(path), @as(?av.Object, null) });
}

/// A video's size, frame rate and length.
pub fn info(path: []const u8) !Info {
    const pool = objc.Pool.push();
    defer pool.pop();
    const a = asset(path);
    const track = videoTrack(a) orelse return error.NoVideo;
    const size = objc.msg(av.CGSize, track, "naturalSize", .{});
    return .{
        .width = @intFromFloat(size.width),
        .height = @intFromFloat(size.height),
        .fps = objc.msg(f32, track, "nominalFrameRate", .{}),
        .duration = objc.msg(av.CMTime, a, "duration", .{}).seconds(),
    };
}

pub const Frame = struct { pb: av.CVPixelBufferRef, t: f64 };

pub const Reader = struct {
    reader: av.Object,
    output: av.Object,
    /// The frame showing now, and the one after it (read ahead).
    current: ?Frame = null,
    next: ?Frame = null,
    ended: bool = false,
    /// Where it was opened: frames before it don't come.
    from: f64,

    /// Decodes `path` from `start` seconds on.
    pub fn open(path: []const u8, start: f64) !Reader {
        const pool = objc.Pool.push();
        defer pool.pop();
        const a = asset(path);
        const track = videoTrack(a) orelse return error.NoVideo;
        var err: ?av.Object = null;
        const reader = objc.msg(?av.Object, objc.class("AVAssetReader"), "assetReaderWithAsset:error:", .{ a, &err }) orelse return error.Reader;
        const output = objc.msg(av.Object, objc.class("AVAssetReaderTrackOutput"), "assetReaderTrackOutputWithTrack:outputSettings:", .{ track, av.bgraAttributes(null, null) });
        objc.msg(void, output, "setAlwaysCopiesSampleData:", .{false});
        if (!objc.msg(bool, reader, "canAddOutput:", .{output})) return error.Output;
        objc.msg(void, reader, "addOutput:", .{output});
        const duration = objc.msg(av.CMTime, a, "duration", .{}).seconds();
        const s = std.math.clamp(start, 0, @max(0, duration - 0.001));
        objc.msg(void, reader, "setTimeRange:", .{av.CMTimeRange{ .start = av.CMTime.of(s), .duration = av.CMTime.of(@max(0.001, duration - s + 1)) }});
        if (!objc.msg(bool, reader, "startReading", .{})) return error.StartReading;
        return .{ .reader = objc.retain(reader), .output = objc.retain(output), .from = s };
    }

    pub fn deinit(r: *Reader) void {
        if (r.current) |f| av.CFRelease(f.pb);
        if (r.next) |f| av.CFRelease(f.pb);
        objc.msg(void, r.reader, "cancelReading", .{});
        objc.release(r.output);
        objc.release(r.reader);
    }

    fn pull(r: *Reader) ?Frame {
        if (r.ended) return null;
        const pool = objc.Pool.push();
        defer pool.pop();
        while (true) {
            const sb = objc.msg(?*anyopaque, r.output, "copyNextSampleBuffer", .{}) orelse {
                r.ended = true;
                return null;
            };
            defer av.CFRelease(sb);
            const pb = av.CMSampleBufferGetImageBuffer(sb) orelse continue;
            return .{ .pb = av.CFRetain(pb), .t = av.CMSampleBufferGetPresentationTimeStamp(sb).seconds() };
        }
    }

    /// The frame showing at `t` (the last one at or before it), reading
    /// forward; null before the first frame or if `t` is behind `from`.
    pub fn at(r: *Reader, t: f64) ?av.CVPixelBufferRef {
        if (r.current == null) r.current = r.pull();
        if (r.next == null) r.next = r.pull();
        while (r.next) |n| {
            if (n.t > t + 1e-6) break;
            if (r.current) |c| av.CFRelease(c.pb);
            r.current = n;
            r.next = r.pull();
        }
        const c = r.current orelse return null;
        return c.pb;
    }

    /// Whether frames at `t` can still come without opening again.
    pub fn reaches(r: *const Reader, t: f64) bool {
        const c = r.current orelse return t >= r.from;
        return t >= c.t - 1e-6;
    }
};
