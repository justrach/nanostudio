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
pub extern "c" const kCVPixelBufferPixelFormatTypeKey: Object;
pub extern "c" const kCVPixelBufferWidthKey: Object;
pub extern "c" const kCVPixelBufferHeightKey: Object;
pub extern "c" const kCVPixelBufferMetalCompatibilityKey: Object;
pub extern "c" const kCVPixelBufferIOSurfacePropertiesKey: Object;

/// FourCC pixel formats.
pub const bgra: u32 = fourcc("BGRA");
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
