//! The capture bar, a floating window as Screen Studio's: ✕ to put it
//! away, Display or Window, the system's sound and the microphone, and
//! Record; choosing Window lists the windows to pick from. While recording it shows the time and Stop, above
//! everything, and is kept out of the recording.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const motion = ui.motion;
const theme = @import("theme.zig");
const av = @import("av.zig");
const capture = @import("capture.zig");
const App = @import("app.zig").App;

pub const width: f64 = 800;
pub const height: f64 = 76;
pub const list_height: f64 = 300;

pub fn view(a: *App, c: *ui.Context) void {
    const bar_bg = theme.background.mix(.{}, if (theme.dark) 0.25 else 0.0);
    const root = ui.div(c).column().sizeFull().bg(bar_bg);
    defer root.end();
    switch (a.recorder.state) {
        .recording, .saving => recording(c, a),
        else => choosing(c, a),
    }
}

/// A tall button with an icon over its label.
fn tool(c: *ui.Context, icon: []const u8, label: []const u8, on: bool) bool {
    const b = ui.div(c).column().gap(4).itemsCenter().px(12).py(8).rounded(10).bg(if (on) theme.accent.alpha(0.16) else theme.background.alpha(0)).hover(theme.hover).control();
    defer b.end();
    ui.icon(c, icon, .{ .size = 20, .color = if (on) theme.accent else theme.text });
    ui.text(c, label, .{ .size = 11, .color = if (on) theme.accent else theme.muted });
    return b.clicked();
}

fn divider(c: *ui.Context) void {
    _ = c.leaf(.{ .width = .{ .px = 1 }, .height = .{ .px = 40 }, .background = theme.border }, .none, null);
}

fn choosing(c: *ui.Context, a: *App) void {
    {
        const row = ui.div(c).row().wFull().h(@floatCast(height)).px(14).gap(10).itemsCenter();
        defer row.end();
        {
            const x = ui.div(c).size(30, 30).roundedFull().center().bg(theme.text.alpha(0.12)).hover(theme.text.alpha(0.2)).control();
            defer x.end();
            if (x.clicked()) return a.closeBar();
            ui.icon(c, "xmark", .{ .size = 12, .weight = .bold, .color = theme.text });
        }
        divider(c);
        if (tool(c, "display", "Display", a.bar_mode == .display)) a.setBarMode(.display);
        if (tool(c, "macwindow", "Window", a.bar_mode == .window)) a.setBarMode(.window);
        divider(c);
        const r = &a.recorder;
        if (tool(c, if (r.system_audio) "speaker.wave.2.fill" else "speaker.slash", "System audio", r.system_audio)) r.system_audio = !r.system_audio;
        if (capture.microphoneSupported()) {
            const denied = capture.microphoneAccess() == 2 or capture.microphoneAccess() == 1;
            if (tool(c, if (r.microphone) "mic.fill" else "mic.slash", if (denied) "Mic blocked" else "Microphone", r.microphone and !denied)) {
                r.microphone = !r.microphone and !denied;
                if (r.microphone) capture.requestMicrophone(r);
            }
        }
        divider(c);
        const what = ui.div(c).column().grow().gap(2);
        {
            defer what.end();
            switch (a.bar_mode) {
                .display => if (a.display_count > 0) {
                    const d = a.displays[a.display];
                    ui.text(c, if (d.main) "Main Display" else c.print("Display {d}", .{a.display + 1}), .{ .size = 13, .weight = .semibold });
                    ui.text(c, c.print("{d}×{d}", .{ @as(u32, @intFromFloat(d.width)), @as(u32, @intFromFloat(d.height)) }), .{ .size = 11, .color = theme.muted, .mono = true });
                },
                .window => if (a.barWindow()) |w| {
                    ui.text(c, w.app, .{ .size = 13, .weight = .semibold });
                    ui.text(c, if (w.title.len > 0) w.title else "Untitled window", .{ .size = 11, .color = theme.muted });
                } else ui.text(c, "Pick a window below", .{ .size = 12.5, .color = theme.muted }),
            }
            if (a.recorder.state == .failed) ui.text(c, if (a.recorder.needs_relaunch) "Allow Screen Recording in System Settings, then reopen nanostudio: macOS applies it only then." else a.recorder.failure, .{ .size = 11, .color = theme.danger, .wrap = true });
        }
        if (a.recorder.state == .failed and a.recorder.needs_relaunch) {
            const re = ui.div(c).row().gap(8).itemsCenter().px(16).py(10).roundedFull().bg(theme.accent).control();
            defer re.end();
            if (re.clicked()) a.relaunch();
            ui.icon(c, "arrow.clockwise", .{ .size = 12, .weight = .bold, .color = .{ .r = 1, .g = 1, .b = 1 } });
            ui.text(c, "Quit & Reopen", .{ .size = 13, .weight = .semibold, .color = .{ .r = 1, .g = 1, .b = 1 } });
            return;
        }
        const ready = a.bar_mode == .display or a.barWindow() != null;
        const starting = a.recorder.state == .starting;
        const press = motion.frame(c, .{ .press = .{ .scale = 0.94 }, .hover = .{ .scale = 1.03 }, .transition = .{ .spring = motion.Spring.bouncy } });
        const rec = ui.div(c).row().gap(8).itemsCenter().px(16).py(10).roundedFull().bg(if (ready and !starting) theme.danger else theme.danger.alpha(0.35)).control().motion(press);
        defer rec.end();
        if (rec.clicked() and ready and !starting) a.record();
        _ = c.leaf(.{ .width = .{ .px = 10 }, .height = .{ .px = 10 }, .radius = 5, .background = .{ .r = 1, .g = 1, .b = 1 } }, .none, null);
        ui.text(c, if (starting) "Starting…" else "Record", .{ .size = 13, .weight = .semibold, .color = .{ .r = 1, .g = 1, .b = 1 } });
    }
    if (a.bar_mode != .window) return;
    // The windows, to pick one.
    _ = c.leaf(.{ .width = .fill, .height = .{ .px = 1 }, .background = theme.border }, .none, null);
    const list = ui.div(c).column().grow().wFull().scrollY().p(8).gap(2);
    defer list.end();
    if (a.recorder.windows.items.len == 0) {
        ui.text(c, if (a.screen_access) "Looking for windows…" else "Allow screen access to list windows.", .{ .size = 12, .color = theme.muted });
        return;
    }
    for (a.recorder.windows.items, 0..) |w, i| {
        ui.key(c, c.print("win-{d}", .{w.id}));
        const on = a.bar_window == w.id;
        const f = motion.frame(c, .{ .initial = .{ .y = 6, .opacity = 0 }, .delay = motion.stagger(@min(i, 12), 0.025), .transition = .{ .spring = motion.Spring.snappy } });
        const row = ui.div(c).row().wFull().gap(10).px(10).py(7).rounded(8).itemsCenter().bg(if (on) theme.selected else theme.background.alpha(0)).hover(theme.hover).control().motion(f);
        defer row.end();
        if (row.clicked()) a.bar_window = w.id;
        ui.icon(c, "macwindow", .{ .size = 13, .color = if (on) theme.accent else theme.muted });
        ui.text(c, w.app, .{ .size = 12.5, .weight = .medium });
        ui.text(c, if (w.title.len > 0) w.title else "Untitled", .{ .size = 12, .color = theme.muted });
        ui.spacer(c);
        ui.text(c, c.print("{d}×{d}", .{ @as(u32, @intFromFloat(w.width)), @as(u32, @intFromFloat(w.height)) }), .{ .size = 11, .color = theme.faint, .mono = true });
    }
}

fn recording(c: *ui.Context, a: *App) void {
    const row = ui.div(c).row().wFull().h(@floatCast(height)).px(18).gap(12).itemsCenter();
    defer row.end();
    // The recording dot breathes.
    const pulse = motion.keyframes(c, .{ .values = &.{ .{ .scale = 1, .opacity = 1 }, .{ .scale = 0.7, .opacity = 0.45 }, .{ .scale = 1, .opacity = 1 } }, .duration = 1.4, .repeat = null });
    const dot = ui.div(c).w(12).h(12).roundedFull().bg(theme.danger).motion(pulse);
    dot.end();
    const secs: u64 = @intFromFloat(@max(0, av.CACurrentMediaTime() - a.rec_started));
    ui.text(c, c.print("{d}:{d:0>2}", .{ secs / 60, secs % 60 }), .{ .size = 16, .weight = .semibold, .mono = true });
    ui.text(c, if (a.recorder.state == .saving) "Saving…" else switch (a.recorder.source) {
        .display => "Recording the display",
        .window => "Recording a window",
    }, .{ .size = 12.5, .color = theme.muted });
    ui.spacer(c);
    if (a.recorder.state == .saving) return;
    const stop = ui.div(c).row().gap(8).itemsCenter().px(16).py(10).roundedFull().bg(theme.text).control();
    defer stop.end();
    if (stop.clicked()) a.recorder.stop();
    _ = c.leaf(.{ .width = .{ .px = 10 }, .height = .{ .px = 10 }, .radius = 2, .background = theme.background }, .none, null);
    ui.text(c, "Stop", .{ .size = 13, .weight = .semibold, .color = theme.background });
}
