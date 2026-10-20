//! One frame of the final video, drawn by nanoui: the background, the
//! screen (the recording's frame, its corners rounded, its shadow) inset by
//! the padding, the camera's zoom over all of it, the click ripples and the
//! cursor, as the reference's compositor lays them out. The editor's
//! preview and every exported frame are this view, so they match.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const style_mod = @import("style.zig");
const motion = @import("motion.zig");
const rec = @import("recording.zig");
const art = @import("art.zig");

/// Pixels the canvas draws besides the frame, made once and kept.
pub const Art = struct {
    gpa: std.mem.Allocator,
    cursors: [3]?[]u8 = .{ null, null, null },
    gradient: [art.gradient_size * art.gradient_size * 4]u8 = undefined,
    /// What `gradient` holds: a background and the canvas's shape.
    gradient_for: ?struct { bg: usize, ratio: f32 } = null,
    /// The picture behind (a wallpaper, or a file), and what it is.
    picture: ?art.Picture = null,
    picture_for: u64 = 0,
    /// It blurred, and by how much.
    blurred: ?art.Picture = null,
    blurred_for: struct { key: u64 = 0, blur: f32 = 0 } = .{},

    pub fn deinit(a: *Art) void {
        for (a.cursors) |c| if (c) |px| a.gpa.free(px);
        if (a.picture) |p| a.gpa.free(p.bgra);
        if (a.blurred) |p| a.gpa.free(p.bgra);
    }

    fn cursor(a: *Art, which: style_mod.CursorStyle) ?ui.Texture {
        const i = @intFromEnum(which);
        if (a.cursors[i] == null) a.cursors[i] = art.cursor(a.gpa, which) catch return null;
        return .{ .width = art.cursor_w, .height = art.cursor_h, .bgra = a.cursors[i].? };
    }

    /// The picture at `path`, decoded once; blurred by `blur` (0 to 1).
    fn pictureAt(a: *Art, path: []const u8, blur: f32) ?ui.Texture {
        const key = std.hash.Wyhash.hash(0, path);
        if (a.picture_for != key) {
            if (a.picture) |old| a.gpa.free(old.bgra);
            a.picture = art.decode(a.gpa, path, 2560) catch null;
            a.picture_for = key;
        }
        const p = a.picture orelse return null;
        if (blur <= 0.01) return .{ .width = p.width, .height = p.height, .bgra = p.bgra };
        if (a.blurred == null or a.blurred_for.key != key or @abs(a.blurred_for.blur - blur) > 1e-3) {
            if (a.blurred) |old| a.gpa.free(old.bgra);
            a.blurred = art.blurred(a.gpa, p, blur) catch null;
            a.blurred_for = .{ .key = key, .blur = blur };
        }
        const b = a.blurred orelse return null;
        return .{ .width = b.width, .height = b.height, .bgra = b.bgra };
    }

    /// The background for a `w` × `h` canvas: pixels, or a plain color.
    fn background(a: *Art, st: style_mod.Style, w: f32, h: f32) union(enum) { texture: ui.Texture, color: ui.Color, none } {
        switch (style_mod.fillOf(st)) {
            .gradient => |g| {
                const ratio = w / @max(h, 1);
                const same = if (a.gradient_for) |f| f.bg == st.background and @abs(f.ratio - ratio) < 1e-3 else false;
                if (!same) {
                    art.gradient(&a.gradient, g, w, h);
                    a.gradient_for = .{ .bg = st.background, .ratio = ratio };
                }
                return .{ .texture = .{ .width = art.gradient_size, .height = art.gradient_size, .bgra = &a.gradient } };
            },
            .color => |c| return .{ .color = .hex(c) },
            .wallpaper => |i| {
                var buf: [256]u8 = undefined;
                return if (a.pictureAt(style_mod.wallpaperPath(&buf, i), st.background_blur)) |t| .{ .texture = t } else .none;
            },
            .image => |path| return if (a.pictureAt(path, st.background_blur)) |t| .{ .texture = t } else .none,
        }
    }
};

/// What a frame shows.
pub const Frame = struct {
    /// The recording's frame at this time (null: still loading).
    screen: ?ui.Texture,
    /// The source's size in pixels, and its display's width in points.
    src_w: u32,
    src_h: u32,
    points_width: f32,
    style: style_mod.Style,
    camera: motion.Camera,
    cursor: [2]f32,
    clicks: []const rec.Click,
    /// Source time: for the ripples.
    t: f64,
};

/// The screen's place in a `w` × `h` canvas before the zoom.
pub fn screenRect(w: f32, h: f32, src_w: u32, src_h: u32, padding: f32) ui.Rect {
    const pad = padding * style_mod.unit(w, h);
    const aw = @max(16, w - 2 * pad);
    const ah = @max(16, h - 2 * pad);
    const aspect = @as(f32, @floatFromInt(src_w)) / @as(f32, @floatFromInt(@max(src_h, 1)));
    const sw, const sh = if (aw / ah > aspect) .{ ah * aspect, ah } else .{ aw, aw / aspect };
    return .{ .x = (w - sw) / 2, .y = (h - sh) / 2, .w = sw, .h = sh };
}

/// The zoom: `z`, and the offset that puts canvas point p at p * z + off.
pub const View = struct { z: f32, ox: f32, oy: f32 };

pub fn view(w: f32, h: f32, screen: ui.Rect, cam: motion.Camera) View {
    const z = @max(1, cam.scale);
    const hw = w / (2 * z);
    const hh = h / (2 * z);
    const fx = std.math.clamp(screen.x + cam.fx * screen.w, hw, w - hw);
    const fy = std.math.clamp(screen.y + cam.fy * screen.h, hh, h - hh);
    return .{ .z = z, .ox = w / 2 - z * fx, .oy = h / 2 - z * fy };
}

fn place(v: View, r: ui.Rect) ui.Rect {
    return .{ .x = r.x * v.z + v.ox, .y = r.y * v.z + v.oy, .w = r.w * v.z, .h = r.h * v.z };
}

fn abs(r: ui.Rect) ui.Style {
    return .{ .absolute = true, .offset = .{ .x = r.x, .y = r.y }, .width = .{ .px = r.w }, .height = .{ .px = r.h } };
}

/// Draws `f` as a `w` × `h` canvas (points) in the box now open.
pub fn draw(c: *ui.Context, a: *Art, w: f32, h: f32, f: Frame) void {
    const st = f.style;
    const s = style_mod.unit(w, h);
    const screen = screenRect(w, h, f.src_w, f.src_h, st.padding);
    const v = view(w, h, screen, f.camera);
    const box = c.open(.{ .width = .{ .px = w }, .height = .{ .px = h }, .clip = true }, null);
    defer c.end();
    _ = box;
    // The background, zoomed with the rest; a wallpaper covers the canvas.
    const whole = abs(place(v, .{ .x = 0, .y = 0, .w = w, .h = h }));
    switch (a.background(st, w, h)) {
        .none => {},
        .color => |col| {
            var fill = whole;
            fill.background = col;
            _ = c.leaf(fill, .none, null);
        },
        .texture => |bg| {
        var uv: [4]f32 = .{ 0, 0, 1, 1 };
        if (style_mod.fillOf(st) != .gradient) {
            const pr = @as(f32, @floatFromInt(bg.width)) / @as(f32, @floatFromInt(bg.height));
            const cr = w / h;
            if (pr > cr) {
                const k = cr / pr;
                uv = .{ 0.5 - k / 2, 0, 0.5 + k / 2, 1 };
            } else {
                const k = pr / cr;
                uv = .{ 0, 0.5 - k / 2, 1, 0.5 + k / 2 };
            }
        }
        ui.texture(c, whole, bg, uv, 1);
        },
    }
    const sr = place(v, screen);
    const radius = @min(st.radius * s * v.z, @min(sr.w, sr.h) / 2);
    // The screen's shadow, under it.
    if (st.shadow > 0) {
        var shadow = abs(sr);
        shadow.radius = radius;
        shadow.background = .{ .a = 0 };
        shadow.shadow = .{ .color = .{ .a = std.math.clamp(st.shadow, 0, 1) * 0.75 }, .blur = 36 * s * v.z, .y = 18 * s * v.z };
        _ = c.leaf(shadow, .none, null);
    }
    var screen_style = abs(sr);
    screen_style.radius = radius;
    if (f.screen) |frame| {
        ui.texture(c, screen_style, frame, .{ 0, 0, 1, 1 }, 1);
    } else {
        screen_style.background = .hex(0x111111);
        _ = c.leaf(screen_style, .none, null);
    }
    const px_per_pt = screen.w / @max(f.points_width, 1);
    const toCanvas = struct {
        fn p(r: ui.Rect, x: f32, y: f32) [2]f32 {
            return .{ r.x + x * r.w, r.y + y * r.h };
        }
    }.p;
    // Click ripples: a white disc and ring, growing and fading in half a second.
    if (st.click_ripple) for (f.clicks) |cl| {
        const age: f32 = @floatCast(f.t - cl.t);
        if (age < 0 or age >= 0.5) continue;
        const e = 1 - std.math.pow(f32, 1 - age / 0.5, 3);
        const at = toCanvas(screen, cl.x, cl.y);
        const r = (6 + 22 * e) * px_per_pt * @max(st.cursor_size, 0.5) * v.z;
        const cx = at[0] * v.z + v.ox;
        const cy = at[1] * v.z + v.oy;
        var ring = abs(.{ .x = cx - r, .y = cy - r, .w = 2 * r, .h = 2 * r });
        ring.radius = r;
        ring.background = .{ .r = 1, .g = 1, .b = 1, .a = 0.35 * (1 - e) };
        ring.border = .{ .r = 1, .g = 1, .b = 1, .a = 0.9 * (1 - e) };
        ring.border_width = 2 * px_per_pt * v.z;
        _ = c.leaf(ring, .none, null);
    };
    // The cursor, its tip where it points.
    if (st.cursor_visible and f.cursor[0] >= -0.01 and f.cursor[0] <= 1.01 and f.cursor[1] >= -0.01 and f.cursor[1] <= 1.01) {
        if (a.cursor(st.cursor_style)) |tex| {
            const k = px_per_pt * st.cursor_size * v.z;
            const at = toCanvas(screen, f.cursor[0], f.cursor[1]);
            const x = at[0] * v.z + v.ox - art.cursor_margin * k;
            const y = at[1] * v.z + v.oy - art.cursor_margin * k;
            const size_w = @as(f32, @floatFromInt(art.cursor_w)) / art.cursor_px * k;
            const size_h = @as(f32, @floatFromInt(art.cursor_h)) / art.cursor_px * k;
            ui.texture(c, abs(.{ .x = x, .y = y, .w = size_w, .h = size_h }), tex, .{ 0, 0, 1, 1 }, 1);
        }
    }
}

test "the screen fits inside the padding; the zoom keeps the canvas covered" {
    const r = screenRect(1920, 1080, 3024, 1964, 90);
    try std.testing.expectApproxEqAbs(@as(f32, 900), r.h, 0.5);
    try std.testing.expectApproxEqAbs(@as(f32, 960), r.x + r.w / 2, 0.5);
    // Zoomed 2x at the screen's top-left corner: clamped so the canvas's
    // top-left stays at the top left.
    const v = view(1920, 1080, r, .{ .scale = 2, .fx = 0, .fy = 0 });
    try std.testing.expectApproxEqAbs(@as(f32, 0), v.ox, 0.5);
    try std.testing.expectApproxEqAbs(@as(f32, 0), v.oy, 0.5);
    const none = view(1920, 1080, r, .{});
    try std.testing.expectEqual(View{ .z = 1, .ox = 0, .oy = 0 }, none);
}
