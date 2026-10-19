//! The camera and the cursor over time, as the reference's `motion.rs`
//! computes them, stepped at 120 Hz from the start: the cursor follows its
//! samples on a spring (`cursor_smoothing`); within a zoom the camera
//! pushes in toward the click along one line, then follows the cursor with
//! a dead zone, faster near the view's edge; out of a zoom it eases back.
const std = @import("std");
const rec = @import("recording.zig");
const Style = @import("style.zig").Style;

pub const step = 1.0 / 120.0;
const dead_zone: f32 = 0.5;
const edge_boost_max: f32 = 2.5;
const zoom_in_kick: f32 = 14;
const end_hold = 0.15;

const Tuning = struct {
    zoom_in: f32,
    zoom_out: f32,
    pan_omega: f32,
    lookahead: f64,

    fn init(speed: f32) Tuning {
        const s = std.math.clamp(speed, 0, 1);
        const pick = struct {
            fn f(sp: f32, slow: f32, mid: f32, fast: f32) f32 {
                return if (sp < 0.5) slow + (mid - slow) * sp * 2 else mid + (fast - mid) * (sp - 0.5) * 2;
            }
        }.f;
        return .{ .zoom_in = pick(s, 0.9, 0.6, 0.4), .zoom_out = pick(s, 1.5, 1.0, 0.6), .pan_omega = pick(s, 7, 11, 16), .lookahead = pick(s, 0.4, 0.3, 0.2) };
    }
};

const Spring = struct {
    pos: f32,
    vel: f32 = 0,
    omega: f32,

    fn stepTo(s: *Spring, target: f32, dt: f32) void {
        const accel = s.omega * s.omega * (target - s.pos) - 2 * s.omega * s.vel;
        s.vel += accel * dt;
        s.pos += s.vel * dt;
    }
};

const Pan = struct {
    goal: Spring,
    pos: Spring,
    omega: f32,

    fn init(p: f32, omega: f32) Pan {
        return .{ .goal = .{ .pos = p, .omega = omega }, .pos = .{ .pos = p, .omega = omega }, .omega = omega };
    }

    fn stepTo(p: *Pan, target: f32, dt: f32, boost: f32) void {
        const omega = p.omega * boost;
        p.goal.omega = omega;
        p.pos.omega = omega;
        p.goal.stepTo(target, dt);
        p.pos.stepTo(p.goal.pos, dt);
    }
};

/// A quintic ease that keeps its velocity when retargeted.
const Ease = struct {
    from: f32,
    vel: f32 = 0,
    to: f32,
    elapsed: f32 = 0,
    dur: f32 = 1,
    kick: f32 = 0,

    fn sample(e: Ease) [2]f32 {
        const u = std.math.clamp(e.elapsed / e.dur, 0, 1);
        const uu = u * u;
        const uuu = uu * u;
        const d = e.to - e.from;
        const v = e.vel * e.dur;
        const a = e.kick * d;
        const w = 1 - u;
        const pos = e.from + d * uuu * (10 - 15 * u + 6 * uu) + v * (u - 6 * uuu + 8 * uuu * u - 3 * uuu * uu) + a * 0.5 * uu * w * w * w;
        const dpos = d * 30 * uu * w * w + v * (1 - 18 * uu + 32 * uuu - 15 * uuu * u) + a * (u * w * w * w - 1.5 * uu * w * w);
        return .{ pos, dpos / e.dur };
    }

    fn retarget(e: *Ease, to: f32, dur: f32, kick: f32) void {
        if (@abs(to - e.to) < 1e-6) return;
        const s = e.sample();
        e.* = .{ .from = s[0], .vel = s[1], .to = to, .dur = dur, .kick = kick };
    }

    fn stepBy(e: *Ease, dt: f32) f32 {
        e.elapsed += dt;
        return e.sample()[0];
    }
};

pub const Camera = struct { scale: f32 = 1, fx: f32 = 0.5, fy: f32 = 0.5 };
pub const Frame = struct { cursor: [2]f32 = .{ 0.5, 0.5 }, camera: Camera = .{} };

/// The cursor's position at `t`, between its samples.
pub fn rawCursor(samples: []const rec.CursorSample, t: f64) [2]f32 {
    if (samples.len == 0) return .{ 0.5, 0.5 };
    var lo: usize = 0;
    var hi: usize = samples.len;
    while (lo < hi) {
        const mid = (lo + hi) / 2;
        if (samples[mid].t <= t) lo = mid + 1 else hi = mid;
    }
    if (lo == 0) return .{ samples[0].x, samples[0].y };
    if (lo >= samples.len) return .{ samples[samples.len - 1].x, samples[samples.len - 1].y };
    const a = samples[lo - 1];
    const b = samples[lo];
    const k: f32 = @floatCast((t - a.t) / @max(b.t - a.t, 1e-9));
    return .{ a.x + (b.x - a.x) * k, a.y + (b.y - a.y) * k };
}

fn zoomAt(zooms: []const rec.ZoomSegment, t: f64) ?rec.ZoomSegment {
    for (zooms) |z| if (t >= z.start and t < z.end and z.scale > 1) return z;
    return null;
}

/// Where a zoom aims: its first click, else where the cursor settles.
fn zoomAim(samples: []const rec.CursorSample, seg: rec.ZoomSegment, settle: f64) [2]f32 {
    for (samples, 0..) |s, i| {
        if (s.t < seg.start) continue;
        if (s.t >= seg.end) break;
        if (s.down and (i == 0 or !samples[i - 1].down)) return .{ s.x, s.y };
    }
    return rawCursor(samples, @min(settle, seg.end));
}

fn edgeBoost(cursor: [2]f32, view: [2]f32, half: f32) f32 {
    const reach = @max(@abs(cursor[0] - view[0]), @abs(cursor[1] - view[1])) / half;
    const u = std.math.clamp((reach - 0.7) / 0.5, 0, 1);
    return 1 + edge_boost_max * u * u * (3 - 2 * u);
}

fn follow(current: ?[2]f32, cursor: [2]f32, ahead: [2]f32, scale: f32) [2]f32 {
    const half = 0.5 / scale;
    const c = struct {
        fn f(v: f32, h: f32) f32 {
            return std.math.clamp(v, h, 1 - h);
        }
    }.f;
    const cur = current orelse return .{ c(cursor[0], half), c(cursor[1], half) };
    const slack = half * dead_zone;
    const inside = @abs(cursor[0] - cur[0]) <= slack and @abs(cursor[1] - cur[1]) <= slack;
    return if (inside) .{ c(cur[0], half), c(cur[1], half) } else .{ c(ahead[0], half), c(ahead[1], half) };
}

pub const Motion = struct {
    frames: []Frame,

    pub fn deinit(m: *Motion, gpa: std.mem.Allocator) void {
        gpa.free(m.frames);
    }

    /// Steps the camera and cursor from 0 to `duration` (source time);
    /// zooms let go in time to have eased out by `end`.
    pub fn build(gpa: std.mem.Allocator, samples: []const rec.CursorSample, zooms: []const rec.ZoomSegment, duration: f64, end: f64, style: Style) !Motion {
        const tune: Tuning = .init(style.camera_speed);
        const smoothing = style.cursor_smoothing;
        const n: usize = @as(usize, @intFromFloat(@ceil(@max(duration, 0) / step))) + 2;
        const dt: f32 = step;
        const start = rawCursor(samples, 0);
        const cursor_omega = 60 - 50 * std.math.clamp(smoothing, 0, 1);
        var cx: Spring = .{ .pos = start[0], .omega = cursor_omega };
        var cy: Spring = .{ .pos = start[1], .omega = cursor_omega };
        var log_size: Ease = .{ .from = 0, .to = 0 };
        var size: f32 = 1;
        var pan_x: Pan = .init(0.5, tune.pan_omega);
        var pan_y: Pan = .init(0.5, tune.pan_omega);
        var target: ?[2]f32 = null;
        var seg_size: f32 = 0.5;
        var landing: f64 = 0;
        const release_by = end - tune.zoom_out - end_hold;
        const frames = try gpa.alloc(Frame, n);
        for (frames, 0..) |*f, i| {
            const t = @as(f64, @floatFromInt(i)) * step;
            const raw = rawCursor(samples, t);
            if (smoothing <= 0.01) {
                cx.pos = raw[0];
                cy.pos = raw[1];
            } else {
                cx.stepTo(raw[0], dt);
                cy.stepTo(raw[1], dt);
            }
            const seg = if (t < release_by) zoomAt(zooms, t) else null;
            if (seg) |z| {
                seg_size = 1 / z.scale;
                const half = 0.5 / z.scale;
                if (target == null) {
                    var aim = zoomAim(samples, z, t + tune.zoom_in);
                    aim = .{ std.math.clamp(aim[0], half, 1 - half), std.math.clamp(aim[1], half, 1 - half) };
                    if (size > 0.98) {
                        pan_x = .init(aim[0], tune.pan_omega);
                        pan_y = .init(aim[1], tune.pan_omega);
                    }
                    target = aim;
                    landing = t + tune.zoom_in;
                }
                const settling = t < landing;
                const focus = if (settling) target.? else follow(target, raw, rawCursor(samples, t + tune.lookahead), z.scale);
                target = focus;
                const boost: f32 = if (settling) 1 else edgeBoost(raw, .{ pan_x.pos.pos, pan_y.pos.pos }, half);
                pan_x.stepTo(focus[0], dt, boost);
                pan_y.stepTo(focus[1], dt, boost);
                log_size.retarget(@log(seg_size), tune.zoom_in, zoom_in_kick);
                size = @exp(log_size.stepBy(dt));
            } else {
                target = null;
                log_size.retarget(0, tune.zoom_out, 0);
                size = @exp(log_size.stepBy(dt));
            }
            const progress = std.math.clamp((1 - size) / @max(1 - seg_size, 1e-3), 0, 1);
            f.* = .{ .cursor = .{ cx.pos, cy.pos }, .camera = .{
                .scale = 1 / std.math.clamp(size, 0.05, 1),
                .fx = 0.5 + (pan_x.pos.pos - 0.5) * progress,
                .fy = 0.5 + (pan_y.pos.pos - 0.5) * progress,
            } };
        }
        return .{ .frames = frames };
    }

    /// The frame at source time `t`, between steps.
    pub fn at(m: Motion, t: f64) Frame {
        if (m.frames.len == 0) return .{};
        const f = @min(@max(t, 0) / step, @as(f64, @floatFromInt(m.frames.len - 1)));
        const i: usize = @intFromFloat(@floor(f));
        const j = @min(i + 1, m.frames.len - 1);
        const k: f32 = @floatCast(f - @floor(f));
        const a = m.frames[i];
        const b = m.frames[j];
        const lerp = struct {
            fn l(p: f32, q: f32, kk: f32) f32 {
                return p + (q - p) * kk;
            }
        }.l;
        return .{ .cursor = .{ lerp(a.cursor[0], b.cursor[0], k), lerp(a.cursor[1], b.cursor[1], k) }, .camera = .{
            .scale = lerp(a.camera.scale, b.camera.scale, k),
            .fx = lerp(a.camera.fx, b.camera.fx, k),
            .fy = lerp(a.camera.fy, b.camera.fy, k),
        } };
    }
};

test "a zoom pushes in toward its click, holds, and eases back out" {
    const gpa = std.testing.allocator;
    const samples = [_]rec.CursorSample{
        .{ .t = 0, .x = 0.5, .y = 0.5, .down = false },
        .{ .t = 1.0, .x = 0.2, .y = 0.25, .down = false },
        .{ .t = 1.2, .x = 0.2, .y = 0.25, .down = true },
        .{ .t = 1.3, .x = 0.2, .y = 0.25, .down = false },
    };
    const zooms = [_]rec.ZoomSegment{.{ .start = 0.8, .end = 3.5, .scale = 2 }};
    var m = try Motion.build(gpa, &samples, &zooms, 6, 6, .{});
    defer m.deinit(gpa);
    try std.testing.expectApproxEqAbs(@as(f32, 1), m.at(0.5).camera.scale, 0.01);
    const held = m.at(3.0).camera;
    try std.testing.expectApproxEqAbs(@as(f32, 2), held.scale, 0.05);
    // Aimed at the click, kept inside the frame (half of 1/2 from the edge).
    try std.testing.expectApproxEqAbs(@as(f32, 0.25), held.fx, 0.03);
    try std.testing.expectApproxEqAbs(@as(f32, 0.25), held.fy, 0.03);
    try std.testing.expectApproxEqAbs(@as(f32, 1), m.at(5.8).camera.scale, 0.02);
    // The cursor has settled on its sample.
    try std.testing.expectApproxEqAbs(@as(f32, 0.2), m.at(3.0).cursor[0], 0.01);
}
