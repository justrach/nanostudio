//! AVFoundation, CoreMedia and CoreVideo as nanostudio calls them: their C
//! functions and constants declared directly, their classes through
//! nanoui's Objective-C runtime (`objc.msg`). No headers, no shims.
const std = @import("std");
const nanoui = @import("nanoui");
pub const objc = nanoui.objc;
pub const Object = objc.Object;

/// CMTime: a rational time, as CoreMedia passes it by value.
pub const CMTime = extern struct {
    value: i64,
    timescale: i32,
    flags: u32,
    epoch: i64 = 0,

    pub fn seconds(t: CMTime) f64 {
        if (t.flags & 1 == 0 or t.timescale == 0) return 0;
        return @as(f64, @floatFromInt(t.value)) / @as(f64, @floatFromInt(t.timescale));
    }

    pub fn of(s: f64) CMTime {
        return .{ .value = @intFromFloat(@round(s * 600_000)), .timescale = 600_000, .flags = 1 };
    }
};

pub const CMTimeRange = extern struct { start: CMTime, duration: CMTime };
pub const CGSize = extern struct { width: f64, height: f64 };
pub const CGPoint = extern struct { x: f64, y: f64 };
pub const CGRect = extern struct { origin: CGPoint, size: CGSize };

pub const CVPixelBufferRef = *anyopaque;
pub const CMSampleBufferRef = *anyopaque;

pub extern "c" fn CFRelease(obj: *anyopaque) void;
pub extern "c" fn CFRetain(obj: *anyopaque) *anyopaque;
pub extern "c" fn CMSampleBufferGetImageBuffer(sb: CMSampleBufferRef) ?CVPixelBufferRef;
pub extern "c" fn CMSampleBufferGetPresentationTimeStamp(sb: CMSampleBufferRef) CMTime;
pub extern "c" fn CMSampleBufferGetSampleAttachmentsArray(sb: CMSampleBufferRef, create: bool) ?Object;
pub extern "c" fn CMSampleBufferIsValid(sb: CMSampleBufferRef) bool;
pub extern "c" fn CVPixelBufferGetWidth(pb: CVPixelBufferRef) usize;
pub extern "c" fn CVPixelBufferGetHeight(pb: CVPixelBufferRef) usize;
pub extern "c" fn CVPixelBufferGetBytesPerRow(pb: CVPixelBufferRef) usize;
pub extern "c" fn CVPixelBufferGetBaseAddress(pb: CVPixelBufferRef) ?[*]u8;
pub extern "c" fn CVPixelBufferLockBaseAddress(pb: CVPixelBufferRef, flags: u64) i32;
pub extern "c" fn CVPixelBufferUnlockBaseAddress(pb: CVPixelBufferRef, flags: u64) i32;
pub extern "c" fn CVPixelBufferCreate(allocator: ?*anyopaque, width: usize, height: usize, format: u32, attrs: ?Object, out: *?CVPixelBufferRef) i32;
pub extern "c" fn CVPixelBufferPoolCreatePixelBuffer(allocator: ?*anyopaque, pool: *anyopaque, out: *?CVPixelBufferRef) i32;
pub extern "c" fn CACurrentMediaTime() f64;
pub extern "c" fn CMSampleBufferGetDataBuffer(sb: CMSampleBufferRef) ?*anyopaque;
pub extern "c" fn CMBlockBufferGetDataLength(bb: *anyopaque) usize;
pub extern "c" fn CMBlockBufferCopyDataBytes(bb: *anyopaque, offset: usize, len: usize, dest: *anyopaque) i32;
pub extern "c" fn CMBlockBufferCreateWithMemoryBlock(allocator: ?*anyopaque, memory: ?*anyopaque, block_len: usize, block_allocator: ?*anyopaque, custom: ?*const anyopaque, offset: usize, len: usize, flags: u32, out: *?*anyopaque) i32;
pub extern "c" fn CMBlockBufferReplaceDataBytes(src: *const anyopaque, dest: *anyopaque, offset: usize, len: usize) i32;
pub extern "c" fn CMAudioFormatDescriptionCreate(allocator: ?*anyopaque, asbd: *const AudioStreamBasicDescription, layout_size: usize, layout: ?*const anyopaque, cookie_size: usize, cookie: ?*const anyopaque, extensions: ?Object, out: *?*anyopaque) i32;
pub extern "c" fn CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: ?*anyopaque, data: *anyopaque, format: *anyopaque, samples: isize, pts: CMTime, packets: ?*const anyopaque, out: *?CMSampleBufferRef) i32;

/// CoreAudio's description of a PCM stream.
pub const AudioStreamBasicDescription = extern struct {
    sample_rate: f64,
    format_id: u32,
    format_flags: u32,
    bytes_per_packet: u32,
    frames_per_packet: u32,
    bytes_per_frame: u32,
    channels_per_frame: u32,
    bits_per_channel: u32,
    reserved: u32 = 0,
};

pub extern "c" const AVMediaTypeVideo: Object;
pub extern "c" const AVFileTypeMPEG4: Object;
pub extern "c" const AVVideoCodecKey: Object;
pub extern "c" const AVVideoCodecTypeH264: Object;
pub extern "c" const AVVideoCodecTypeHEVC: Object;
pub extern "c" const AVVideoWidthKey: Object;
pub extern "c" const AVVideoHeightKey: Object;
pub extern "c" const AVVideoCompressionPropertiesKey: Object;
pub extern "c" const AVVideoAverageBitRateKey: Object;
pub extern "c" const AVVideoExpectedSourceFrameRateKey: Object;
pub extern "c" const AVVideoMaxKeyFrameIntervalDurationKey: Object;
pub extern "c" const AVVideoAllowFrameReorderingKey: Object;
pub extern "c" const AVMediaTypeAudio: Object;
pub extern "c" const AVFormatIDKey: Object;
pub extern "c" const AVSampleRateKey: Object;
pub extern "c" const AVNumberOfChannelsKey: Object;
pub extern "c" const AVEncoderBitRateKey: Object;
pub extern "c" const AVLinearPCMBitDepthKey: Object;
pub extern "c" const AVLinearPCMIsFloatKey: Object;
pub extern "c" const AVLinearPCMIsBigEndianKey: Object;
pub extern "c" const AVLinearPCMIsNonInterleaved: Object;
pub extern "c" const kCVPixelBufferPixelFormatTypeKey: Object;
pub extern "c" const kCVPixelBufferWidthKey: Object;
pub extern "c" const kCVPixelBufferHeightKey: Object;
pub extern "c" const kCVPixelBufferMetalCompatibilityKey: Object;
pub extern "c" const kCVPixelBufferIOSurfacePropertiesKey: Object;

/// FourCC pixel and audio formats.
pub const bgra: u32 = fourcc("BGRA");
pub const aac: u32 = fourcc("aac ");
pub const lpcm: u32 = fourcc("lpcm");
pub const nv12: u32 = fourcc("420v");

pub fn fourcc(s: *const [4]u8) u32 {
    return std.mem.readInt(u32, s, .big);
}

pub fn number(v: anytype) Object {
    return switch (@typeInfo(@TypeOf(v))) {
        .bool => objc.msg(Object, objc.class("NSNumber"), "numberWithBool:", .{v}),
        .float, .comptime_float => objc.msg(Object, objc.class("NSNumber"), "numberWithDouble:", .{@as(f64, v)}),
        else => objc.msg(Object, objc.class("NSNumber"), "numberWithLongLong:", .{@as(i64, @intCast(v))}),
    };
}

/// An NSDictionary of `keys` and `values` (autoreleased).
pub fn dict(keys: []const Object, values: []const Object) Object {
    return objc.msg(Object, objc.class("NSDictionary"), "dictionaryWithObjects:forKeys:count:", .{ @as(*const anyopaque, @ptrCast(values.ptr)), @as(*const anyopaque, @ptrCast(keys.ptr)), @as(objc.NSUInteger, keys.len) });
}

pub fn fileUrl(path: []const u8) Object {
    return objc.msg(Object, objc.class("NSURL"), "fileURLWithPath:", .{objc.nsString(path)});
}

/// What a pixel buffer for Metal and the encoders asks: BGRA, IOSurface
/// backed (so the renderer wraps it without a copy).
pub fn bgraAttributes(width: ?usize, height: ?usize) Object {
    var keys: [5]Object = undefined;
    var values: [5]Object = undefined;
    keys[0] = kCVPixelBufferPixelFormatTypeKey;
    values[0] = number(bgra);
    keys[1] = kCVPixelBufferMetalCompatibilityKey;
    values[1] = number(true);
    keys[2] = kCVPixelBufferIOSurfacePropertiesKey;
    values[2] = objc.msg(Object, objc.class("NSDictionary"), "dictionary", .{});
    var n: usize = 3;
    if (width) |w| {
        keys[n] = kCVPixelBufferWidthKey;
        values[n] = number(w);
        n += 1;
    }
    if (height) |h| {
        keys[n] = kCVPixelBufferHeightKey;
        values[n] = number(h);
        n += 1;
    }
    return dict(keys[0..n], values[0..n]);
}

/// An NSError's description, or "".
pub fn errorText(err: ?Object) []const u8 {
    const e = err orelse return "";
    return objc.fromNSString(objc.msg(?Object, e, "localizedDescription", .{}));
}

/// A frame as nanoui shows it: the pixel buffer wrapped, not copied.
pub fn texture(pb: CVPixelBufferRef) nanoui.ui.Texture {
    return .{ .width = @intCast(CVPixelBufferGetWidth(pb)), .height = @intCast(CVPixelBufferGetHeight(pb)), .pixel_buffer = pb };
}

/// AAC at 48 kHz, stereo: how audio is kept.
pub fn aacSettings() Object {
    return dict(&.{ AVFormatIDKey, AVSampleRateKey, AVNumberOfChannelsKey, AVEncoderBitRateKey }, &.{ number(aac), number(48000), number(2), number(160_000) });
}

/// 16-bit interleaved PCM at 48 kHz, stereo: how audio is read to be mixed.
pub fn pcmSettings() Object {
    return dict(
        &.{ AVFormatIDKey, AVSampleRateKey, AVNumberOfChannelsKey, AVLinearPCMBitDepthKey, AVLinearPCMIsFloatKey, AVLinearPCMIsBigEndianKey, AVLinearPCMIsNonInterleaved },
        &.{ number(lpcm), number(48000), number(2), number(16), number(false), number(false), number(false) },
    );
}
