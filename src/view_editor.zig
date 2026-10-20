//! The editor, as the reference lays it out: a top bar (back to the
//! library, undo, redo, export), the preview (the canvas at the playhead,
//! fitted; a click plays or pauses), the inspector, and the timeline.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const kit = nanoui.kit;
const motion = ui.motion;
const theme = @import("theme.zig");
const av = @import("av.zig");
const canvas = @import("canvas.zig");
const style_mod = @import("style.zig");
const inspector = @import("view_inspector.zig");
const timeline_view = @import("view_timeline.zig");
const App = @import("app.zig").App;

pub fn view(c: *ui.Context, a: *App) void {
    const p = a.project orelse return;
    const pl = &(a.player orelse return);
    keys(c, a);
    if (pl.tick(p.timeline)) c.animationFrame();
    const root = ui.div(c).column().sizeFull().bg(theme.background);
    defer root.end();
    topbar(c, a);
    // Back to the library: the editor is gone for the rest of this frame.
    if (a.project == null) return;
    {
        const mid = ui.div(c).row().grow().wFull();
        defer mid.end();
        preview(c, a);
        inspector.view(c, a);
    }
    timeline_view.view(c, a);
    presets(c, a);
}

/// The Presets menu under its button: it springs open, and Escape or a
/// click elsewhere closes it.
fn presets(c: *ui.Context, a: *App) void {
    var items: [style_mod.presets.len]kit.MenuItem = undefined;
    for (style_mod.presets, 0..) |pr, i| items[i] = .{ .label = pr.name, .icon = "sparkles" };
    if (kit.menu(c, "presets", &a.presets_open, a.presets_anchor, &items, .{ .placement = .bottom_end, .width = 220 })) |i| a.applyPreset(i);
}

/// Space plays, ⌘Z undoes, ⇧⌘Z redoes, S splits, ⌫ removes the selection,
/// ← and → step a frame.
fn keys(c: *ui.Context, a: *App) void {
    const p = a.project.?;
    const pl = &a.player.?;
    if (c.shortcut(.{ .key = 'z', .cmd = true })) p.undo();
    if (c.shortcut(.{ .key = 'z', .cmd = true, .shift = true })) p.redo();
    if (std.mem.eql(u8, c.input.chars, " ")) pl.toggle(p.timeline);
    if (std.mem.eql(u8, c.input.chars, "s")) timeline_view.split(a);
    const step = 1 / @as(f64, @max(p.info.fps, 1));
    if (c.input.key) |k| switch (k) {
        .left => pl.seek(pl.t - step, p.timeline),
        .right => pl.seek(pl.t + step, p.timeline),
        .backspace, .delete => timeline_view.removeSelected(a),
        else => {},
    };
}

fn topbar(c: *ui.Context, a: *App) void {
    const p = a.project.?;
    // Room for the window's traffic lights on the left.
    const bar = ui.div(c).row().wFull().h(52).pl(84).pr(14).gap(8).itemsCenter().bg(theme.panel).border(theme.border);
    defer bar.end();
    if (ui.button(c, "Library", .{ .variant = .ghost, .size = 12.5, .icon = "chevron.left" }).clicked) {
        a.closeProject();
        a.reload();
        return;
    }
    ui.text(c, std.fs.path.basename(p.dir), .{ .size = 13, .weight = .semibold });
    ui.text(c, c.print("{d}×{d} · {d:.0} fps", .{ p.info.width, p.info.height, p.info.fps }), .{ .size = 11.5, .color = theme.faint, .mono = true });
    ui.spacer(c);
    {
        const pb = ui.div(c).row().gap(6).itemsCenter().px(10).py(6).rounded(8).hover(theme.hover).control();
        defer pb.end();
        if (pb.clicked()) a.presets_open = !a.presets_open;
        a.presets_anchor = pb.interaction().rect;
        ui.icon(c, "sparkles", .{ .size = 13, .color = theme.muted });
        ui.text(c, "Presets", .{ .size = 12.5 });
        ui.icon(c, "chevron.down", .{ .size = 9, .color = theme.muted });
    }
    if (ui.button(c, "", .{ .variant = .ghost, .size = 12, .icon = "arrow.uturn.backward" }).clicked) p.undo();
    if (ui.button(c, "", .{ .variant = .ghost, .size = 12, .icon = "arrow.uturn.forward" }).clicked) p.redo();
    if (a.exporting) |e| {
        // The figure and the bar ease between the batches of frames.
        const shown = motion.number(c, "export", e.progress(), .{ .tween = .{ .duration = 0.25, .ease = .linear } });
        ui.text(c, c.print("Exporting… {d:.0}%", .{shown * 100}), .{ .size = 12, .color = theme.muted });
        ui.progress(c, shown, .{ .px = 120 });
    } else {
        if (a.export_failed) |why| ui.text(c, why, .{ .size = 12, .color = theme.danger });
        // Finished: it slides in beside Export.
        if (motion.present(c, "export-done", a.exported != null and a.export_failed == null, .{ .initial = .{ .x = 12, .opacity = 0 }, .exit = .{ .opacity = 0 }, .transition = .{ .spring = motion.Spring.snappy } })) |f| {
            const done = ui.div(c).row().gap(6).itemsCenter().motion(f);
            defer done.end();
            ui.icon(c, "checkmark.circle.fill", .{ .size = 13, .color = theme.success });
            ui.text(c, "Export finished", .{ .size = 12, .color = theme.success });
            if (ui.button(c, "Show in Finder", .{ .variant = .ghost, .size = 12 }).clicked) a.showExport();
        }
        if (ui.button(c, "Export…", .{ .variant = .primary, .size = 12.5, .icon = "square.and.arrow.up" }).clicked) a.startExport();
    }
}

/// The canvas's size in a box of `w` × `h`, its shape kept.
fn fit(w: f32, h: f32, ratio: f32) [2]f32 {
    return if (w / @max(h, 1) > ratio) .{ h * ratio, h } else .{ w, w / ratio };
}

fn preview(c: *ui.Context, a: *App) void {
    const p = a.project.?;
    const pl = &a.player.?;
    const box = ui.div(c).grow().hFull().center().p(24).control();
    defer box.end();
    if (box.clicked()) pl.toggle(p.timeline);
    // The box's size last frame (the first frame guesses).
    const r = box.interaction().rect orelse ui.Rect{ .x = 0, .y = 0, .w = 800, .h = 450 };
    const size = style_mod.canvasSize(p.style.aspect, p.info.width, p.info.height, 1080);
    const ratio = @as(f32, @floatFromInt(size[0])) / @as(f32, @floatFromInt(size[1]));
    const wh = fit(@max(64, r.w - 48), @max(36, r.h - 48), ratio);
    const src = p.timeline.toSource(pl.t);
    const m = p.motionNow().at(src);
    // Opened: the canvas eases in.
    const f = motion.frame(c, .{ .initial = .{ .scale = 0.97, .opacity = 0 }, .transition = .{ .spring = .{} } });
    const holder = ui.div(c).motion(f);
    defer holder.end();
    canvas.draw(c, &a.art, @floor(wh[0]), @floor(wh[1]), .{
        .screen = if (pl.frameAt(src)) |pb| av.texture(pb) else null,
        .src_w = p.info.width,
        .src_h = p.info.height,
        .points_width = if (p.rec.points_width > 0) p.rec.points_width else @floatFromInt(p.info.width / 2),
        .style = p.style,
        .camera = m.camera,
        .cursor = m.cursor,
        .clicks = p.clicks,
        .t = src,
    });
}
