//! Sound along the timeline: the recording's audio tracks (system audio,
//! the microphone) laid out clip by clip in an AVMutableComposition, each
//! clip at its speed, so output time t sounds what the frame at t shows.
//! The editor plays it with an AVPlayer kept to the playhead; export reads
//! it mixed down (`Mix`) and encodes it beside the frames.
const std = @import("std");
const av = @import("av.zig");
const timeline = @import("timeline.zig");
const objc = av.objc;

fn audioTracks(source: av.Object) av.Object {
    return objc.msg(av.Object, source, "tracksWithMediaType:", .{av.AVMediaTypeAudio});
}

fn count(list: av.Object) usize {
    return objc.msg(objc.NSUInteger, list, "count", .{});
}

fn at(list: av.Object, i: usize) av.Object {
    return objc.msg(av.Object, list, "objectAtIndex:", .{@as(objc.NSUInteger, i)});
}

/// The file at `path`, as AVFoundation opens it (autoreleased).
pub fn asset(path: []const u8) av.Object {
    return objc.msg(av.Object, objc.class("AVURLAsset"), "URLAssetWithURL:options:", .{ av.fileUrl(path), @as(?av.Object, null) });
}

/// Whether the file at `path` has sound.
pub fn has(path: []const u8) bool {
    const pool = objc.Pool.push();
    defer pool.pop();
    return count(audioTracks(asset(path))) > 0;
}

/// The audio of `path` along `slices` (owned), or null when it has none.
pub fn composition(path: []const u8, slices: []const timeline.Slice) ?av.Object {
    const pool = objc.Pool.push();
    defer pool.pop();
    const tracks = audioTracks(asset(path));
    if (count(tracks) == 0) return null;
    const comp = objc.msg(av.Object, objc.class("AVMutableComposition"), "composition", .{});
    for (0..count(tracks)) |i| {
        const src = at(tracks, i);
        const range = objc.msg(av.CMTimeRange, src, "timeRange", .{});
        const have = range.start.seconds() + range.duration.seconds();
        const ct = objc.msg(?av.Object, comp, "addMutableTrackWithMediaType:preferredTrackID:", .{ av.AVMediaTypeAudio, @as(i32, 0) }) orelse continue;
        var out: f64 = 0;
        for (slices) |s| {
            const len = s.end - s.start;
            if (len <= 0) continue;
            // What the track has of the clip; silence for the rest.
            const real = std.math.clamp(have - s.start, 0, len);
            var err: ?av.Object = null;
            if (real > 0.001) _ = objc.msg(bool, ct, "insertTimeRange:ofTrack:atTime:error:", .{ av.CMTimeRange{ .start = .of(s.start), .duration = .of(real) }, src, av.CMTime.of(out), &err });
            if (len - real > 0.001) objc.msg(void, ct, "insertEmptyTimeRange:", .{av.CMTimeRange{ .start = .of(out + real), .duration = .of(len - real) }});
            if (s.speed != 1) objc.msg(void, ct, "scaleTimeRange:toDuration:", .{ av.CMTimeRange{ .start = .of(out), .duration = .of(len) }, av.CMTime.of(len / s.speed) });
            out += len / s.speed;
        }
    }
    return objc.retain(comp);
}

/// A composition's audio, mixed to 16-bit stereo PCM at 48 kHz, in order.
pub const Mix = struct {
    reader: av.Object,
    output: av.Object,

    /// Reads `source` (an AVAsset, or a composition) from its start.
    pub fn open(source: av.Object) !Mix {
        const pool = objc.Pool.push();
        defer pool.pop();
        const tracks = audioTracks(source);
        if (count(tracks) == 0) return error.NoAudio;
        var err: ?av.Object = null;
        const reader = objc.msg(?av.Object, objc.class("AVAssetReader"), "assetReaderWithAsset:error:", .{ source, &err }) orelse return error.Reader;
        const output = objc.msg(av.Object, objc.class("AVAssetReaderAudioMixOutput"), "assetReaderAudioMixOutputWithAudioTracks:audioSettings:", .{ tracks, av.pcmSettings() });
        if (!objc.msg(bool, reader, "canAddOutput:", .{output})) return error.Reader;
        objc.msg(void, reader, "addOutput:", .{output});
        if (!objc.msg(bool, reader, "startReading", .{})) return error.Reader;
        return .{ .reader = objc.retain(reader), .output = objc.retain(output) };
    }

    pub fn deinit(m: *Mix) void {
        // AVAssetReaderStatusReading
        if (objc.msg(i64, m.reader, "status", .{}) == 1) objc.msg(void, m.reader, "cancelReading", .{});
        objc.release(m.output);
        objc.release(m.reader);
    }

    /// The next buffer (owned: CFRelease it), or null at the end.
    pub fn next(m: *Mix) ?av.CMSampleBufferRef {
        return objc.msg(?av.CMSampleBufferRef, m.output, "copyNextSampleBuffer", .{});
    }
};

/// How loud `path` is: the RMS of its mixed audio (0 to 1) in windows of
/// 1 / `per_second` s (owned), or empty when it has no sound.
pub fn loudness(gpa: std.mem.Allocator, path: []const u8, per_second: u32) ![]f32 {
    const pool = objc.Pool.push();
    defer pool.pop();
    var m = Mix.open(asset(path)) catch return &.{};
    defer m.deinit();
    var out: std.ArrayList(f32) = .empty;
    errdefer out.deinit(gpa);
    const window: usize = 48000 / per_second;
    var sum: f64 = 0;
    var n: usize = 0;
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(gpa);
    while (m.next()) |sb| {
        defer av.CFRelease(sb);
        const block = av.CMSampleBufferGetDataBuffer(sb) orelse continue;
        const len = av.CMBlockBufferGetDataLength(block);
        try bytes.resize(gpa, len);
        if (av.CMBlockBufferCopyDataBytes(block, 0, len, bytes.items.ptr) != 0) continue;
        // Stereo frames: both channels together.
        var i: usize = 0;
        while (i + 4 <= len) : (i += 4) {
            const l: f64 = @floatFromInt(std.mem.readInt(i16, bytes.items[i..][0..2], .little));
            const r: f64 = @floatFromInt(std.mem.readInt(i16, bytes.items[i + 2 ..][0..2], .little));
            sum += (l * l + r * r) / 2;
            n += 1;
            if (n == window) {
                try out.append(gpa, @floatCast(@sqrt(sum / @as(f64, @floatFromInt(n))) / 32768));
                sum = 0;
                n = 0;
            }
        }
    }
    if (n > window / 2) try out.append(gpa, @floatCast(@sqrt(sum / @as(f64, @floatFromInt(n))) / 32768));
    return out.toOwnedSlice(gpa);
}

/// The editor's sound: an AVPlayer on the composition, started, stopped and
/// moved with the playhead.
pub const Preview = struct {
    player: av.Object,

    /// Plays `comp` (taking it).
    pub fn init(comp: av.Object) Preview {
        const pool = objc.Pool.push();
        defer pool.pop();
        defer objc.release(comp);
        const item = objc.msg(av.Object, objc.class("AVPlayerItem"), "playerItemWithAsset:", .{comp});
        return .{ .player = objc.msg(av.Object, objc.alloc("AVPlayer"), "initWithPlayerItem:", .{item}) };
    }

    pub fn deinit(p: *Preview) void {
        objc.msg(void, p.player, "pause", .{});
        objc.release(p.player);
    }

    /// Plays from output time `t`.
    pub fn play(p: *Preview, t: f64) void {
        p.seek(t);
        objc.msg(void, p.player, "play", .{});
    }

    pub fn pause(p: *Preview) void {
        objc.msg(void, p.player, "pause", .{});
    }

    pub fn seek(p: *Preview, t: f64) void {
        const zero = av.CMTime.of(0);
        objc.msg(void, p.player, "seekToTime:toleranceBefore:toleranceAfter:", .{ av.CMTime.of(t), zero, zero });
    }
};
