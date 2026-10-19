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

extern "c" fn time(t: ?*i64) i64;

pub const Screen = enum { home, editor };
pub const Panel = enum { design, motion };

/// A drag on the timeline: the playhead, a clip's edge, or a zoom's.
pub const Drag = union(enum) {
    none,
    playhead,
    clip_edge: struct { index: usize, start: bool },
    zoom_edge: struct { index: usize, start: bool },
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
    tray: ?*nanoui.Tray = null,

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
        if (a.tray) |t| t.destroy();
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

    pub fn showExport(a: *App) void {
        const path = a.exported orelse return;
        nanoui.shell.showInFolder(path);
    }

    /// Starts recording the chosen display into a new folder of the library.
    pub fn record(a: *App) void {
        if (a.display_count == 0) return;
        var buf: [1100]u8 = undefined;
        const now = time(null);
        const dir = std.fmt.bufPrint(&buf, "{s}/recording-{d}", .{ a.library_dir, now }) catch return;
        std.Io.Dir.cwd().createDirPath(a.io, dir) catch return;
        a.recorder.changed = .{ .ctx = a, .func = recorderChanged };
        a.recorder.start(dir, a.displays[a.display]);
    }

    fn recorderChanged(ctx: *anyopaque) void {
        const a: *App = @ptrCast(@alignCast(ctx));
        switch (a.recorder.state) {
            .recording => {
                // The window steps aside; the menu bar stops it.
                if (a.window) |w| w.hide();
                a.tray = nanoui.Tray.create(a.gpa, "nanostudio", .{ .symbol = "record.circle", .title = " Stop", .tooltip = "Stop recording", .menu = &.{
                    .{ .label = "Stop Recording", .click = .of(a, stopFromMenu) },
                } }) catch null;
            },
            .idle => {
                // Saved: open it.
                a.removeTray();
                a.reload();
                if (a.window) |w| w.show();
                a.open(a.recorder.dir);
            },
            .failed => {
                a.removeTray();
                if (a.window) |w| w.show();
            },
            else => {},
        }
        a.redraw();
    }

    fn removeTray(a: *App) void {
        if (a.tray) |t| t.destroy();
        a.tray = null;
    }

    fn stopFromMenu(a: *App, _: *nanoui.menu.Item) void {
        a.recorder.stop();
    }

    pub fn requestAccess(a: *App) void {
        a.screen_access = capture.requestScreenAccess();
    }
};
