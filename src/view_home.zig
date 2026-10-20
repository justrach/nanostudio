//! The home screen, as the reference lays it out: the library down the
//! side (each recording with its picture, when, and how long), and the
//! capture studio: the display to record, screen access, and Start.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const motion = ui.motion;
const theme = @import("theme.zig");
const library = @import("library.zig");
const App = @import("app.zig").App;

pub fn view(c: *ui.Context, a: *App) void {
    const root = ui.div(c).row().sizeFull().bg(theme.background);
    defer root.end();
    sidebar(c, a);
    const main = ui.div(c).column().grow().hFull();
    defer main.end();
    toolbar(c, a);
    const sc = ui.div(c).column().grow().wFull().scrollY().p(24);
    defer sc.end();
    // The studio eases in.
    const f = motion.frame(c, .{ .initial = .{ .y = 10, .opacity = 0 }, .transition = .{ .spring = motion.Spring.gentle } });
    const body = ui.div(c).column().wFull().gap(16).motion(f);
    defer body.end();
    hero(c);
    {
        // Side by side when there's room; else one over the other.
        const room = c.size.w - sidebar_w - 48;
        const wide = room >= 700;
        const r = if (wide) ui.div(c).row().wFull().gap(16).itemsStart() else ui.div(c).column().wFull().gap(16);
        defer r.end();
        // Widths in points: wrapped text measures by them.
        setup(c, a, if (wide) room - access_w - 16 else null);
        access(c, a, wide);
    }
    after(c);
}

/// A small label in capitals, in amber.
fn eyebrow(c: *ui.Context, s: []const u8) void {
    ui.text(c, s, .{ .size = 10.5, .weight = .semibold, .color = theme.accent });
}

fn card(c: *ui.Context) ui.Div {
    return ui.div(c).column().gap(12).p(18).rounded(16).bg(theme.panel).border(theme.border);
}

fn duration(c: *ui.Context, s: f64) []const u8 {
    const total: u64 = @intFromFloat(@max(0, @round(s)));
    return c.print("{d}:{d:0>2}", .{ total / 60, total % 60 });
}

const sidebar_w: f32 = 272;

fn sidebar(c: *ui.Context, a: *App) void {
    const side = ui.div(c).column().w(sidebar_w).hFull().bg(theme.panel).border(theme.border);
    defer side.end();
    {
        // Room for the window's traffic lights on the left.
        const h = ui.div(c).row().wFull().h(52).pl(84).pr(16).itemsCenter().gap(8);
        defer h.end();
        ui.icon(c, "film.stack", .{ .size = 14, .color = theme.muted });
        ui.text(c, "Library", .{ .size = 13, .weight = .semibold });
        ui.spacer(c);
        ui.text(c, c.print("{d}", .{a.entries.len}), .{ .size = 11.5, .color = theme.faint });
    }
    const list = ui.div(c).column().grow().wFull().scrollY().px(8).gap(2);
    defer list.end();
    if (a.entries.len == 0) {
        const e = ui.div(c).column().wFull().p(16).gap(6);
        defer e.end();
        ui.text(c, "No recordings yet.", .{ .size = 12.5, .color = theme.muted });
        ui.text(c, "Your takes land here, and in ~/Movies/Shitty Screen Studio.", .{ .size = 11.5, .color = theme.faint, .wrap = true });
        return;
    }
    for (a.entries, 0..) |*e, i| {
        ui.key(c, e.dir);
        // In one after another; a new take pushes the rest down smoothly.
        const f = motion.frame(c, .{ .initial = .{ .x = -12, .opacity = 0 }, .delay = motion.stagger(@min(i, 10), 0.03), .layout = true, .transition = .{ .spring = .{} } });
        const row = ui.div(c).row().wFull().gap(10).p(8).rounded(9).itemsCenter().hover(theme.hover).control().motion(f);
        defer row.end();
        if (row.clicked()) a.open(e.dir);
        thumb(c, a, e);
        const t = ui.div(c).column().grow().gap(3);
        defer t.end();
        ui.text(c, e.when, .{ .size = 12.5, .weight = .medium });
        ui.text(c, c.print("{s} · {d}×{d}", .{ duration(c, e.duration), e.width, e.height }), .{ .size = 11, .color = theme.muted, .mono = true });
    }
}

/// A recording's picture, made the first time it shows.
fn thumb(c: *ui.Context, a: *App, e: *library.Entry) void {
    if (!e.thumb_tried) {
        e.thumb_tried = true;
        const video = std.fs.path.join(c.alloc(), &.{ e.dir, "screen.mp4" }) catch "";
        e.thumb = library.thumbnail(a.gpa, video, e.duration);
    }
    const style: ui.Style = .{ .width = .{ .px = 64 }, .height = .{ .px = 40 }, .radius = 6, .background = theme.raised };
    if (e.thumb) |t| ui.texture(c, style, .{ .width = t.width, .height = t.height, .bgra = t.bgra }, .{ 0, 0, 1, 1 }, 1) else _ = c.leaf(style, .none, null);
}

fn toolbar(c: *ui.Context, a: *App) void {
    const bar = ui.div(c).row().wFull().h(52).px(20).itemsCenter().gap(8).border(theme.border);
    defer bar.end();
    ui.icon(c, "display", .{ .size = 14, .color = theme.muted });
    ui.text(c, "Capture", .{ .size = 13, .weight = .semibold });
    ui.spacer(c);
    const pill = ui.div(c).row().gap(6).itemsCenter().px(10).py(4).roundedFull().bg((if (a.screen_access) theme.success else theme.accent).alpha(0.1));
    defer pill.end();
    _ = c.leaf(.{ .width = .{ .px = 6 }, .height = .{ .px = 6 }, .radius = 3, .background = if (a.screen_access) theme.success else theme.accent }, .none, null);
    ui.text(c, if (a.screen_access) "Screen access granted" else "Screen access needed", .{ .size = 11.5, .color = theme.muted });
}

fn hero(c: *ui.Context) void {
    const h = ui.div(c).column().wFull().gap(8).pt(4).pb(4);
    defer h.end();
    {
        const r = ui.div(c).row().gap(8).itemsCenter();
        defer r.end();
        _ = c.leaf(.{ .width = .{ .px = 6 }, .height = .{ .px = 6 }, .radius = 3, .background = theme.accent }, .none, null);
        eyebrow(c, "CAPTURE STUDIO");
    }
    ui.text(c, "Ready when you are.", .{ .size = 28, .weight = .semibold });
    ui.text(c, "Choose a screen, then make your take. nanostudio follows your cursor and clicks, so the edit can zoom where you worked.", .{ .size = 14, .color = theme.muted, .wrap = true });
}

const access_w: f32 = 320;

fn setup(c: *ui.Context, a: *App, width: ?f32) void {
    const k = if (width) |w| card(c).w(w) else card(c).wFull();
    defer k.end();
    eyebrow(c, "01  /  SET UP YOUR TAKE");
    ui.text(c, "Source", .{ .size = 13, .weight = .semibold });
    if (a.display_count == 0) ui.text(c, "Looking for screens…", .{ .size = 12, .color = theme.muted });
    for (a.displays[0..a.display_count], 0..) |d, i| {
        ui.key(c, c.print("display-{d}", .{d.id}));
        const on = i == a.display;
        const row = ui.div(c).row().wFull().gap(10).p(10).rounded(10).itemsCenter().border(if (on) theme.accent else theme.border).bg(if (on) theme.selected else theme.background).control();
        defer row.end();
        if (row.clicked()) a.display = i;
        ui.icon(c, "display", .{ .size = 15, .color = if (on) theme.accent else theme.muted });
        ui.text(c, if (d.main) "Main Display" else c.print("Display {d}", .{i + 1}), .{ .size = 12.5, .weight = .medium });
        ui.spacer(c);
        ui.text(c, c.print("{d}×{d}", .{ @as(u32, @intFromFloat(d.width)), @as(u32, @intFromFloat(d.height)) }), .{ .size = 11.5, .color = theme.muted, .mono = true });
    }
    {
        const f = ui.div(c).row().wFull().pt(4);
        defer f.end();
        const busy = a.recorder.state == .starting or a.recorder.state == .saving;
        if (ui.button(c, if (busy) "Starting…" else "Start recording", .{ .variant = .primary, .size = 13, .icon = "record.circle" }).clicked and !busy) {
            a.bar_mode = .display;
            a.openBar();
        }
    }
    ui.text(c, "A capture bar opens: record a display or a window, and stop from it.", .{ .size = 11.5, .color = theme.faint, .wrap = true });
    // Why the last take didn't start, on its own line, the width of the card.
    if (a.recorder.state == .failed) {
        const w = ui.div(c).column().wFull().gap(4).p(10).rounded(8).bg(theme.danger.alpha(0.08)).border(theme.danger.alpha(0.3));
        defer w.end();
        {
            const t = ui.div(c).row().gap(6).itemsCenter();
            defer t.end();
            ui.icon(c, "exclamationmark.triangle.fill", .{ .size = 12, .color = theme.danger });
            ui.text(c, "The take didn't start", .{ .size = 12, .weight = .semibold, .color = theme.danger });
        }
        ui.text(c, a.recorder.failure, .{ .size = 11.5, .color = theme.danger, .wrap = true });
        if (a.recorder.needs_relaunch) {
            const r = ui.div(c).row().pt(4);
            defer r.end();
            if (ui.button(c, "Quit & Reopen", .{ .size = 12, .icon = "arrow.clockwise" }).clicked) a.relaunch();
        }
    }
}

fn access(c: *ui.Context, a: *App, wide: bool) void {
    const k = if (wide) card(c).w(access_w) else card(c).wFull();
    defer k.end();
    eyebrow(c, "BEFORE YOU ROLL");
    ui.text(c, "Screen access", .{ .size = 13, .weight = .semibold });
    if (a.screen_access) {
        ui.text(c, "nanostudio can record your screen. The window steps aside while you record.", .{ .size = 12, .color = theme.muted, .wrap = true });
        return;
    }
    ui.text(c, "Allow nanostudio in System Settings, Privacy & Security, Screen & System Audio Recording, then check again. macOS may ask you to reopen the app.", .{ .size = 12, .color = theme.muted, .wrap = true });
    const r = ui.div(c).row().gap(6);
    defer r.end();
    if (ui.button(c, "Allow Screen Access…", .{ .size = 12 }).clicked) a.requestAccess();
    if (ui.button(c, "Check Again", .{ .variant = .ghost, .size = 12 }).clicked) a.reload();
}

fn after(c: *ui.Context) void {
    const k = card(c).wFull();
    defer k.end();
    eyebrow(c, "AFTER THE TAKE");
    ui.text(c, "Make the take yours.", .{ .size = 18, .weight = .semibold });
    ui.text(c, "Trim the pauses. Speed through the slow parts. Zoom where you clicked. Dress it in a background, then export.", .{ .size = 12.5, .color = theme.muted, .wrap = true });
    const chips = ui.div(c).row().gap(14).pt(2);
    defer chips.end();
    for ([_][2][]const u8{ .{ "scissors", "Precise cuts" }, .{ "plus.magnifyingglass", "Smooth zooms" }, .{ "cursorarrow.rays", "Cursor polish" }, .{ "square.and.arrow.up", "One-click export" } }) |chip| {
        const r = ui.div(c).row().gap(5).itemsCenter();
        defer r.end();
        ui.icon(c, chip[0], .{ .size = 12, .color = theme.accent });
        ui.text(c, chip[1], .{ .size = 11.5, .color = theme.muted });
    }
}
