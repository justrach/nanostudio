//! A recording open in the editor: what was recorded (recording.json, the
//! video's size and rate), and what is being made of it (the timeline's
//! clips, the zooms, the style), with undo and redo, saved back to
//! recording.json. The camera's motion is built again when they change.
const std = @import("std");
const rec = @import("recording.zig");
const timeline = @import("timeline.zig");
const motion_mod = @import("motion.zig");
const reader = @import("reader.zig");
const Style = @import("style.zig").Style;

pub const Selection = union(enum) { none, clip: usize, zoom: usize };

const Snapshot = struct {
    slices: []timeline.Slice,
    zooms: []rec.ZoomSegment,
    style: Style,
};

pub const Project = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    arena: std.heap.ArenaAllocator,
    dir: []const u8,
    video: []const u8,
    rec: rec.Recording,
    info: reader.Info,
    clicks: []rec.Click,
    timeline: timeline.Timeline = .{},
    zooms: std.ArrayList(rec.ZoomSegment) = .empty,
    style: Style,
    selection: Selection = .none,
    motion: ?motion_mod.Motion = null,
    undos: std.ArrayList(Snapshot) = .empty,
    redos: std.ArrayList(Snapshot) = .empty,
    /// Changed since it was saved.
    dirty: bool = false,

    /// Opens the recording in `dir`.
    pub fn open(gpa: std.mem.Allocator, io: std.Io, dir: []const u8) !*Project {
        const p = try gpa.create(Project);
        errdefer gpa.destroy(p);
        p.* = .{ .gpa = gpa, .io = io, .arena = .init(gpa), .dir = undefined, .video = undefined, .rec = undefined, .info = undefined, .clicks = &.{}, .style = .{} };
        errdefer p.arena.deinit();
        const a = p.arena.allocator();
        p.dir = try a.dupe(u8, dir);
        p.video = try std.fs.path.join(a, &.{ dir, "screen.mp4" });
        p.rec = try rec.load(a, io, dir);
        p.info = reader.info(p.video) catch .{ .width = p.rec.width, .height = p.rec.height, .fps = @floatFromInt(p.rec.fps), .duration = p.rec.duration };
        p.clicks = try rec.clicks(a, p.rec.cursor);
        p.style = p.rec.style orelse .{};
        if (p.rec.timeline) |tl| {
            try p.timeline.slices.appendSlice(gpa, tl.slices);
        } else {
            // A fresh recording: cut the reach for the stop button.
            const end = rec.stopReach(p.rec.cursor, p.rec.duration) orelse p.rec.duration;
            try p.timeline.slices.append(gpa, .{ .start = 0, .end = end });
        }
        if (p.rec.zooms) |z| {
            try p.zooms.appendSlice(gpa, z);
        } else if (p.style.auto_zoom) {
            const auto = try rec.autoZooms(gpa, p.rec.cursor, p.timeline, p.rec.duration, p.style.zoom);
            defer gpa.free(auto);
            try p.zooms.appendSlice(gpa, auto);
        }
        return p;
    }

    pub fn deinit(p: *Project) void {
        const gpa = p.gpa;
        for (p.undos.items) |s| freeSnapshot(gpa, s);
        for (p.redos.items) |s| freeSnapshot(gpa, s);
        p.undos.deinit(gpa);
        p.redos.deinit(gpa);
        if (p.motion) |*m| m.deinit(gpa);
        p.timeline.deinit(gpa);
        p.zooms.deinit(gpa);
        p.arena.deinit();
        gpa.destroy(p);
    }

    fn freeSnapshot(gpa: std.mem.Allocator, s: Snapshot) void {
        gpa.free(s.slices);
        gpa.free(s.zooms);
    }

    fn snapshot(p: *Project) !Snapshot {
        return .{ .slices = try p.gpa.dupe(timeline.Slice, p.timeline.slices.items), .zooms = try p.gpa.dupe(rec.ZoomSegment, p.zooms.items), .style = p.style };
    }

    fn restore(p: *Project, s: Snapshot) void {
        p.timeline.slices.clearRetainingCapacity();
        p.timeline.slices.appendSlice(p.gpa, s.slices) catch {};
        p.zooms.clearRetainingCapacity();
        p.zooms.appendSlice(p.gpa, s.zooms) catch {};
        p.style = s.style;
        p.selection = .none;
        p.changed();
    }

    /// Call before changing the timeline, zooms or style: undo comes back here.
    pub fn edit(p: *Project) void {
        const s = p.snapshot() catch return;
        p.undos.append(p.gpa, s) catch return freeSnapshot(p.gpa, s);
        for (p.redos.items) |r| freeSnapshot(p.gpa, r);
        p.redos.clearRetainingCapacity();
    }

    /// Something changed: the motion follows, and it needs saving.
    pub fn changed(p: *Project) void {
        if (p.motion) |*m| m.deinit(p.gpa);
        p.motion = null;
        p.dirty = true;
    }

    pub fn undo(p: *Project) void {
        const s = p.undos.pop() orelse return;
        const now = p.snapshot() catch return;
        p.redos.append(p.gpa, now) catch freeSnapshot(p.gpa, now);
        p.restore(s);
        freeSnapshot(p.gpa, s);
    }

    pub fn redo(p: *Project) void {
        const s = p.redos.pop() orelse return;
        const now = p.snapshot() catch return;
        p.undos.append(p.gpa, now) catch freeSnapshot(p.gpa, now);
        p.restore(s);
        freeSnapshot(p.gpa, s);
    }

    /// The camera and cursor, built when needed.
    pub fn motionNow(p: *Project) *const motion_mod.Motion {
        if (p.motion == null) {
            p.motion = motion_mod.Motion.build(p.gpa, p.rec.cursor, p.zooms.items, p.rec.duration, p.timeline.sourceEnd(p.rec.duration), p.style) catch .{ .frames = &.{} };
        }
        return &p.motion.?;
    }

    /// The final video's length.
    pub fn duration(p: *const Project) f64 {
        return p.timeline.duration();
    }

    /// Zooms made again from the clicks, at the style's zoom.
    pub fn autoZoom(p: *Project) void {
        p.edit();
        const auto = rec.autoZooms(p.gpa, p.rec.cursor, p.timeline, p.rec.duration, p.style.zoom) catch return;
        defer p.gpa.free(auto);
        p.zooms.clearRetainingCapacity();
        p.zooms.appendSlice(p.gpa, auto) catch {};
        p.selection = .none;
        p.changed();
    }

    /// A zoom at source time `src`, two seconds long.
    pub fn addZoom(p: *Project, src: f64) void {
        p.edit();
        const start = @max(0, src - 0.3);
        const z: rec.ZoomSegment = .{ .start = start, .end = @min(p.rec.duration, start + 2), .scale = p.style.zoom };
        var i: usize = 0;
        while (i < p.zooms.items.len and p.zooms.items[i].start < z.start) i += 1;
        p.zooms.insert(p.gpa, i, z) catch return;
        p.selection = .{ .zoom = i };
        p.changed();
    }

    /// Writes what was made back to recording.json.
    pub fn save(p: *Project) !void {
        var r = p.rec;
        r.style = p.style;
        r.zooms = p.zooms.items;
        r.timeline = .{ .slices = p.timeline.slices.items };
        try rec.save(p.gpa, p.io, p.dir, r);
        p.dirty = false;
    }
};
