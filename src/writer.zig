//! Video out: an AVAssetWriter with a pixel buffer adaptor, H.264 or HEVC
//! in an MP4, and AAC tracks for audio. Capture appends ScreenCaptureKit's
//! buffers as they come (real time), on their own clock (the video starts
//! at its first frame); export appends the frames it renders, copied into
//! buffers from the adaptor's pool, and its mixed audio.
const std = @import("std");
const nanoui = @import("nanoui");
const av = @import("av.zig");
const objc = av.objc;

pub const Codec = enum { h264, hevc };

pub const Options = struct {
    width: usize,
    height: usize,
    fps: u32 = 60,
    codec: Codec = .h264,
    /// Frames come as they happen (capture): the encoder never makes them wait.
    realtime: bool = false,
    bitrate: i64 = 20_000_000,
    /// AAC tracks: 0, or 1 (export's mix), or 2 (capture: system audio and
    /// the microphone).
    audio_tracks: u2 = 0,
};

/// Where more audio comes from when the writer wants it before the next
/// frame (it interleaves the tracks): `more` appends a buffer, or says
/// there's no more (false).
pub const Feeder = struct { ctx: *anyopaque, more: *const fn (*anyopaque) bool };

pub const Writer = struct {
    writer: av.Object,
    input: av.Object,
    adaptor: av.Object,
    audio: [2]?av.Object = .{ null, null },
    width: usize,
    height: usize,
    /// The first frame's time: the video starts there.
    start: ?f64 = null,
    frames: usize = 0,
    done: bool = false,
    feeder: ?Feeder = null,
    audio_done: bool = false,

    pub fn create(path: []const u8, o: Options) !Writer {
        const pool = objc.Pool.push();
        defer pool.pop();
        std.Io.Dir.cwd().deleteFile(std.Io.Threaded.global_single_threaded.io(), path) catch {};
        var err: ?av.Object = null;
        const writer = objc.msg(?av.Object, objc.class("AVAssetWriter"), "assetWriterWithURL:fileType:error:", .{ av.fileUrl(path), av.AVFileTypeMPEG4, &err }) orelse {
            std.log.err("nanostudio: writer: {s}", .{av.errorText(err)});
            return error.Writer;
        };
        const compression = av.dict(
            &.{ av.AVVideoAverageBitRateKey, av.AVVideoExpectedSourceFrameRateKey, av.AVVideoMaxKeyFrameIntervalDurationKey, av.AVVideoAllowFrameReorderingKey },
            &.{ av.number(o.bitrate), av.number(o.fps), av.number(1.0), av.number(false) },
        );
        const settings = av.dict(
            &.{ av.AVVideoCodecKey, av.AVVideoWidthKey, av.AVVideoHeightKey, av.AVVideoCompressionPropertiesKey },
            &.{ if (o.codec == .hevc) av.AVVideoCodecTypeHEVC else av.AVVideoCodecTypeH264, av.number(o.width), av.number(o.height), compression },
        );
        if (!objc.msg(bool, writer, "canApplyOutputSettings:forMediaType:", .{ settings, av.AVMediaTypeVideo })) return error.Settings;
        const input = objc.msg(av.Object, objc.class("AVAssetWriterInput"), "assetWriterInputWithMediaType:outputSettings:", .{ av.AVMediaTypeVideo, settings });
        objc.msg(void, input, "setExpectsMediaDataInRealTime:", .{o.realtime});
        if (!objc.msg(bool, writer, "canAddInput:", .{input})) return error.Input;
        objc.msg(void, writer, "addInput:", .{input});
        const adaptor = objc.msg(av.Object, objc.class("AVAssetWriterInputPixelBufferAdaptor"), "assetWriterInputPixelBufferAdaptorWithAssetWriterInput:sourcePixelBufferAttributes:", .{ input, av.bgraAttributes(o.width, o.height) });
        var audio: [2]?av.Object = .{ null, null };
        for (0..o.audio_tracks) |k| {
            const ai = objc.msg(av.Object, objc.class("AVAssetWriterInput"), "assetWriterInputWithMediaType:outputSettings:", .{ av.AVMediaTypeAudio, av.aacSettings() });
            objc.msg(void, ai, "setExpectsMediaDataInRealTime:", .{o.realtime});
            if (!objc.msg(bool, writer, "canAddInput:", .{ai})) return error.AudioInput;
            objc.msg(void, writer, "addInput:", .{ai});
            audio[k] = objc.retain(ai);
        }
        if (!objc.msg(bool, writer, "startWriting", .{})) {
            std.log.err("nanostudio: writer: {s}", .{av.errorText(objc.msg(?av.Object, writer, "error", .{}))});
            return error.StartWriting;
        }
        return .{ .writer = objc.retain(writer), .input = objc.retain(input), .adaptor = objc.retain(adaptor), .audio = audio, .width = o.width, .height = o.height };
    }

    pub fn deinit(w: *Writer) void {
        for (w.audio) |a| if (a) |o| objc.release(o);
        objc.release(w.adaptor);
        objc.release(w.input);
        objc.release(w.writer);
    }

    /// Appends `pb` at time `t` (seconds, any clock: the first one starts
    /// the video). False if the encoder refused it.
    /// Starts the file at time `t` (else the first frame's time).
    pub fn startAt(w: *Writer, t: f64) void {
        if (w.start != null) return;
        w.start = t;
        objc.msg(void, w.writer, "startSessionAtSourceTime:", .{av.CMTime.of(t)});
    }

    pub fn append(w: *Writer, pb: av.CVPixelBufferRef, t: f64) bool {
        w.startAt(t);
        // Real time drops a frame the encoder can't take; else it waits.
        if (!objc.msg(bool, w.input, "isReadyForMoreMediaData", .{})) {
            if (objc.msg(bool, w.input, "expectsMediaDataInRealTime", .{})) return false;
            var waited: usize = 0;
            while (!objc.msg(bool, w.input, "isReadyForMoreMediaData", .{}) and waited < 5000) {
                if (w.feeder) |f| {
                    if (!f.more(f.ctx)) w.endAudio();
                    continue;
                }
                nanoui.runFor(0.001);
                waited += 1;
            }
            if (!objc.msg(bool, w.input, "isReadyForMoreMediaData", .{})) {
                std.log.err("nanostudio: the encoder stalled: {s}", .{av.errorText(objc.msg(?av.Object, w.writer, "error", .{}))});
                return false;
            }
        }
        const ok = objc.msg(bool, w.adaptor, "appendPixelBuffer:withPresentationTime:", .{ pb, av.CMTime.of(t) });
        if (ok) w.frames += 1;
        return ok;
    }

    /// Appends audio (`sb`, its own times on the video's clock) to track
    /// `track`; before the first frame it's dropped (the video starts there).
    pub fn appendAudio(w: *Writer, track: usize, sb: av.CMSampleBufferRef) bool {
        const input = w.audio[track] orelse return false;
        if (w.start == null) return false;
        if (!objc.msg(bool, input, "isReadyForMoreMediaData", .{})) {
            if (objc.msg(bool, input, "expectsMediaDataInRealTime", .{})) return false;
            var waited: usize = 0;
            while (!objc.msg(bool, input, "isReadyForMoreMediaData", .{}) and waited < 5000) : (waited += 1) nanoui.runFor(0.001);
            if (!objc.msg(bool, input, "isReadyForMoreMediaData", .{})) return false;
        }
        return objc.msg(bool, input, "appendSampleBuffer:", .{sb});
    }

    /// Appends BGRA pixels (`stride` bytes a row), copied into a buffer of
    /// the adaptor's pool.
    pub fn appendBgra(w: *Writer, bytes: []const u8, stride: usize, t: f64) bool {
        const pool = objc.msg(?*anyopaque, w.adaptor, "pixelBufferPool", .{}) orelse return false;
        var pb: ?av.CVPixelBufferRef = null;
        if (av.CVPixelBufferPoolCreatePixelBuffer(null, pool, &pb) != 0) return false;
        defer av.CFRelease(pb.?);
        _ = av.CVPixelBufferLockBaseAddress(pb.?, 0);
        const base = av.CVPixelBufferGetBaseAddress(pb.?).?;
        const dst_stride = av.CVPixelBufferGetBytesPerRow(pb.?);
        const row = @min(stride, w.width * 4);
        for (0..w.height) |y| @memcpy(base[y * dst_stride ..][0..row], bytes[y * stride ..][0..row]);
        _ = av.CVPixelBufferUnlockBaseAddress(pb.?, 0);
        return w.append(pb.?, t);
    }

    /// The file ends at time `t`: what's after it (the sound's last
    /// buffer) is cut.
    pub fn endAt(w: *Writer, t: f64) void {
        if (w.start == null) return;
        objc.msg(void, w.writer, "endSessionAtSourceTime:", .{av.CMTime.of(t)});
    }

    /// No more audio comes.
    pub fn endAudio(w: *Writer) void {
        w.feeder = null;
        if (w.audio_done) return;
        w.audio_done = true;
        for (w.audio) |a| if (a) |o| objc.msg(void, o, "markAsFinished", .{});
    }

    fn finished(w: *Writer) void {
        w.done = true;
    }

    /// Ends the video and waits for the file to be written.
    pub fn finish(w: *Writer) !void {
        objc.msg(void, w.input, "markAsFinished", .{});
        w.endAudio();
        var block = objc.Block(Writer, &.{}).init(w, finished);
        objc.msg(void, w.writer, "finishWritingWithCompletionHandler:", .{@as(*anyopaque, @ptrCast(&block))});
        var waited: usize = 0;
        while (!w.done and waited < 30_000) : (waited += 1) nanoui.runFor(0.001);
        // AVAssetWriterStatusCompleted
        if (objc.msg(i64, w.writer, "status", .{}) != 2) {
            std.log.err("nanostudio: finishing the video: {s}", .{av.errorText(objc.msg(?av.Object, w.writer, "error", .{}))});
            return error.Finish;
        }
    }
};
