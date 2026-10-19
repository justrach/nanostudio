//! The slices of a recording that make the final video, and the mapping
//! between output and source time, as the reference's `edit.rs`: ordered,
//! non-overlapping slices in source time, each at a speed; the gaps
//! between them are cut.
const std = @import("std");

pub const min_slice = 0.1;
pub const speeds = [_]f64{ 0.5, 1.0, 1.5, 2.0, 3.0, 4.0 };

pub const Slice = struct {
    start: f64,
    end: f64,
    speed: f64 = 1,

    pub fn lenOut(s: Slice) f64 {
        return @max(0, s.end - s.start) / s.speed;
    }
};

pub const Timeline = struct {
    slices: std.ArrayList(Slice) = .empty,

    pub fn full(gpa: std.mem.Allocator, dur: f64) !Timeline {
        var t: Timeline = .{};
        try t.slices.append(gpa, .{ .start = 0, .end = dur });
        return t;
    }

    pub fn deinit(t: *Timeline, gpa: std.mem.Allocator) void {
        t.slices.deinit(gpa);
    }

    pub fn clone(t: Timeline, gpa: std.mem.Allocator) !Timeline {
        return .{ .slices = try t.slices.clone(gpa) };
    }

    /// Source time of the output's last frame.
    pub fn sourceEnd(t: Timeline, dur: f64) f64 {
        const s = t.slices.items;
        return if (s.len == 0) dur else @min(s[s.len - 1].end, dur);
    }

    /// The output's length.
    pub fn duration(t: Timeline) f64 {
        var d: f64 = 0;
        for (t.slices.items) |s| d += s.lenOut();
        return d;
    }

    /// Output start and end of slice `i`.
    pub fn bounds(t: Timeline, i: usize) [2]f64 {
        var start: f64 = 0;
        for (t.slices.items[0..i]) |s| start += s.lenOut();
        return .{ start, start + t.slices.items[i].lenOut() };
    }

    /// The slice under output time `at`.
    pub fn indexAt(t: Timeline, at: f64) usize {
        var acc: f64 = 0;
        for (t.slices.items, 0..) |s, i| {
            acc += s.lenOut();
            if (at < acc) return i;
        }
        return t.slices.items.len -| 1;
    }

    pub fn toSource(t: Timeline, at: f64) f64 {
        const s = t.slices.items;
        if (s.len == 0) return at;
        var acc: f64 = 0;
        for (s) |sl| {
            const len = sl.lenOut();
            if (at < acc + len) return sl.start + @max(0, at - acc) * sl.speed;
            acc += len;
        }
        return s[s.len - 1].end;
    }

    /// Never decreases; a source time inside a cut maps to where the cut
    /// sits in the output.
    pub fn toOutput(t: Timeline, src: f64) f64 {
        var acc: f64 = 0;
        for (t.slices.items) |s| {
            if (src < s.start) return acc;
            if (src <= s.end) return acc + (src - s.start) / s.speed;
            acc += s.lenOut();
        }
        return acc;
    }

    pub fn containsSource(t: Timeline, src: f64) bool {
        for (t.slices.items) |s| if (src >= s.start and src <= s.end) return true;
        return false;
    }

    /// Splits the slice under output time `at`; the right half's index.
    pub fn split(t: *Timeline, gpa: std.mem.Allocator, at: f64) ?usize {
        if (t.slices.items.len == 0) return null;
        const i = t.indexAt(at);
        const src = t.toSource(at);
        const s = t.slices.items[i];
        if (src - s.start < min_slice or s.end - src < min_slice) return null;
        t.slices.items[i].end = src;
        t.slices.insert(gpa, i + 1, .{ .start = src, .end = s.end, .speed = s.speed }) catch return null;
        return i + 1;
    }

    /// Removes slice `i`, unless it is the last one left.
    pub fn remove(t: *Timeline, i: usize) bool {
        if (t.slices.items.len <= 1 or i >= t.slices.items.len) return false;
        _ = t.slices.orderedRemove(i);
        return true;
    }

    /// The room slice `i`'s edges may move within, in source time.
    pub fn edgeLimits(t: Timeline, i: usize, dur: f64) [2]f64 {
        const s = t.slices.items;
        const lo = if (i == 0) 0 else s[i - 1].end;
        const hi = if (i + 1 < s.len) s[i + 1].start else dur;
        return .{ lo, hi };
    }

    /// Moves slice `i`'s start (`start`) or end to source time `to`,
    /// within its room and keeping it at least `min_slice` long.
    pub fn moveEdge(t: *Timeline, i: usize, start: bool, to: f64, dur: f64) void {
        const lim = t.edgeLimits(i, dur);
        const s = &t.slices.items[i];
        if (start) s.start = std.math.clamp(to, lim[0], s.end - min_slice) else s.end = std.math.clamp(to, s.start + min_slice, lim[1]);
    }
};

test "maps through cuts and speed" {
    const gpa = std.testing.allocator;
    var tl: Timeline = .{};
    defer tl.deinit(gpa);
    try tl.slices.appendSlice(gpa, &.{ .{ .start = 0, .end = 2 }, .{ .start = 4, .end = 8, .speed = 2 } });
    try std.testing.expectEqual(@as(f64, 4), tl.duration());
    try std.testing.expectEqual(@as(f64, 1), tl.toSource(1));
    try std.testing.expectEqual(@as(f64, 6), tl.toSource(3));
    try std.testing.expectEqual(@as(f64, 2), tl.toOutput(3));
    try std.testing.expectEqual(@as(f64, 3), tl.toOutput(6));
    try std.testing.expectEqual(@as(f64, 8), tl.toSource(10));
    try std.testing.expectEqual(@as(usize, 1), tl.indexAt(2.5));
}

test "split, remove, and an edge's room" {
    const gpa = std.testing.allocator;
    var tl = try Timeline.full(gpa, 10);
    defer tl.deinit(gpa);
    try std.testing.expectEqual(@as(?usize, 1), tl.split(gpa, 4));
    try std.testing.expectEqual(@as(usize, 2), tl.slices.items.len);
    // Too near an edge: no split.
    try std.testing.expectEqual(@as(?usize, null), tl.split(gpa, 4.05));
    try std.testing.expect(tl.remove(0));
    try std.testing.expectEqual(@as(f64, 6), tl.duration());
    try std.testing.expectEqual(@as(f64, 4), tl.toSource(0));
    try std.testing.expect(!tl.remove(0));
    tl.moveEdge(0, true, 1, 10);
    try std.testing.expectEqual(@as(f64, 1), tl.slices.items[0].start);
    tl.moveEdge(0, false, 0.5, 10);
    try std.testing.expectApproxEqAbs(@as(f64, 1.1), tl.slices.items[0].end, 1e-9);
}
