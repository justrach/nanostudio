//! The final video: each output frame's source time through the timeline,
//! the recording's frame there (read in order: source times only grow),
//! the canvas drawn offscreen by nanoui at the output's size, and the
//! pixels encoded. A batch of frames at a time, so the editor keeps
//! drawing (its progress) while it runs.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const av = @import("av.zig");
const canvas = @import("canvas.zig");
const reader = @import("reader.zig");
const writer = @import("writer.zig");
const style_mod = @import("style.zig");
const Project = @import("project.zig").Project;

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
        var w = try writer.Writer.create(out, .{ .width = size[0], .height = size[1], .fps = fps, .bitrate = @divTrunc(@as(i64, size[0]) * size[1] * fps, 4) });
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
            .art = .{ .gpa = gpa },
            .frame = .{ .screen = null, .src_w = p.info.width, .src_h = p.info.height, .points_width = if (p.rec.points_width > 0) p.rec.points_width else @floatFromInt(p.info.width / 2), .style = p.style, .camera = .{}, .cursor = .{ -1, -1 }, .clicks = p.clicks, .t = 0 },
        };
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
            if (!e.writer.appendBgra(pixels.bytes, pixels.width * 4, t)) return e.fail("the encoder refused a frame");
            e.next += 1;
        }
        if (e.next < e.frames) return false;
        e.writer.finish() catch return e.fail("could not finish the video");
        e.done = true;
        return true;
    }

    fn fail(e: *Export, why: []const u8) bool {
        e.failed = why;
        e.done = true;
        return true;
    }
};
