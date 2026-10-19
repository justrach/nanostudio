//! Recording the screen, as the reference does: ScreenCaptureKit streams a
//! display (without its cursor: nanostudio draws its own) into a real-time
//! HEVC writer, while a global event monitor logs the cursor and its
//! clicks on the same host clock as the frames. Stopping finishes the
//! video and writes recording.json beside it.
const std = @import("std");
const nanoui = @import("nanoui");
const av = @import("av.zig");
const writer = @import("writer.zig");
const rec = @import("recording.zig");
const objc = av.objc;

extern "c" fn CGPreflightScreenCaptureAccess() bool;
extern "c" fn CGRequestScreenCaptureAccess() bool;
extern "c" fn CGMainDisplayID() u32;
extern "c" fn dispatch_queue_create(label: [*:0]const u8, attr: ?*anyopaque) ?*anyopaque;
extern "c" const SCStreamFrameInfoStatus: av.Object;

/// Whether this app may record the screen (no prompt).
pub fn screenAccess() bool {
    return CGPreflightScreenCaptureAccess();
}

/// Asks for screen access: only when the user asks (a button), never on launch.
pub fn requestScreenAccess() bool {
    return CGRequestScreenCaptureAccess();
}

/// A display, as the capture screen lists them.
pub const Display = struct { id: u32, width: f64, height: f64, scale: f64, main: bool };

/// The displays, the main one first (NSScreen: no permission needed).
pub fn displays(buf: []Display) []Display {
    const pool = objc.Pool.push();
    defer pool.pop();
    const screens = objc.msg(av.Object, objc.class("NSScreen"), "screens", .{});
    const n = @min(buf.len, objc.msg(objc.NSUInteger, screens, "count", .{}));
    const main_id = CGMainDisplayID();
    var k: usize = 0;
    for (0..n) |i| {
        const s = objc.msg(av.Object, screens, "objectAtIndex:", .{@as(objc.NSUInteger, i)});
        const desc = objc.msg(av.Object, s, "deviceDescription", .{});
        const num = objc.msg(?av.Object, desc, "objectForKey:", .{objc.nsString("NSScreenNumber")}) orelse continue;
        const id: u32 = @intCast(objc.msg(c_uint, num, "unsignedIntValue", .{}));
        const f = objc.msg(av.CGRect, s, "frame", .{});
        buf[k] = .{ .id = id, .width = f.size.width, .height = f.size.height, .scale = objc.msg(f64, s, "backingScaleFactor", .{}), .main = id == main_id };
        k += 1;
    }
    std.mem.sort(Display, buf[0..k], {}, struct {
        fn lt(_: void, a: Display, b: Display) bool {
            return a.main and !b.main;
        }
    }.lt);
    return buf[0..k];
}

pub const State = enum { idle, starting, recording, saving, failed };

pub const Recorder = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    state: State = .idle,
    failure: []const u8 = "",
    dir: []const u8 = "",
    display: Display = undefined,
    /// The display's frame in global coordinates (top-left origin), for the cursor.
    frame: av.CGRect = undefined,
    primary_height: f64 = 0,
    stream: ?av.Object = null,
    output: ?av.Object = null,
    monitor: ?av.Object = null,
    content: ?av.Object = null,
    writer: ?writer.Writer = null,
    cursor: std.ArrayList(rec.CursorSample) = .empty,
    /// The first frame's and the last frame's host time.
    first: ?f64 = null,
    last: f64 = 0,
    /// Called on the main thread when recording starts, fails, or is saved.
    changed: ?struct { ctx: *anyopaque, func: *const fn (*anyopaque) void } = null,

    pub fn deinit(r: *Recorder) void {
        r.cursor.deinit(r.gpa);
        if (r.dir.len > 0) r.gpa.free(r.dir);
    }

    fn notify(r: *Recorder) void {
        if (r.changed) |c| c.func(c.ctx);
    }

    fn fail(r: *Recorder, why: []const u8) void {
        r.state = .failed;
        r.failure = why;
        r.notify();
    }

    /// Starts recording `display` into the new folder `dir`.
    pub fn start(r: *Recorder, dir: []const u8, display: Display) void {
        if (r.state == .starting or r.state == .recording) return;
        if (r.dir.len > 0) r.gpa.free(r.dir);
        r.dir = r.gpa.dupe(u8, dir) catch return;
        r.display = display;
        r.cursor.clearRetainingCapacity();
        r.first = null;
        r.state = .starting;
        if (!screenAccess()) return r.fail("Screen Recording is off for nanostudio: allow it in System Settings, Privacy & Security, Screen & System Audio Recording.");
        var block = objc.Block(Recorder, &.{ ?av.Object, ?av.Object }).init(r, gotContent);
        objc.msg(void, objc.class("SCShareableContent"), "getShareableContentWithCompletionHandler:", .{@as(*anyopaque, @ptrCast(&block))});
    }

    fn gotContent(r: *Recorder, content: ?av.Object, err: ?av.Object) void {
        _ = err;
        r.content = if (content) |c| objc.retain(c) else null;
        objc.dispatchMain(r, struct {
            fn f(ctx: ?*anyopaque) callconv(.c) void {
                const self: *Recorder = @ptrCast(@alignCast(ctx));
                self.begin();
            }
        }.f);
    }

    /// On the main thread, with the shareable content: the stream starts.
    fn begin(r: *Recorder) void {
        const pool = objc.Pool.push();
        defer pool.pop();
        const content = r.content orelse return r.fail("macOS gave no screens to record (is Screen Recording allowed?).");
        defer {
            objc.release(content);
            r.content = null;
        }
        const list = objc.msg(av.Object, content, "displays", .{});
        var sc_display: ?av.Object = null;
        for (0..objc.msg(objc.NSUInteger, list, "count", .{})) |i| {
            const d = objc.msg(av.Object, list, "objectAtIndex:", .{@as(objc.NSUInteger, i)});
            if (objc.msg(u32, d, "displayID", .{}) == r.display.id) sc_display = d;
        }
        const d = sc_display orelse return r.fail("That display isn't there any more.");
        r.frame = objc.msg(av.CGRect, d, "frame", .{});
        const main_screen = objc.msg(av.Object, objc.msg(av.Object, objc.class("NSScreen"), "screens", .{}), "objectAtIndex:", .{@as(objc.NSUInteger, 0)});
        r.primary_height = objc.msg(av.CGRect, main_screen, "frame", .{}).size.height;
        // Pixels, even for the encoder, at most 3840 wide.
        var w = r.display.width * r.display.scale;
        var h = r.display.height * r.display.scale;
        if (w > 3840) {
            h = h * 3840 / w;
            w = 3840;
        }
        const pw: usize = @as(usize, @intFromFloat(w)) & ~@as(usize, 1);
        const ph: usize = @as(usize, @intFromFloat(h)) & ~@as(usize, 1);
        const video = std.fs.path.join(r.gpa, &.{ r.dir, "screen.mp4" }) catch return r.fail("out of memory");
        defer r.gpa.free(video);
        r.writer = writer.Writer.create(video, .{ .width = pw, .height = ph, .fps = 60, .codec = .hevc, .realtime = true, .bitrate = 40_000_000 }) catch return r.fail("The video encoder could not start.");

        const filter = objc.msg(av.Object, objc.alloc("SCContentFilter"), "initWithDisplay:excludingWindows:", .{ d, objc.msg(av.Object, objc.class("NSArray"), "array", .{}) });
        defer objc.release(filter);
        const config = objc.new("SCStreamConfiguration");
        defer objc.release(config);
        objc.msg(void, config, "setWidth:", .{@as(objc.NSUInteger, pw)});
        objc.msg(void, config, "setHeight:", .{@as(objc.NSUInteger, ph)});
        objc.msg(void, config, "setMinimumFrameInterval:", .{av.CMTime{ .value = 1, .timescale = 60, .flags = 1 }});
        objc.msg(void, config, "setPixelFormat:", .{av.bgra});
        objc.msg(void, config, "setShowsCursor:", .{false});
        objc.msg(void, config, "setQueueDepth:", .{@as(objc.NSInteger, 6)});
        const stream = objc.msg(av.Object, objc.alloc("SCStream"), "initWithFilter:configuration:delegate:", .{ filter, config, @as(?av.Object, null) });
        r.stream = stream;
        const cls = objc.defineClass(.{ .name = "NanostudioStreamOutput", .protocols = &.{"SCStreamOutput"}, .methods = &.{
            .{ .name = "stream:didOutputSampleBuffer:ofType:", .imp = &didOutput, .types = "v@:@^vq" },
        } });
        const output = objc.msg(av.Object, objc.msg(av.Object, cls, "alloc", .{}), "init", .{});
        objc.setZig(output, r);
        r.output = output;
        var err: ?av.Object = null;
        const queue = dispatch_queue_create("nanostudio.capture", null);
        if (!objc.msg(bool, stream, "addStreamOutput:type:sampleHandlerQueue:error:", .{ output, @as(objc.NSInteger, 0), queue, &err })) return r.fail("The screen stream could not start.");
        var block = objc.Block(Recorder, &.{?av.Object}).init(r, started);
        objc.msg(void, stream, "startCaptureWithCompletionHandler:", .{@as(*anyopaque, @ptrCast(&block))});
        // The cursor, wherever it goes: moves, drags, presses.
        const mask: u64 = (1 << 1) | (1 << 2) | (1 << 3) | (1 << 4) | (1 << 5) | (1 << 6) | (1 << 7);
        var mblock = objc.Block(Recorder, &.{av.Object}).init(r, onEvent);
        r.monitor = objc.retain(objc.msg(av.Object, objc.class("NSEvent"), "addGlobalMonitorForEventsMatchingMask:handler:", .{ mask, @as(*anyopaque, @ptrCast(&mblock)) }));
    }

    fn started(r: *Recorder, err: ?av.Object) void {
        objc.dispatchMain(r, if (err == null) struct {
            fn f(ctx: ?*anyopaque) callconv(.c) void {
                const self: *Recorder = @ptrCast(@alignCast(ctx));
                self.state = .recording;
                self.notify();
            }
        }.f else struct {
            fn f(ctx: ?*anyopaque) callconv(.c) void {
                const self: *Recorder = @ptrCast(@alignCast(ctx));
                self.cleanup();
                self.fail("The screen stream would not start.");
            }
        }.f);
    }

    fn didOutput(obj: av.Object, _: objc.SEL, _: av.Object, sb: *anyopaque, kind: objc.NSInteger) callconv(.c) void {
        if (kind != 0) return;
        const r = objc.getZig(Recorder, obj) orelse return;
        if (!av.CMSampleBufferIsValid(sb)) return;
        // Only complete frames: idle and blank ones carry nothing new.
        const attachments = av.CMSampleBufferGetSampleAttachmentsArray(sb, false) orelse return;
        if (objc.msg(objc.NSUInteger, attachments, "count", .{}) == 0) return;
        const info = objc.msg(av.Object, attachments, "objectAtIndex:", .{@as(objc.NSUInteger, 0)});
        const status = objc.msg(?av.Object, info, "objectForKey:", .{SCStreamFrameInfoStatus}) orelse return;
        if (objc.msg(objc.NSInteger, status, "integerValue", .{}) != 0) return;
        const pb = av.CMSampleBufferGetImageBuffer(sb) orelse return;
        const t = av.CMSampleBufferGetPresentationTimeStamp(sb).seconds();
        const w = &(r.writer orelse return);
        if (w.append(pb, t)) {
            if (r.first == null) r.first = t;
            r.last = t;
        }
    }

    fn onEvent(r: *Recorder, event: av.Object) void {
        _ = event;
        const loc = objc.msg(av.CGPoint, objc.class("NSEvent"), "mouseLocation", .{});
        const buttons = objc.msg(objc.NSUInteger, objc.class("NSEvent"), "pressedMouseButtons", .{});
        // AppKit's y goes up from the primary screen's bottom; the display's
        // frame is top-left based.
        const top = r.primary_height - loc.y;
        const x: f32 = @floatCast((loc.x - r.frame.origin.x) / r.frame.size.width);
        const y: f32 = @floatCast((top - r.frame.origin.y) / r.frame.size.height);
        r.cursor.append(r.gpa, .{ .t = av.CACurrentMediaTime(), .x = x, .y = y, .down = buttons & 1 != 0 }) catch {};
    }

    fn cleanup(r: *Recorder) void {
        if (r.monitor) |m| {
            objc.msg(void, objc.class("NSEvent"), "removeMonitor:", .{m});
            objc.release(m);
            r.monitor = null;
        }
        if (r.stream) |s| objc.release(s);
        r.stream = null;
        if (r.output) |o| {
            objc.setZig(o, null);
            objc.release(o);
        }
        r.output = null;
    }

    /// Stops recording; the video and recording.json are saved, then `changed`.
    pub fn stop(r: *Recorder) void {
        if (r.state != .recording) return;
        r.state = .saving;
        const s = r.stream orelse return;
        var block = objc.Block(Recorder, &.{?av.Object}).init(r, stopped);
        objc.msg(void, s, "stopCaptureWithCompletionHandler:", .{@as(*anyopaque, @ptrCast(&block))});
    }

    fn stopped(r: *Recorder, _: ?av.Object) void {
        objc.dispatchMain(r, struct {
            fn f(ctx: ?*anyopaque) callconv(.c) void {
                const self: *Recorder = @ptrCast(@alignCast(ctx));
                self.save();
            }
        }.f);
    }

    fn save(r: *Recorder) void {
        r.cleanup();
        var w = r.writer orelse return r.fail("Nothing was recorded.");
        defer {
            w.deinit();
            r.writer = null;
        }
        const first = r.first orelse return r.fail("No frames came from the screen.");
        w.finish() catch return r.fail("The video could not be finished.");
        // The cursor on the video's clock.
        var samples: std.ArrayList(rec.CursorSample) = .empty;
        defer samples.deinit(r.gpa);
        for (r.cursor.items) |s| {
            if (s.t < first - 0.05) continue;
            samples.append(r.gpa, .{ .t = @max(0, s.t - first), .x = s.x, .y = s.y, .down = s.down }) catch break;
        }
        const recording: rec.Recording = .{
            .width = @intCast(w.width),
            .height = @intCast(w.height),
            .fps = 60,
            .duration = @max(0.1, r.last - first),
            .points_width = @floatCast(r.display.width),
            .cursor = samples.items,
        };
        rec.save(r.gpa, r.io, r.dir, recording) catch return r.fail("recording.json could not be written.");
        r.state = .idle;
        r.notify();
    }
};
