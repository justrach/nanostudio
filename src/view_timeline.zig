//! The timeline, as the reference's: play and the time, split, delete and
//! add a zoom; under a ruler, the video's clips (each its length at its
//! speed; a selected clip's edges drag to trim it) and the zooms (placed in
//! the output's time; their edges drag too), and the playhead, which a
//! click or a drag on the ruler moves.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const theme = @import("theme.zig");
const timeline = @import("timeline.zig");
const App = @import("app.zig").App;

const label_w: f32 = 64;
const handle_w: f32 = 7;

pub fn view(c: *ui.Context, a: *App) void {
    const p = a.project.?;
    const pl = &a.player.?;
    const box = ui.div(c).column().wFull().h(196).bg(theme.panel).border(theme.border).px(16).pt(10).pb(14).gap(10);
    defer box.end();
    controls(c, a);
    const rows = ui.div(c).row().wFull().grow().gap(8);
    defer rows.end();
    {
        const labels = ui.div(c).column().w(label_w).gap(10).pt(26);
        defer labels.end();
        ui.text(c, "VIDEO", .{ .size = 10, .weight = .semibold, .color = theme.faint });
        _ = c.leaf(.{ .height = .{ .px = 22 } }, .none, null);
        ui.text(c, "ZOOMS", .{ .size = 10, .weight = .semibold, .color = theme.faint });
    }
    ui.key(c, "tl-content");
    const content = ui.div(c).column().grow().hFull().gap(10).clip();
    defer content.end();
    const r = content.interaction().rect orelse ui.Rect{ .x = 0, .y = 0, .w = 600, .h = 120 };
    const dur = @max(p.duration(), 0.001);
    const W = @max(r.w, 1);
    drags(c, a, r.x, W, dur);
    ruler(c, a, W, dur);
    clips(c, a, W, dur);
    zooms(c, a, W, dur);
    // The playhead, over the tracks.
    const x = @as(f32, @floatCast(pl.t / dur)) * W;
    _ = c.leaf(.{ .absolute = true, .offset = .{ .x = x - 1, .y = 0 }, .width = .{ .px = 2 }, .height = .fill, .background = theme.accent }, .none, null);
    _ = c.leaf(.{ .absolute = true, .offset = .{ .x = x - 6, .y = 0 }, .width = .{ .px = 12 }, .height = .{ .px = 12 }, .radius = 6, .background = theme.accent }, .none, null);
}

fn clock(c: *ui.Context, t: f64) []const u8 {
    const tenths: u64 = @intFromFloat(@max(0, @floor(t * 10)));
    return c.print("{d}:{d:0>2}.{d}", .{ tenths / 600, (tenths / 10) % 60, tenths % 10 });
}

fn controls(c: *ui.Context, a: *App) void {
    const p = a.project.?;
    const pl = &a.player.?;
    const r = ui.div(c).row().wFull().gap(8).itemsCenter();
    defer r.end();
    if (ui.button(c, "", .{ .variant = .primary, .size = 12, .icon = if (pl.playing) "pause.fill" else "play.fill" }).clicked) pl.toggle(p.timeline);
    ui.text(c, c.print("{s} / {s}", .{ clock(c, pl.t), clock(c, p.duration()) }), .{ .size = 12, .mono = true, .color = theme.muted });
    ui.spacer(c);
    if (ui.button(c, "Split at Playhead", .{ .variant = .ghost, .size = 12, .icon = "scissors" }).clicked) split(a);
    if (ui.button(c, "Delete", .{ .variant = .ghost, .size = 12, .icon = "trash" }).clicked) removeSelected(a);
    if (ui.button(c, "Add Zoom", .{ .size = 12, .icon = "plus.magnifyingglass" }).clicked) p.addZoom(p.timeline.toSource(pl.t));
}

/// Splits the clip under the playhead.
pub fn split(a: *App) void {
    const p = a.project orelse return;
    const pl = &(a.player orelse return);
    p.edit();
    if (p.timeline.split(p.gpa, pl.t)) |i| {
        p.selection = .{ .clip = i };
        p.changed();
    } else _ = p.undos.pop();
}

/// Removes the selected clip or zoom.
pub fn removeSelected(a: *App) void {
    const p = a.project orelse return;
    switch (p.selection) {
        .none => {},
        .clip => |i| {
            p.edit();
            if (p.timeline.remove(i)) {
                p.selection = .none;
                p.changed();
                const pl = &a.player.?;
                pl.seek(pl.t, p.timeline);
            }
        },
        .zoom => |i| if (i < p.zooms.items.len) {
            p.edit();
            _ = p.zooms.orderedRemove(i);
            p.selection = .none;
            p.changed();
        },
    }
}

/// A drag under way follows the pointer; a release ends it.
fn drags(c: *ui.Context, a: *App, x0: f32, W: f32, dur: f64) void {
    const p = a.project.?;
    const pl = &a.player.?;
    const t = std.math.clamp(@as(f64, @floatCast((c.input.mouse.x - x0) / W)) * dur, 0, dur);
    if (!c.input.down) {
        // A zoom drawn on its track: from where the press began to here
        // (a click: two seconds from there).
        if (a.drag == .new_zoom) {
            const d = a.drag.new_zoom;
            const lo = @min(d.from, d.to);
            const hi = @max(d.from, d.to);
            if (hi - lo < 0.2) p.addZoom(p.timeline.toSource(lo) + 0.3) else {
                p.addZoom(p.timeline.toSource(lo) + 0.3);
                if (p.selection == .zoom) p.zooms.items[p.selection.zoom].end = p.timeline.toSource(hi);
                p.changed();
            }
        }
        a.drag = .none;
        return;
    }
    switch (a.drag) {
        .none => {},
        .playhead => pl.seek(t, p.timeline),
        .clip_edge => |d| {
            if (d.index >= p.timeline.slices.items.len) return;
            const s = p.timeline.slices.items[d.index];
            const b = p.timeline.bounds(d.index);
            // The source time under the pointer, through this clip's speed.
            const src = if (d.start) s.end - (b[1] - t) * s.speed else s.start + (t - b[0]) * s.speed;
            p.timeline.moveEdge(d.index, d.start, src, p.rec.duration);
            p.changed();
        },
        .new_zoom => |*d| d.to = t,
        .zoom_edge => |d| {
            if (d.index >= p.zooms.items.len) return;
            const z = &p.zooms.items[d.index];
            const src = p.timeline.toSource(t);
            if (d.start) z.start = std.math.clamp(src, 0, z.end - 0.2) else z.end = std.math.clamp(src, z.start + 0.2, p.rec.duration);
            p.changed();
        },
    }
}

fn ruler(c: *ui.Context, a: *App, W: f32, dur: f64) void {
    const p = a.project.?;
    const pl = &a.player.?;
    const r = ui.div(c).wFull().h(16).control();
    defer r.end();
    if (r.interaction().pressed and a.drag == .none) {
        a.drag = .playhead;
        pl.stop();
    }
    // A tick a second (every five when long), labelled.
    const every: f64 = if (dur > 60) 10 else if (dur > 20) 5 else 1;
    var s: f64 = 0;
    while (s <= dur) : (s += every) {
        const x = @as(f32, @floatCast(s / dur)) * W;
        _ = c.leaf(.{ .absolute = true, .offset = .{ .x = x, .y = 10 }, .width = .{ .px = 1 }, .height = .{ .px = 6 }, .background = theme.faint }, .none, null);
        const label = ui.div(c).absolute().offset(x + 3, 0);
        defer label.end();
        ui.text(c, c.print("{d}s", .{@as(u32, @intFromFloat(s))}), .{ .size = 9.5, .color = theme.faint, .mono = true });
    }
    _ = p;
}

fn clips(c: *ui.Context, a: *App, W: f32, dur: f64) void {
    const p = a.project.?;
    const track = ui.div(c).wFull().h(40).rounded(8).bg(theme.background);
    defer track.end();
    for (p.timeline.slices.items, 0..) |s, i| {
        ui.key(c, c.print("clip-{d}", .{i}));
        const b = p.timeline.bounds(i);
        const x = @as(f32, @floatCast(b[0] / dur)) * W;
        const w = @max(4, @as(f32, @floatCast((b[1] - b[0]) / dur)) * W - 2);
        const on = p.selection == .clip and p.selection.clip == i;
        const clip = ui.div(c).absolute().offset(x + 1, 2).w(w).h(36).rounded(7).bg(if (on) theme.accent.alpha(0.55) else theme.clip).border(if (on) theme.accent else theme.clip).px(8).itemsCenter().control();
        defer clip.end();
        if (clip.clicked()) p.selection = .{ .clip = i };
        if (w > 70) ui.text(c, if (s.speed != 1) c.print("Clip {d} · {d}×", .{ i + 1, s.speed }) else c.print("Clip {d}", .{i + 1}), .{ .size = 11, .weight = .medium, .color = theme.text });
        if (on) {
            edge(c, a, .{ .clip_edge = .{ .index = i, .start = true } }, 0);
            edge(c, a, .{ .clip_edge = .{ .index = i, .start = false } }, w - handle_w);
        }
    }
}

fn zooms(c: *ui.Context, a: *App, W: f32, dur: f64) void {
    const p = a.project.?;
    const track = ui.div(c).wFull().h(26).rounded(7).bg(theme.background).center().control();
    defer track.end();
    // Pressed on the track itself (not a zoom): a new zoom is drawn.
    if (track.interaction().pressed and a.drag == .none) {
        const r = track.interaction().rect orelse ui.Rect{ .x = 0, .y = 0, .w = W, .h = 26 };
        const t0 = std.math.clamp(@as(f64, @floatCast((c.input.mouse.x - r.x) / W)) * dur, 0, dur);
        a.drag = .{ .new_zoom = .{ .from = t0, .to = t0 } };
    }
    if (p.zooms.items.len == 0 and a.drag != .new_zoom) ui.text(c, "Click or drag to add zoom on cursor", .{ .size = 11, .color = theme.faint });
    if (a.drag == .new_zoom) {
        const d = a.drag.new_zoom;
        const x = @as(f32, @floatCast(@min(d.from, d.to) / dur)) * W;
        const w = @max(2, @as(f32, @floatCast(@abs(d.to - d.from) / dur)) * W);
        _ = c.leaf(.{ .absolute = true, .offset = .{ .x = x, .y = 2 }, .width = .{ .px = w }, .height = .{ .px = 22 }, .radius = 6, .background = theme.zoom.alpha(0.6) }, .none, null);
    }
    for (p.zooms.items, 0..) |z, i| {
        ui.key(c, c.print("zoom-{d}", .{i}));
        const o0 = p.timeline.toOutput(z.start);
        const o1 = p.timeline.toOutput(z.end);
        if (o1 - o0 < 0.01) continue;
        const x = @as(f32, @floatCast(o0 / dur)) * W;
        const w = @max(4, @as(f32, @floatCast((o1 - o0) / dur)) * W);
        const on = p.selection == .zoom and p.selection.zoom == i;
        const seg = ui.div(c).absolute().offset(x, 2).w(w).h(22).rounded(6).bg(if (on) theme.zoom.mix(theme.text, 0.25) else theme.zoom).px(6).itemsCenter().control();
        defer seg.end();
        if (seg.clicked()) p.selection = .{ .zoom = i };
        if (w > 50) ui.text(c, c.print("{d:.1}×", .{z.scale}), .{ .size = 10.5, .weight = .medium, .color = theme.text });
        if (on) {
            edge(c, a, .{ .zoom_edge = .{ .index = i, .start = true } }, 0);
            edge(c, a, .{ .zoom_edge = .{ .index = i, .start = false } }, w - handle_w);
        }
    }
}

/// A selected item's edge: pressing it starts dragging that edge.
fn edge(c: *ui.Context, a: *App, drag: @import("app.zig").Drag, x: f32) void {
    const h = ui.div(c).absolute().offset(x, 0).w(handle_w).hFull().rounded(3).bg(theme.text.alpha(0.85)).control();
    defer h.end();
    if (h.interaction().pressed and a.drag == .none) {
        a.project.?.edit();
        a.drag = drag;
    }
}
