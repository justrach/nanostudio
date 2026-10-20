//! Recording the screen, as the reference does: ScreenCaptureKit streams a
//! display (without its cursor: nanostudio draws its own) into a real-time
//! HEVC writer, with the system's sound and the microphone (macOS 15) as
//! AAC tracks beside it, while a global event monitor logs the cursor and
//! its clicks on the same host clock as the frames. Stopping finishes the
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
extern "c" fn getpid() c_int;
extern "c" const SCStreamFrameInfoStatus: av.Object;

/// Whether this app may record the screen (no prompt).
pub fn screenAccess() bool {
    return CGPreflightScreenCaptureAccess();
}

/// Asks for screen access: only when the user asks (a button), never on launch.
pub fn requestScreenAccess() bool {
    return CGRequestScreenCaptureAccess();
}

/// Whether ScreenCaptureKit can record the microphone (macOS 15 and later).
pub fn microphoneSupported() bool {
    return objc.msg(bool, objc.class("SCStreamConfiguration"), "instancesRespondToSelector:", .{objc.sel("setCaptureMicrophone:")});
}

/// The microphone's permission: 0 not asked, 1 restricted, 2 denied, 3 allowed.
pub fn microphoneAccess() isize {
    return objc.msg(objc.NSInteger, objc.class("AVCaptureDevice"), "authorizationStatusForMediaType:", .{av.AVMediaTypeAudio});
}

/// Asks for the microphone: only when the user turns it on.
pub fn requestMicrophone(r: *Recorder) void {
    if (microphoneAccess() != 0) return;
    var block = objc.Block(Recorder, &.{bool}).init(r, struct {
        fn f(self: *Recorder, _: bool) void {
            objc.dispatchMain(self, struct {
                fn g(ctx: ?*anyopaque) callconv(.c) void {
                    const me: *Recorder = @ptrCast(@alignCast(ctx));
                    if (me.state != .idle and me.state != .failed) return;
                    me.pending = .ask;
                    me.notify();
                }
            }.g);
        }
    }.f);
    objc.msg(void, objc.class("AVCaptureDevice"), "requestAccessForMediaType:completionHandler:", .{ av.AVMediaTypeAudio, @as(*anyopaque, @ptrCast(&block)) });
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

/// What to record: a display, or one window (its id).
pub const Source = union(enum) { display: Display, window: u32 };

/// A window that can be recorded, as the capture bar lists them.
pub const WindowInfo = struct { id: u32, app: []const u8, title: []const u8, width: f64, height: f64 };

pub const Recorder = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    state: State = .idle,
    failure: []const u8 = "",
    dir: []const u8 = "",
    source: Source = undefined,
    /// The windows that can be recorded (`listWindows`), their names owned.
    windows: std.ArrayList(WindowInfo) = .empty,
    /// What the shareable content was asked for.
    /// What was asked of macOS last: a recording, the windows, or the
    /// microphone (only a recording's end opens the take).
    pending: enum { start, list, ask } = .start,
    /// What's recorded's frame in global coordinates (top-left origin), for the cursor.
    frame: av.CGRect = undefined,
    primary_height: f64 = 0,
    stream: ?av.Object = null,
    output: ?av.Object = null,
    monitor: ?av.Object = null,
    content: ?av.Object = null,
    writer: ?writer.Writer = null,
    /// What's heard: the system's sound, the microphone.
    system_audio: bool = true,
    microphone: bool = false,
    /// The writer's track for each kind of buffer the stream gives
    /// (0 screen, 1 audio, 2 microphone).
    tracks: [3]?usize = .{ null, null, null },
    cursor: std.ArrayList(rec.CursorSample) = .empty,
    /// The first frame's and the last frame's host time.
    first: ?f64 = null,
    last: f64 = 0,
    /// Called on the main thread when recording starts, fails, or is saved.
    changed: ?struct { ctx: *anyopaque, func: *const fn (*anyopaque) void } = null,

    pub fn deinit(r: *Recorder) void {
        r.clearWindows();
        r.windows.deinit(r.gpa);
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

    fn clearWindows(r: *Recorder) void {
        for (r.windows.items) |w| {
            r.gpa.free(w.app);
            r.gpa.free(w.title);
        }
        r.windows.clearRetainingCapacity();
    }

    /// Lists the windows that can be recorded; `changed` when they're in.
    pub fn listWindows(r: *Recorder) void {
        if (r.state == .starting or r.state == .recording or !screenAccess()) return;
        r.pending = .list;
        var block = objc.Block(Recorder, &.{ ?av.Object, ?av.Object }).init(r, gotContent);
        objc.msg(void, objc.class("SCShareableContent"), "getShareableContentWithCompletionHandler:", .{@as(*anyopaque, @ptrCast(&block))});
    }

    fn listed(r: *Recorder, content: av.Object) void {
        r.clearWindows();
        const me = getpid();
        const list = objc.msg(av.Object, content, "windows", .{});
        for (0..objc.msg(objc.NSUInteger, list, "count", .{})) |i| {
            const w = objc.msg(av.Object, list, "objectAtIndex:", .{@as(objc.NSUInteger, i)});
            const app = objc.msg(?av.Object, w, "owningApplication", .{}) orelse continue;
            const f = objc.msg(av.CGRect, w, "frame", .{});
            if (objc.msg(objc.NSInteger, w, "windowLayer", .{}) != 0 or !objc.msg(bool, w, "isOnScreen", .{})) continue;
            if (objc.msg(c_int, app, "processID", .{}) == me or f.size.width < 120 or f.size.height < 80) continue;
            const name = r.gpa.dupe(u8, objc.fromNSString(objc.msg(?av.Object, app, "applicationName", .{}))) catch continue;
            const title = r.gpa.dupe(u8, objc.fromNSString(objc.msg(?av.Object, w, "title", .{}))) catch {
                r.gpa.free(name);
                continue;
            };
            r.windows.append(r.gpa, .{ .id = objc.msg(u32, w, "windowID", .{}), .app = name, .title = title, .width = f.size.width, .height = f.size.height }) catch {};
        }
        std.mem.sort(WindowInfo, r.windows.items, {}, struct {
            fn lt(_: void, a: WindowInfo, b: WindowInfo) bool {
                return std.ascii.lessThanIgnoreCase(a.app, b.app);
            }
        }.lt);
        r.notify();
    }

    /// Starts recording `source` into the new folder `dir`.
    pub fn start(r: *Recorder, dir: []const u8, source: Source) void {
        if (r.state == .starting or r.state == .recording) return;
        if (r.dir.len > 0) r.gpa.free(r.dir);
        r.dir = r.gpa.dupe(u8, dir) catch return;
        r.source = source;
        r.pending = .start;
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
                if (self.pending == .list) {
                    const c = self.content orelse return;
                    self.content = null;
                    self.listed(c);
                    objc.release(c);
                    return;
                }
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
        const main_screen = objc.msg(av.Object, objc.msg(av.Object, objc.class("NSScreen"), "screens", .{}), "objectAtIndex:", .{@as(objc.NSUInteger, 0)});
        r.primary_height = objc.msg(av.CGRect, main_screen, "frame", .{}).size.height;
        var scale: f64 = objc.msg(f64, main_screen, "backingScaleFactor", .{});
        const filter = switch (r.source) {
            .display => |want| blk: {
                const d = find(content, "displays", "displayID", want.id) orelse return r.fail("That display isn't there any more.");
                r.frame = objc.msg(av.CGRect, d, "frame", .{});
                scale = want.scale;
                // nanostudio's own windows (the capture bar) stay out of it.
                const me = getpid();
                var mine: [1]av.Object = undefined;
                var n: usize = 0;
                const apps = objc.msg(av.Object, content, "applications", .{});
                for (0..objc.msg(objc.NSUInteger, apps, "count", .{})) |i| {
                    const app = objc.msg(av.Object, apps, "objectAtIndex:", .{@as(objc.NSUInteger, i)});
                    if (objc.msg(c_int, app, "processID", .{}) == me) {
                        mine[0] = app;
                        n = 1;
                        break;
                    }
                }
                const excluded = objc.msg(av.Object, objc.class("NSArray"), "arrayWithObjects:count:", .{ @as(*const anyopaque, @ptrCast(&mine)), @as(objc.NSUInteger, n) });
                break :blk objc.msg(av.Object, objc.alloc("SCContentFilter"), "initWithDisplay:excludingApplications:exceptingWindows:", .{ d, excluded, objc.msg(av.Object, objc.class("NSArray"), "array", .{}) });
            },
            .window => |id| blk: {
                const w = find(content, "windows", "windowID", id) orelse return r.fail("That window isn't there any more.");
                r.frame = objc.msg(av.CGRect, w, "frame", .{});
                break :blk objc.msg(av.Object, objc.alloc("SCContentFilter"), "initWithDesktopIndependentWindow:", .{w});
            },
        };
        defer objc.release(filter);
        // Pixels, even for the encoder, at most 3840 wide.
        var w = r.frame.size.width * scale;
        var h = r.frame.size.height * scale;
        if (w > 3840) {
            h = h * 3840 / w;
            w = 3840;
        }
        const pw: usize = @as(usize, @intFromFloat(w)) & ~@as(usize, 1);
        const ph: usize = @as(usize, @intFromFloat(h)) & ~@as(usize, 1);
        const video = std.fs.path.join(r.gpa, &.{ r.dir, "screen.mp4" }) catch return r.fail("out of memory");
        defer r.gpa.free(video);
        var n_tracks: u2 = 0;
        r.tracks = .{ null, null, null };
        if (r.system_audio) {
            r.tracks[1] = n_tracks;
            n_tracks += 1;
        }
        if (r.microphone and microphoneSupported()) {
            r.tracks[2] = n_tracks;
            n_tracks += 1;
        }
        r.writer = writer.Writer.create(video, .{ .width = pw, .height = ph, .fps = 60, .codec = .hevc, .realtime = true, .bitrate = 40_000_000, .audio_tracks = n_tracks }) catch return r.fail("The video encoder could not start.");

        const config = objc.new("SCStreamConfiguration");
        defer objc.release(config);
        objc.msg(void, config, "setWidth:", .{@as(objc.NSUInteger, pw)});
        objc.msg(void, config, "setHeight:", .{@as(objc.NSUInteger, ph)});
        objc.msg(void, config, "setMinimumFrameInterval:", .{av.CMTime{ .value = 1, .timescale = 60, .flags = 1 }});
        objc.msg(void, config, "setPixelFormat:", .{av.bgra});
        objc.msg(void, config, "setShowsCursor:", .{false});
        objc.msg(void, config, "setQueueDepth:", .{@as(objc.NSInteger, 6)});
        if (r.tracks[1] != null) {
            objc.msg(void, config, "setCapturesAudio:", .{true});
            objc.msg(void, config, "setExcludesCurrentProcessAudio:", .{true});
            objc.msg(void, config, "setSampleRate:", .{@as(objc.NSInteger, 48000)});
            objc.msg(void, config, "setChannelCount:", .{@as(objc.NSInteger, 2)});
        }
        if (r.tracks[2] != null) objc.msg(void, config, "setCaptureMicrophone:", .{true});
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
        // Every kind on one queue: the writer is only ever touched there.
        for (r.tracks, 0..) |track, kind| {
            if (kind > 0 and track == null) continue;
            if (!objc.msg(bool, stream, "addStreamOutput:type:sampleHandlerQueue:error:", .{ output, @as(objc.NSInteger, @intCast(kind)), queue, &err })) return r.fail("The screen stream could not start.");
        }
        var block = objc.Block(Recorder, &.{?av.Object}).init(r, started);
        objc.msg(void, stream, "startCaptureWithCompletionHandler:", .{@as(*anyopaque, @ptrCast(&block))});
        // The cursor, wherever it goes: moves, drags, presses.
        const mask: u64 = (1 << 1) | (1 << 2) | (1 << 3) | (1 << 4) | (1 << 5) | (1 << 6) | (1 << 7);
        var mblock = objc.Block(Recorder, &.{av.Object}).init(r, onEvent);
        r.monitor = objc.retain(objc.msg(av.Object, objc.class("NSEvent"), "addGlobalMonitorForEventsMatchingMask:handler:", .{ mask, @as(*anyopaque, @ptrCast(&mblock)) }));
    }

    /// The item of `content`'s `list` whose `key` is `id`.
    fn find(content: av.Object, comptime list_name: [:0]const u8, comptime key: [:0]const u8, id: u32) ?av.Object {
        const list = objc.msg(av.Object, content, list_name, .{});
        for (0..objc.msg(objc.NSUInteger, list, "count", .{})) |i| {
            const item = objc.msg(av.Object, list, "objectAtIndex:", .{@as(objc.NSUInteger, i)});
            if (objc.msg(u32, item, key, .{}) == id) return item;
        }
        return null;
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
        const r = objc.getZig(Recorder, obj) orelse return;
        if (!av.CMSampleBufferIsValid(sb)) return;
        if (kind == 1 or kind == 2) {
            const track = r.tracks[@intCast(kind)] orelse return;
            if (r.writer) |*w| _ = w.appendAudio(track, sb);
            return;
        }
        if (kind != 0) return;
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
        // The sound stops with the last frame.
        w.endAt(r.last + 1.0 / 60.0);
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
            .points_width = @floatCast(r.frame.size.width),
            .cursor = samples.items,
        };
        rec.save(r.gpa, r.io, r.dir, recording) catch return r.fail("recording.json could not be written.");
        r.state = .idle;
        r.notify();
    }
};
