//! A recording on disk, as the reference keeps it: a folder in the library
//! (~/Movies/Shitty Screen Studio, shared with it, so its recordings open
//! here and these there) with screen.mp4 and recording.json (the cursor,
//! its clicks, the zooms, the timeline and the style).
const std = @import("std");
const timeline = @import("timeline.zig");
const style_mod = @import("style.zig");

pub const CursorSample = struct { t: f64, x: f32, y: f32, down: bool };
pub const Click = struct { t: f64, x: f32, y: f32 };
pub const KeyPress = struct { t: f64, keys: []const u8 };
pub const ZoomSegment = struct { start: f64, end: f64, scale: f32 };
pub const CameraTrack = struct { lead: f64 };

/// recording.json, field for field.
pub const Recording = struct {
    width: u32,
    height: u32,
    fps: u32,
    duration: f64,
    /// The display's width in points: the cursor's art is sized from it.
    points_width: f32 = 0,
    cursor: []const CursorSample = &.{},
    zooms: ?[]const ZoomSegment = null,
    style: ?style_mod.Style = null,
    color: []const u8 = "srgb",
    camera: ?CameraTrack = null,
    timeline: ?struct { slices: []const timeline.Slice } = null,
    keys: []const KeyPress = &.{},
};

/// Its clicks: where the button went down.
pub fn clicks(gpa: std.mem.Allocator, cursor: []const CursorSample) ![]Click {
    var out: std.ArrayList(Click) = .empty;
    var was = false;
    for (cursor) |s| {
        if (s.down and !was) try out.append(gpa, .{ .t = s.t, .x = s.x, .y = s.y });
        was = s.down;
    }
    return out.toOwnedSlice(gpa);
}

/// Zooms for the clicks the timeline keeps: from just before each to a
/// little after, those close together merged.
pub fn autoZooms(gpa: std.mem.Allocator, cursor: []const CursorSample, tl: timeline.Timeline, duration: f64, scale: f32) ![]ZoomSegment {
    const lead = 0.4;
    const hold = 2.2;
    const merge_gap = 0.8;
    const cs = try clicks(gpa, cursor);
    defer gpa.free(cs);
    var out: std.ArrayList(ZoomSegment) = .empty;
    for (cs) |c| {
        if (!tl.containsSource(c.t)) continue;
        const start = @max(0, c.t - lead);
        const end = @min(duration, c.t + hold);
        if (out.items.len > 0 and start - out.items[out.items.len - 1].end < merge_gap) {
            const last = &out.items[out.items.len - 1];
            last.end = @max(last.end, end);
        } else try out.append(gpa, .{ .start = start, .end = end, .scale = scale });
    }
    return out.toOwnedSlice(gpa);
}

/// A recording that ends with a click on the stop button: when the cursor
/// left its last resting place to reach for it. Cutting there keeps the
/// reach out of the video (the reference's `stop_reach`).
pub fn stopReach(cursor: []const CursorSample, duration: f64) ?f64 {
    const click_to_stop = 0.4;
    const max_reach = 3.0;
    const rest = 0.4;
    const still: f32 = 0.004;
    const away: f32 = 0.03;
    const backtrack: f32 = 0.02;
    const pad = 0.1;
    var last_down: ?usize = null;
    for (cursor, 0..) |s, i| if (s.down) {
        last_down = i;
    };
    const ld = last_down orelse return null;
    if (cursor[ld].t < duration - click_to_stop) return null;
    var press: usize = 0;
    var j = ld + 1;
    while (j > 0) : (j -= 1) if (!cursor[j - 1].down) {
        press = j;
        break;
    };
    const px = cursor[press].x;
    const py = cursor[press].y;
    const pt = cursor[press].t;
    const dist = struct {
        fn f(s: CursorSample, x: f32, y: f32) f32 {
            return std.math.hypot(s.x - x, s.y - y);
        }
    }.f;
    var far_d: f32 = 0;
    var far_i = press;
    var release: ?f64 = null;
    var first_pause: ?f64 = null;
    var was_paused = false;
    var k = press;
    while (k > 0) {
        k -= 1;
        const s = cursor[k];
        if (pt - s.t > max_reach) return null;
        if (s.down) return reachEnd((first_pause orelse release orelse s.t) + pad, pt);
        release = s.t;
        const n = cursor[k + 1];
        const paused = @max(@abs(n.x - s.x), @abs(n.y - s.y)) < still and dist(s, px, py) >= away;
        if (paused and !was_paused) first_pause = s.t;
        was_paused = paused;
        const d = dist(s, px, py);
        if (d > far_d) {
            far_d = d;
            far_i = k;
        } else if (far_d - d > backtrack) return reachEnd(cursor[far_i].t + pad, pt);
        if (d < away or s.t - cursor[0].t < rest) continue;
        var calm = true;
        var r = k + 1;
        while (r > 0) {
            r -= 1;
            if (s.t - cursor[r].t > rest) break;
            if (@max(@abs(cursor[r].x - s.x), @abs(cursor[r].y - s.y)) >= still) {
                calm = false;
                break;
            }
        }
        if (calm) return reachEnd(s.t + pad, pt);
    }
    return null;
}

fn reachEnd(end: f64, press: f64) ?f64 {
    return if (end < press) end else null;
}

/// The library: where recordings are, the reference's as well.
pub fn libraryDir(buf: []u8, home: []const u8) []const u8 {
    return std.fmt.bufPrint(buf, "{s}/Movies/Shitty Screen Studio", .{home}) catch "";
}

/// A recording's folders, newest first.
pub fn list(arena: std.mem.Allocator, io: std.Io, dir: []const u8) ![][]const u8 {
    var d = std.Io.Dir.cwd().openDir(io, dir, .{ .iterate = true }) catch return &.{};
    defer d.close(io);
    var out: std.ArrayList([]const u8) = .empty;
    var it = d.iterate();
    while (try it.next(io)) |e| {
        if (e.kind != .directory) continue;
        const path = try std.fs.path.join(arena, &.{ dir, e.name });
        const meta = try std.fs.path.join(arena, &.{ path, "recording.json" });
        const video = try std.fs.path.join(arena, &.{ path, "screen.mp4" });
        std.Io.Dir.cwd().access(io, meta, .{}) catch continue;
        std.Io.Dir.cwd().access(io, video, .{}) catch continue;
        try out.append(arena, path);
    }
    std.mem.sort([]const u8, out.items, {}, struct {
        fn gt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .gt;
        }
    }.gt);
    return out.items;
}

/// recording.json in `dir`, parsed into `arena`.
pub fn load(arena: std.mem.Allocator, io: std.Io, dir: []const u8) !Recording {
    const path = try std.fs.path.join(arena, &.{ dir, "recording.json" });
    const data = try std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(64 << 20));
    return std.json.parseFromSliceLeaky(Recording, arena, data, .{ .ignore_unknown_fields = true, .allocate = .alloc_always });
}

/// Writes `rec` as recording.json in `dir`.
pub fn save(gpa: std.mem.Allocator, io: std.Io, dir: []const u8, rec: Recording) !void {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const json = try std.json.Stringify.valueAlloc(a, rec, .{ .whitespace = .indent_2, .emit_null_optional_fields = false });
    const path = try std.fs.path.join(a, &.{ dir, "recording.json" });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = json });
}

/// Rests at (0.3, 0.3), reaches for a button at (0.5, 1.1) from `move_at`,
/// and clicks it near the end.
fn session(gpa: std.mem.Allocator, move_at: f64, click_at: f64, duration: f64) ![]CursorSample {
    var out: std.ArrayList(CursorSample) = .empty;
    var t: f64 = 0;
    while (t <= duration) : (t += 0.008) {
        const k: f32 = @floatCast(std.math.clamp((t - move_at) / (click_at - 0.1 - move_at), 0, 1));
        try out.append(gpa, .{ .t = t, .x = 0.3 + 0.2 * k, .y = 0.3 + 0.8 * k, .down = t >= click_at and t < click_at + 0.08 });
    }
    return out.toOwnedSlice(gpa);
}

test "the reach for the stop button is cut; a click long before it is kept" {
    const gpa = std.testing.allocator;
    const c = try session(gpa, 4, 5, 5.1);
    defer gpa.free(c);
    const end = stopReach(c, 5.1).?;
    try std.testing.expect(end >= 4.0 and end < 4.2);
    const long = try session(gpa, 4, 5, 6);
    defer gpa.free(long);
    try std.testing.expectEqual(@as(?f64, null), stopReach(long, 6));
    const no_rest = try session(gpa, 0, 5, 5.1);
    defer gpa.free(no_rest);
    try std.testing.expectEqual(@as(?f64, null), stopReach(no_rest, 5.1));
}

test "recording.json as the reference writes it; auto zooms from clicks" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const json =
        \\{"width":3024,"height":1964,"fps":60,"duration":10.0,"points_width":1512.0,
        \\ "cursor":[{"t":0.0,"x":0.5,"y":0.5,"down":false},{"t":2.0,"x":0.2,"y":0.3,"down":true},
        \\           {"t":2.1,"x":0.2,"y":0.3,"down":false},{"t":2.5,"x":0.25,"y":0.3,"down":true},
        \\           {"t":2.6,"x":0.25,"y":0.3,"down":false},{"t":7.0,"x":0.8,"y":0.8,"down":true}],
        \\ "style":{"background":2,"aspect":"wide","padding":60.0,"cursor_style":"amber"},
        \\ "color":"display-p3","timeline":{"slices":[{"start":0.0,"end":6.0,"speed":1.0},{"start":6.5,"end":10.0,"speed":2.0}]},
        \\ "something_new":1}
    ;
    const rec = try std.json.parseFromSliceLeaky(Recording, a, json, .{ .ignore_unknown_fields = true, .allocate = .alloc_always });
    try std.testing.expectEqual(@as(u32, 3024), rec.width);
    try std.testing.expectEqual(style_mod.Aspect.wide, rec.style.?.aspect);
    try std.testing.expectEqual(style_mod.CursorStyle.amber, rec.style.?.cursor_style);
    // Missing style fields take their defaults.
    try std.testing.expectEqual(@as(f32, 14), rec.style.?.radius);
    try std.testing.expectEqual(@as(usize, 2), rec.timeline.?.slices.len);
    var tl: timeline.Timeline = .{};
    try tl.slices.appendSlice(a, rec.timeline.?.slices);
    const zooms = try autoZooms(a, rec.cursor, tl, rec.duration, 2);
    // The clicks at 2.0 and 2.5 merge; the one at 7.0 is kept too.
    try std.testing.expectEqual(@as(usize, 2), zooms.len);
    try std.testing.expectApproxEqAbs(@as(f64, 1.6), zooms[0].start, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 4.7), zooms[0].end, 1e-9);
}
