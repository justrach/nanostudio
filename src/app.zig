//! nanostudio's state: the library, the recording open in the editor and
//! its playhead, an export under way, and the recorder; with what the views
//! call (open, play, export, record). Work is driven by input, by the
//! recorder's and exporter's callbacks, and by frames while video plays.
const std = @import("std");
const nanoui = @import("nanoui");
const library = @import("library.zig");
const rec = @import("recording.zig");
const capture = @import("capture.zig");
const canvas = @import("canvas.zig");
const Project = @import("project.zig").Project;
const Player = @import("player.zig").Player;
const Export = @import("export.zig").Export;
const bar = @import("view_bar.zig");

extern "c" fn time(t: ?*i64) i64;

pub const Screen = enum { home, editor };
pub const Panel = enum { design, motion };

/// A drag on the timeline: the playhead, a clip's edge, or a zoom's.
pub const Drag = union(enum) {
    none,
    playhead,
    clip_edge: struct { index: usize, start: bool },
    zoom_edge: struct { index: usize, start: bool },
    /// A new zoom being drawn on the zoom track, in output time.
    new_zoom: struct { from: f64, to: f64 },
};

pub const App = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    home: []const u8,
    library_dir: []const u8,
    arena: std.heap.ArenaAllocator,
    entries: []library.Entry = &.{},
    screen: Screen = .home,
    project: ?*Project = null,
    player: ?Player = null,
    art: canvas.Art,
    panel: Panel = .design,
    /// The inspector's background tab.
    bg_tab: enum { wallpaper, gradient, color, image } = .wallpaper,
    /// The top bar's Presets menu is open.
    presets_open: bool = false,
    presets_anchor: nanoui.ui.Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    drag: Drag = .none,
    /// A slider's drag under way: its changes are one undo.
    gesture: bool = false,
    /// The wallpapers' small pictures, decoded when the inspector shows.
    wall_thumbs: [@import("style.zig").wallpapers.len]?@import("art.zig").Picture = @splat(null),
    wall_tried: [@import("style.zig").wallpapers.len]bool = @splat(false),
    exporting: ?*Export = null,
    /// The last export's file, or why it failed.
    exported: ?[]const u8 = null,
    export_failed: ?[]const u8 = null,
    recorder: capture.Recorder,
    displays: [8]capture.Display = undefined,
    display_count: usize = 0,
    display: usize = 0,
    screen_access: bool = false,
    nanoapp: ?*nanoui.App = null,
    window: ?*nanoui.Window = null,
    /// The capture bar's window, and what it records.
    bar: ?*nanoui.Window = null,
    bar_mode: enum { display, window } = .display,
    bar_window: ?u32 = null,
    /// When recording started (host time), for the bar's clock.
    rec_started: f64 = 0,

    pub fn init(gpa: std.mem.Allocator, io: std.Io, home: []const u8) !App {
        var buf: [1024]u8 = undefined;
        var a: App = .{
            .gpa = gpa,
            .io = io,
            .home = home,
            .library_dir = try gpa.dupe(u8, rec.libraryDir(&buf, home)),
            .arena = .init(gpa),
            .art = .{ .gpa = gpa },
            .recorder = .{ .gpa = gpa, .io = io },
        };
        a.reload();
        return a;
    }

    pub fn deinit(a: *App) void {
        a.closeProject();
        if (a.exporting) |e| e.deinit();
        if (a.exported) |p| a.gpa.free(p);
        a.freeThumbs();
        for (a.wall_thumbs) |w| if (w) |pic| a.gpa.free(pic.bgra);
        a.recorder.deinit();
        a.art.deinit();
        a.arena.deinit();
        a.gpa.free(a.library_dir);
    }

    fn freeThumbs(a: *App) void {
        for (a.entries) |e| if (e.thumb) |t| a.gpa.free(t.bgra);
    }

    /// The library read again, and the displays and screen access.
    pub fn reload(a: *App) void {
        a.freeThumbs();
        _ = a.arena.reset(.retain_capacity);
        a.entries = library.load(a.arena.allocator(), a.io, a.library_dir) catch &.{};
        a.display_count = capture.displays(&a.displays).len;
        a.display = @min(a.display, a.display_count -| 1);
        a.screen_access = capture.screenAccess();
    }

    pub fn redraw(a: *App) void {
        if (a.window) |w| w.redraw();
    }

    pub fn open(a: *App, dir: []const u8) void {
        a.closeProject();
        const p = Project.open(a.gpa, a.io, dir) catch return;
        a.project = p;
        a.player = .{ .path = p.video };
        a.screen = .editor;
        a.panel = .design;
        a.bg_tab = switch (@import("style.zig").fillOf(p.style)) {
            .wallpaper => .wallpaper,
            .gradient => .gradient,
            .color => .color,
            .image => .image,
        };
    }

    /// Back to the library, the edits saved.
    pub fn closeProject(a: *App) void {
        if (a.project) |p| {
            if (p.dirty) p.save() catch {};
            p.deinit();
        }
        if (a.player) |*pl| pl.deinit();
        a.project = null;
        a.player = null;
        a.screen = .home;
    }

    pub fn startExport(a: *App) void {
        const p = a.project orelse return;
        if (a.exporting != null) return;
        if (p.dirty) p.save() catch {};
        const out = std.fs.path.join(a.gpa, &.{ p.dir, "export.mp4" }) catch return;
        defer a.gpa.free(out);
        a.export_failed = null;
        a.exporting = Export.start(a.gpa, p, out, 1080) catch {
            a.export_failed = "The export could not start.";
            return;
        };
        nanoui.App.after(0, a, exportStep);
    }

    fn exportStep(ctx: ?*anyopaque) callconv(.c) void {
        const a: *App = @ptrCast(@alignCast(ctx));
        const e = a.exporting orelse return;
        if (!e.step(6)) {
            a.redraw();
            return nanoui.App.after(0, a, exportStep);
        }
        if (e.failed) |why| a.export_failed = why else {
            if (a.exported) |old| a.gpa.free(old);
            a.exported = a.gpa.dupe(u8, e.out) catch null;
        }
        e.deinit();
        a.exporting = null;
        a.redraw();
    }

    /// An open panel for a background picture, after this frame (a modal
    /// panel can't run inside one).
    pub fn chooseBackground(a: *App) void {
        nanoui.App.after(0, a, chooseNow);
    }

    fn chooseNow(ctx: ?*anyopaque) callconv(.c) void {
        const a: *App = @ptrCast(@alignCast(ctx));
        const p = a.project orelse return;
        const paths = (nanoui.dialog.open(a.gpa, .{ .title = "Background Picture", .button = "Choose", .extensions = &.{ "png", "jpg", "jpeg", "heic", "webp", "tiff" } }) catch null) orelse return;
        defer nanoui.dialog.freePaths(a.gpa, paths);
        if (paths.len == 0) return;
        // Kept as long as the recording is open (its arena).
        const path = p.arena.allocator().dupe(u8, paths[0]) catch return;
        p.edit();
        p.style.background_image = path;
        p.changed();
        a.redraw();
    }

    /// Applies preset `i`'s look, keeping the recording's zooms.
    pub fn applyPreset(a: *App, i: usize) void {
        const p = a.project orelse return;
        p.edit();
        p.style = @import("style.zig").presets[i].style;
        for (p.zooms.items) |*z| z.scale = p.style.zoom;
        p.changed();
        a.presets_open = false;
    }

    pub fn showExport(a: *App) void {
        const path = a.exported orelse return;
        nanoui.shell.showInFolder(path);
    }

    /// Shows the capture bar (the main window steps aside), as Screen
    /// Studio's: Display or Window, then Record.
    pub fn openBar(a: *App) void {
        a.recorder.changed = .{ .ctx = a, .func = recorderChanged };
        if (a.bar == null) {
            const app = a.nanoapp orelse return;
            a.bar = app.newWindow(.{
                .title = "nanostudio capture",
                .width = bar.width,
                .height = bar.height,
                .min_width = bar.width,
                .min_height = bar.height,
                .resizable = false,
                .title_bar = .hidden,
                .always_on_top = true,
                .theme = @import("theme.zig").ui(),
                .content = .{ .view = .init(a, bar.view) },
            }) catch return;
            // No traffic lights on the bar; it moves by its background.
            const objc = nanoui.objc;
            for (0..3) |k| if (objc.msg(?objc.Object, a.bar.?.nswindow, "standardWindowButton:", .{@as(objc.NSInteger, @intCast(k))})) |b| objc.msg(void, b, "setHidden:", .{true});
            objc.msg(void, a.bar.?.nswindow, "setMovableByWindowBackground:", .{true});
        }
        a.sizeBar();
        if (a.bar) |b| b.focus();
        if (a.window) |w| w.hide();
        if (a.bar_mode == .window) a.recorder.listWindows();
    }

    /// Puts the bar away; the main window comes back.
    pub fn closeBar(a: *App) void {
        if (a.recorder.state == .recording or a.recorder.state == .saving) return;
        if (a.bar) |b| b.hide();
        if (a.window) |w| w.focus();
    }

    fn sizeBar(a: *App) void {
        const b = a.bar orelse return;
        const h = if (a.bar_mode == .window and a.recorder.state != .recording) bar.height + bar.list_height else bar.height;
        b.setSize(bar.width, h);
        // Near the top of the main screen, centered.
        if (a.display_count > 0) {
            const d = a.displays[0];
            b.setPosition((d.width - bar.width) / 2, 72);
        }
    }

    pub fn setBarMode(a: *App, mode: @TypeOf(a.bar_mode)) void {
        a.bar_mode = mode;
        if (mode == .window) a.recorder.listWindows();
        a.sizeBar();
        a.redraw();
    }

    /// The window chosen in the bar, if it's still listed.
    pub fn barWindow(a: *App) ?capture.WindowInfo {
        const id = a.bar_window orelse return null;
        for (a.recorder.windows.items) |w| if (w.id == id) return w;
        return null;
    }

    /// Starts recording what the bar chose into a new folder of the library.
    pub fn record(a: *App) void {
        const source: capture.Source = switch (a.bar_mode) {
            .display => if (a.display_count > 0) .{ .display = a.displays[a.display] } else return,
            .window => if (a.barWindow()) |w| .{ .window = w.id } else return,
        };
        var buf: [1100]u8 = undefined;
        const now = time(null);
        const dir = std.fmt.bufPrint(&buf, "{s}/recording-{d}", .{ a.library_dir, now }) catch return;
        std.Io.Dir.cwd().createDirPath(a.io, dir) catch return;
        a.recorder.changed = .{ .ctx = a, .func = recorderChanged };
        a.recorder.start(dir, source);
        a.redrawAll();
    }

    fn redrawAll(a: *App) void {
        a.redraw();
        if (a.bar) |b| b.redraw();
    }

    fn recorderChanged(ctx: *anyopaque) void {
        const a: *App = @ptrCast(@alignCast(ctx));
        switch (a.recorder.state) {
            .recording => {
                a.rec_started = @import("av.zig").CACurrentMediaTime();
                a.sizeBar();
                nanoui.App.after(1000, a, tick);
            },
            .idle => if (a.recorder.pending == .start) {
                // Saved: the bar goes, the take opens in the editor.
                if (a.bar) |b| b.hide();
                a.reload();
                if (a.window) |w| w.focus();
                a.open(a.recorder.dir);
            },
            else => {},
        }
        a.redrawAll();
    }

    /// The bar's clock, a second at a time while recording.
    fn tick(ctx: ?*anyopaque) callconv(.c) void {
        const a: *App = @ptrCast(@alignCast(ctx));
        if (a.recorder.state != .recording) return;
        if (a.bar) |b| b.redraw();
        nanoui.App.after(1000, a, tick);
    }

    pub fn requestAccess(a: *App) void {
        a.screen_access = capture.requestScreenAccess();
    }
};
