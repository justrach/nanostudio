//! The editor's inspector, as the reference's: Design (the background,
//! the canvas's shape, padding, corners, shadow) and Motion & Cursor (the
//! zoom, the camera's pace, the cursor's look and smoothing, click
//! ripples); with what's selected on the timeline (a clip's speed, a
//! zoom's level). A slider's whole drag is one undo.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const theme = @import("theme.zig");
const art = @import("art.zig");
const style_mod = @import("style.zig");
const timeline = @import("timeline.zig");
const App = @import("app.zig").App;

/// The gradients' swatches, made once.
var swatches: [style_mod.backgrounds.len][art.gradient_size * art.gradient_size * 4]u8 = undefined;
var swatches_made = false;

pub fn view(c: *ui.Context, a: *App) void {
    const p = a.project.?;
    // A drag ended: the next change is a new undo.
    if (!c.input.down) a.gesture = false;
    const side = ui.div(c).column().w(340).hFull().bg(theme.panel).border(theme.border);
    defer side.end();
    {
        const tabs = ui.div(c).row().wFull().p(12);
        defer tabs.end();
        var sel: usize = @intFromEnum(a.panel);
        if (nanoui.kit.tabs(c, &.{ "Design", "Motion & Cursor" }, &sel, .{ .variant = .segmented, .size = .sm })) a.panel = @enumFromInt(sel);
    }
    // A panel switched to eases in (keyed by panel: each enters anew).
    ui.key(c, @tagName(a.panel));
    const f = ui.motion.frame(c, .{ .initial = .{ .y = 8, .opacity = 0 }, .transition = .{ .spring = ui.motion.Spring.snappy } });
    const body = ui.div(c).column().grow().wFull().scrollY().px(16).pb(16).gap(18).motion(f);
    defer body.end();
    selection(c, a);
    switch (a.panel) {
        .design => design(c, a),
        .motion => motionPanel(c, a),
    }
    _ = p;
}

/// Before a change to the style: one undo for the gesture.
fn edit(a: *App) void {
    if (a.gesture) return;
    a.project.?.edit();
    a.gesture = true;
}

fn section(c: *ui.Context, title: []const u8) void {
    ui.text(c, title, .{ .size = 11, .weight = .semibold, .color = theme.faint });
}

/// A labelled slider; true while it changes.
fn slider(c: *ui.Context, a: *App, label: []const u8, value: *f32, min: f32, max: f32, comptime fmt: []const u8) bool {
    return sliderReset(c, a, label, value, min, max, fmt, null);
}

/// A slider with Reset (to `default`), as Screen Studio's.
fn sliderReset(c: *ui.Context, a: *App, label: []const u8, value: *f32, min: f32, max: f32, comptime fmt: []const u8, default: ?f32) bool {
    const r = ui.div(c).column().wFull().gap(6);
    defer r.end();
    {
        const h = ui.div(c).row().wFull().itemsCenter();
        defer h.end();
        ui.text(c, label, .{ .size = 12.5 });
        ui.spacer(c);
        ui.text(c, c.print(fmt, .{value.*}), .{ .size = 11.5, .color = theme.muted, .mono = true });
        if (default) |d| if (@abs(value.* - d) > 1e-4) {
            if (ui.button(c, "Reset", .{ .variant = .ghost, .size = 11 }).clicked) {
                a.gesture = false;
                edit(a);
                value.* = d;
                a.project.?.changed();
                a.gesture = false;
                return true;
            }
        };
    }
    var v = value.*;
    if (!ui.slider(c, &v, .{ .min = min, .max = max, .width = .fill })) return false;
    edit(a);
    value.* = v;
    a.project.?.changed();
    return true;
}

fn toggle(c: *ui.Context, a: *App, label: []const u8, value: *bool) void {
    var v = value.*;
    if (!ui.toggle(c, label, &v)) return;
    a.gesture = false;
    edit(a);
    value.* = v;
    a.project.?.changed();
    a.gesture = false;
}

fn selection(c: *ui.Context, a: *App) void {
    const p = a.project.?;
    switch (p.selection) {
        .none => {},
        .clip => |i| {
            if (i >= p.timeline.slices.items.len) return;
            section(c, c.print("CLIP {d} OF {d}", .{ i + 1, p.timeline.slices.items.len }));
            const s = &p.timeline.slices.items[i];
            const labels = [_][]const u8{ "0.5×", "1×", "1.5×", "2×", "3×", "4×" };
            var sel: usize = 1;
            for (timeline.speeds, 0..) |sp, k| if (@abs(sp - s.speed) < 1e-6) {
                sel = k;
            };
            ui.text(c, "Speed", .{ .size = 12.5 });
            if (ui.segmented(c, &labels, &sel)) {
                p.edit();
                s.speed = timeline.speeds[sel];
                p.changed();
            }
            if (ui.button(c, "Remove Clip", .{ .variant = .ghost, .size = 12, .icon = "trash" }).clicked) {
                p.edit();
                if (p.timeline.remove(i)) p.selection = .none;
                p.changed();
            }
        },
        .zoom => |i| {
            if (i >= p.zooms.items.len) return;
            const z = &p.zooms.items[i];
            section(c, "SELECTED ZOOM");
            _ = slider(c, a, "Zoom level", &z.scale, 1.2, 4, "{d:.1}×");
            if (ui.button(c, "Delete Zoom", .{ .variant = .ghost, .size = 12, .icon = "trash" }).clicked) {
                p.edit();
                _ = p.zooms.orderedRemove(i);
                p.selection = .none;
                p.changed();
            }
        },
    }
}

fn design(c: *ui.Context, a: *App) void {
    const p = a.project.?;
    const d: style_mod.Style = .{};
    section(c, "BACKGROUND");
    {
        var sel: usize = @intFromEnum(a.bg_tab);
        if (nanoui.kit.tabs(c, &.{ "Wallpaper", "Gradient", "Color", "Image" }, &sel, .{ .variant = .segmented, .size = .sm })) a.bg_tab = @enumFromInt(sel);
    }
    switch (a.bg_tab) {
        .wallpaper => {
            for (0..2) |row| {
                const grid = ui.div(c).row().wFull().gap(4);
                defer grid.end();
                const from = row * 7;
                for (from..@min(from + 7, style_mod.wallpapers.len)) |w| wallpaper(c, a, w);
            }
        },
        .gradient => {
            if (!swatches_made) {
                for (style_mod.backgrounds, 0..) |bg, i| art.gradient(&swatches[i], bg, 1, 1);
                swatches_made = true;
            }
            const grid = ui.div(c).row().wFull().gap(4);
            defer grid.end();
            for (style_mod.backgrounds, 0..) |_, i| swatch(c, a, i, .{ .width = art.gradient_size, .height = art.gradient_size, .bgra = &swatches[i] });
        },
        .color => for (0..2) |row| {
            const grid = ui.div(c).row().wFull().gap(4);
            defer grid.end();
            for (style_mod.colors[row * 6 .. row * 6 + 6]) |col| colorSwatch(c, a, col);
        },
        .image => {
            const r = ui.div(c).row().wFull().gap(8).itemsCenter();
            defer r.end();
            if (ui.button(c, "Choose image…", .{ .size = 12, .icon = "photo" }).clicked) a.chooseBackground();
            if (p.style.background_image) |path| ui.text(c, std.fs.path.basename(path), .{ .size = 11.5, .color = theme.muted }) else ui.text(c, "A picture of yours behind the screen", .{ .size = 11.5, .color = theme.faint });
        },
    }
    const blurs = style_mod.fillOf(p.style) == .wallpaper or style_mod.fillOf(p.style) == .image;
    if (blurs) _ = sliderReset(c, a, "Background blur", &p.style.background_blur, 0, 1, "{d:.2}", d.background_blur);
    section(c, "FRAME");
    ui.text(c, "Aspect", .{ .size = 12.5 });
    var labels: [style_mod.Aspect.all.len][]const u8 = undefined;
    for (style_mod.Aspect.all, 0..) |as, i| labels[i] = as.label();
    var sel: usize = @intFromEnum(p.style.aspect);
    if (ui.segmented(c, &labels, &sel)) {
        p.edit();
        p.style.aspect = @enumFromInt(sel);
        p.changed();
    }
    _ = sliderReset(c, a, "Padding", &p.style.padding, 0, 220, "{d:.0}", d.padding);
    _ = sliderReset(c, a, "Rounded corners", &p.style.radius, 0, 48, "{d:.0}", d.radius);
    _ = sliderReset(c, a, "Shadow", &p.style.shadow, 0, 1, "{d:.2}", d.shadow);
}

fn colorSwatch(c: *ui.Context, a: *App, col: u24) void {
    const p = a.project.?;
    ui.key(c, c.print("color-{x}", .{col}));
    const on = p.style.background_image == null and p.style.background_color == col;
    const b = ui.div(c).rounded(9).p(2).border(if (on) theme.accent else theme.background.alpha(0)).control();
    defer b.end();
    if (b.clicked()) {
        p.edit();
        p.style.background_color = col;
        p.style.background_image = null;
        p.changed();
    }
    _ = c.leaf(.{ .width = .{ .px = 32 }, .height = .{ .px = 32 }, .radius = 7, .background = .hex(col), .border = theme.border }, .none, null);
}

fn swatch(c: *ui.Context, a: *App, index: usize, tex: ui.Texture) void {
    const p = a.project.?;
    ui.key(c, c.print("bg-{d}", .{index}));
    const on = p.style.background == index and p.style.background_color == null and p.style.background_image == null;
    const b = ui.div(c).rounded(9).p(2).border(if (on) theme.accent else theme.background.alpha(0)).control();
    defer b.end();
    if (b.clicked()) {
        p.edit();
        p.style.background = index;
        p.style.background_color = null;
        p.style.background_image = null;
        p.changed();
    }
    ui.texture(c, .{ .width = .{ .px = 26 }, .height = .{ .px = 26 }, .radius = 7 }, tex, .{ 0, 0, 1, 1 }, 1);
}

fn wallpaper(c: *ui.Context, a: *App, w: usize) void {
    if (a.wall_thumbs[w] == null and !a.wall_tried[w]) {
        a.wall_tried[w] = true;
        var buf: [256]u8 = undefined;
        a.wall_thumbs[w] = art.decode(a.gpa, style_mod.wallpaperPath(&buf, w), 96) catch null;
    }
    const pic = a.wall_thumbs[w] orelse return;
    swatch(c, a, style_mod.backgrounds.len + w, .{ .width = pic.width, .height = pic.height, .bgra = pic.bgra });
}

fn motionPanel(c: *ui.Context, a: *App) void {
    const p = a.project.?;
    section(c, "ZOOM");
    if (slider(c, a, "Zoom level", &p.style.zoom, 1.2, 4, "{d:.1}×")) {
        // Applies to all zooms, as the reference's does.
        for (p.zooms.items) |*z| z.scale = p.style.zoom;
    }
    _ = slider(c, a, "Camera speed", &p.style.camera_speed, 0, 1, "{d:.2}");
    {
        const r = ui.div(c).row().wFull().gap(8);
        defer r.end();
        if (ui.button(c, "Auto from Clicks", .{ .size = 12, .icon = "cursorarrow.click" }).clicked) p.autoZoom();
        if (ui.button(c, "Clear All", .{ .variant = .ghost, .size = 12 }).clicked) {
            p.edit();
            p.zooms.clearRetainingCapacity();
            p.selection = .none;
            p.changed();
        }
    }
    section(c, "CURSOR");
    toggle(c, a, "Show cursor", &p.style.cursor_visible);
    var labels: [style_mod.CursorStyle.all.len][]const u8 = undefined;
    for (style_mod.CursorStyle.all, 0..) |cs, i| labels[i] = cs.label();
    var sel: usize = @intFromEnum(p.style.cursor_style);
    if (ui.segmented(c, &labels, &sel)) {
        p.edit();
        p.style.cursor_style = @enumFromInt(sel);
        p.changed();
    }
    _ = slider(c, a, "Cursor size", &p.style.cursor_size, 0.5, 3, "{d:.1}×");
    _ = slider(c, a, "Cursor smoothing", &p.style.cursor_smoothing, 0, 1, "{d:.2}");
    toggle(c, a, "Click ripple", &p.style.click_ripple);
}
