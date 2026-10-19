//! nanostudio: a screen recorder and editor on nanoui, after the
//! reference recorder (justrach/shitty-screen-studio): record a display
//! with your cursor and clicks, then trim, speed up, zoom where you clicked,
//! dress it in a background and export, in Codegraff's colors.
const std = @import("std");
const nanoui = @import("nanoui");
const App = @import("app.zig").App;
const view = @import("view.zig");
const theme = @import("theme.zig");

pub fn main(init: std.process.Init) !void {
    const app = try nanoui.App.create(init, .{ .name = "nanostudio" });
    defer app.destroy();
    theme.apply(nanoui.isDark());
    const home = init.environ_map.get("HOME") orelse "/";
    var a = try App.init(init.gpa, init.io, home);
    defer a.deinit();
    a.nanoapp = app;
    // nanostudio <recording folder>: open it in the editor.
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len > 1 and args[1].len > 0 and args[1][0] != '-') a.open(args[1]);
    a.window = try app.newWindow(.{
        .title = "nanostudio",
        .width = 1240,
        .height = 820,
        .min_width = 900,
        .min_height = 600,
        .title_bar = .hidden,
        .theme = theme.ui(),
        .content = .{ .view = .init(&a, view.view) },
    });
    try app.run();
}
