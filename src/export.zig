//! The final video: each output frame's source time through the timeline,
//! the recording's frame there (read in order: source times only grow),
//! the canvas drawn offscreen by nanoui at the output's size, and the
//! pixels encoded, with the sound along the timeline mixed in step (just
//! ahead of each frame, as the writer interleaves them). A batch of frames
//! at a time, so the editor keeps drawing (its progress) while it runs.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const av = @import("av.zig");
const canvas = @import("canvas.zig");
const reader = @import("reader.zig");
const writer = @import("writer.zig");
const audio = @import("audio.zig");
const style_mod = @import("style.zig");
const Project = @import("project.zig").Project;
const objc = av.objc;

pub const Export = struct {
    gpa: std.mem.Allocator,
    project: *Project,
    out: []const u8,
    w: u32,
    h: u32,
    fps: u32,
    frames: usize,
    next: usize = 0,
    reader: reader.Reader,
    writer: writer.Writer,
    /// The sound (none when the recording has none), and how far it's in.
    sound: ?audio.Mix = null,
    sound_comp: ?av.Object = null,
    sound_t: f64 = 0,
    tester: ui.Tester = undefined,
    art: canvas.Art,
    frame: canvas.Frame,
    failed: ?[]const u8 = null,
    done: bool = false,

    /// Starts exporting `p` to `out` with the canvas's short side `short`.
    pub fn start(gpa: std.mem.Allocator, p: *Project, out: []const u8, short: u32) !*Export {
        const e = try gpa.create(Export);
        errdefer gpa.destroy(e);
        const size = style_mod.canvasSize(p.style.aspect, p.info.width, p.info.height, short);
        const fps: u32 = @intFromFloat(std.math.clamp(@round(p.info.fps), 24, 60));
        var r = try reader.Reader.open(p.video, p.timeline.toSource(0));
        errdefer r.deinit();
        const comp = audio.composition(p.video, p.timeline.slices.items);
        errdefer if (comp) |o| objc.release(o);
        var sound: ?audio.Mix = if (comp) |o| audio.Mix.open(o) catch null else null;
        errdefer if (sound) |*m| m.deinit();
        var w = try writer.Writer.create(out, .{ .width = size[0], .height = size[1], .fps = fps, .bitrate = @divTrunc(@as(i64, size[0]) * size[1] * fps, 4), .audio_tracks = if (sound != null) 1 else 0 });
        errdefer w.deinit();
        e.* = .{
            .gpa = gpa,
            .project = p,
            .out = try gpa.dupe(u8, out),
            .w = size[0],
            .h = size[1],
            .fps = fps,
            .frames = @intFromFloat(@ceil(p.duration() * @as(f64, @floatFromInt(fps)))),
            .reader = r,
            .writer = w,
            .sound = sound,
            .sound_comp = comp,
            .art = .{ .gpa = gpa },
            .frame = .{ .screen = null, .src_w = p.info.width, .src_h = p.info.height, .points_width = if (p.rec.points_width > 0) p.rec.points_width else @floatFromInt(p.info.width / 2), .style = p.style, .camera = .{}, .cursor = .{ -1, -1 }, .clicks = p.clicks, .t = 0 },
        };
        if (e.sound != null) e.writer.feeder = .{ .ctx = e, .more = feed };
        try e.tester.init(gpa, .init(e, view), .{ .width = @floatFromInt(size[0]), .height = @floatFromInt(size[1]), .scale = 1 });
        return e;
    }

    fn view(e: *Export, c: *ui.Context) void {
        canvas.draw(c, &e.art, @floatFromInt(e.w), @floatFromInt(e.h), e.frame);
    }

    pub fn deinit(e: *Export) void {
        e.tester.deinit();
        e.art.deinit();
        e.reader.deinit();
        if (e.sound) |*m| m.deinit();
        if (e.sound_comp) |o| objc.release(o);
        e.writer.deinit();
        e.gpa.free(e.out);
        e.gpa.destroy(e);
    }

    pub fn progress(e: *const Export) f32 {
        return @as(f32, @floatFromInt(e.next)) / @as(f32, @floatFromInt(@max(e.frames, 1)));
    }

    /// Encodes up to `n` more frames; true once the file is finished.
    pub fn step(e: *Export, n: usize) bool {
        if (e.done) return true;
        const p = e.project;
        const motion = p.motionNow();
        var k: usize = 0;
        while (k < n and e.next < e.frames) : (k += 1) {
            const t = @as(f64, @floatFromInt(e.next)) / @as(f64, @floatFromInt(e.fps));
            const src = p.timeline.toSource(t);
            const m = motion.at(src);
            e.frame.screen = if (e.reader.at(src)) |pb| av.texture(pb) else null;
            e.frame.camera = m.camera;
            e.frame.cursor = m.cursor;
            e.frame.t = src;
            e.tester.frame();
            const pixels = e.tester.render(e.gpa) catch return e.fail("could not draw a frame");
            defer pixels.deinit(e.gpa);
            // The sound a little ahead of the frames, as the writer interleaves.
            e.writer.startAt(0);
            if (!e.soundTo(t + 0.2)) return e.fail("the encoder refused the sound");
            if (!e.writer.appendBgra(pixels.bytes, pixels.width * 4, t)) return e.fail("the encoder refused a frame");
            e.next += 1;
        }
        if (e.next < e.frames) return false;
        if (!e.soundTo(std.math.inf(f64))) return e.fail("the encoder refused the sound");
        e.writer.endAt(@as(f64, @floatFromInt(e.frames)) / @as(f64, @floatFromInt(e.fps)));
        e.writer.finish() catch return e.fail("could not finish the video");
        e.done = true;
        return true;
    }

    /// Encodes the sound up to output time `until`.
    fn soundTo(e: *Export, until: f64) bool {
        while (e.sound != null and e.sound_t < until) {
            if (!e.soundOne()) return false;
        }
        if (e.sound == null) e.writer.endAudio();
        return true;
    }

    /// Encodes the sound's next buffer; at its end, closes it.
    fn soundOne(e: *Export) bool {
        const m = &(e.sound orelse return true);
        const sb = m.next() orelse {
            m.deinit();
            e.sound = null;
            return true;
        };
        defer av.CFRelease(sb);
        e.sound_t = av.CMSampleBufferGetPresentationTimeStamp(sb).seconds();
        return e.writer.appendAudio(0, sb);
    }

    /// The writer wants more sound before the next frame.
    fn feed(ctx: *anyopaque) bool {
        const e: *Export = @ptrCast(@alignCast(ctx));
        return e.soundOne() and e.sound != null;
    }

    fn fail(e: *Export, why: []const u8) bool {
        e.failed = why;
        e.done = true;
        return true;
    }
};
