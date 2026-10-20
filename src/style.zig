//! How a recording is dressed, as the reference's `style.rs` keeps it (the
//! same fields and names in recording.json): a background (a gradient or a
//! macOS wallpaper), the canvas's shape, the screen's padding, corners and
//! shadow, the zoom, the cursor and the camera's pace.
const std = @import("std");

pub const Background = struct { name: []const u8, from: u24, to: u24 };

pub const backgrounds = [_]Background{
    .{ .name = "Sunset", .from = 0xff7e5f, .to = 0xfeb47b },
    .{ .name = "Ocean", .from = 0x2193b0, .to = 0x6dd5ed },
    .{ .name = "Grape", .from = 0x8e2de2, .to = 0x4a00e0 },
    .{ .name = "Mint", .from = 0x11998e, .to = 0x38ef7d },
    .{ .name = "Candy", .from = 0xf953c6, .to = 0xb91d73 },
    .{ .name = "Midnight", .from = 0x0f2027, .to = 0x2c5364 },
    .{ .name = "Dusk", .from = 0x355c7d, .to = 0xc06c84 },
    .{ .name = "Graphite", .from = 0x232526, .to = 0x414345 },
};

/// macOS's own wallpapers, by file name in /System/Library/Desktop Pictures.
pub const wallpapers = [_][]const u8{
    "Sonoma",   "iMac Blue", "iMac Purple", "iMac Pink",   "iMac Orange",     "iMac Yellow", "iMac Green",
    "iMac Silver", "Mac Blue", "Mac Purple", "Mac Pink", "Mac Yellow", "Radial Sky Blue",
};

/// Solid colors for the background, as Screen Studio's Color tab offers.
pub const colors = [_]u24{ 0x16140f, 0x2a261e, 0xfaf8f3, 0xe8a33d, 0xd2674f, 0x7fa86b, 0x3b6fb0, 0x7a4ea3, 0x1f2937, 0xf3f4f6, 0x0ea5e9, 0xf472b6 };

pub const Fill = union(enum) { gradient: Background, wallpaper: usize, color: u24, image: []const u8 };

/// `Style.background` counts the gradients first, then the wallpapers.
pub fn fill(background: usize) Fill {
    if (background >= backgrounds.len and background - backgrounds.len < wallpapers.len) return .{ .wallpaper = background - backgrounds.len };
    return .{ .gradient = backgrounds[background % backgrounds.len] };
}

/// What fills the background: a picture chosen, a color, or a preset.
pub fn fillOf(s: Style) Fill {
    if (s.background_image) |p| if (p.len > 0) return .{ .image = p };
    if (s.background_color) |c| return .{ .color = c };
    return fill(s.background);
}

/// A wallpaper's file.
pub fn wallpaperPath(buf: []u8, i: usize) []const u8 {
    return std.fmt.bufPrint(buf, "/System/Library/Desktop Pictures/{s}.heic", .{wallpapers[i]}) catch "";
}

pub const Aspect = enum {
    auto,
    wide,
    vertical,
    square,
    classic,

    pub const all = [_]Aspect{ .auto, .wide, .vertical, .square, .classic };

    pub fn label(a: Aspect) []const u8 {
        return switch (a) {
            .auto => "Auto",
            .wide => "16:9",
            .vertical => "9:16",
            .square => "1:1",
            .classic => "4:3",
        };
    }

    pub fn ratio(a: Aspect, w: u32, h: u32) f32 {
        return switch (a) {
            .auto => @as(f32, @floatFromInt(w)) / @as(f32, @floatFromInt(@max(h, 1))),
            .wide => 16.0 / 9.0,
            .vertical => 9.0 / 16.0,
            .square => 1,
            .classic => 4.0 / 3.0,
        };
    }
};

/// The canvas for `aspect` with the given short side, even for the encoder.
pub fn canvasSize(aspect: Aspect, w: u32, h: u32, short: u32) [2]u32 {
    const r = aspect.ratio(w, h);
    const even = struct {
        fn f(v: f32) u32 {
            return @max(2, @as(u32, @intFromFloat(@round(v / 2))) * 2);
        }
    }.f;
    const s: f32 = @floatFromInt(short);
    return if (r >= 1) .{ even(s * r), short } else .{ short, even(s / r) };
}

/// Lengths in a style are in pixels of a canvas whose short side is 1080.
pub fn unit(w: f32, h: f32) f32 {
    return @min(w, h) / 1080;
}

pub const CursorStyle = enum {
    black,
    white,
    amber,

    pub const all = [_]CursorStyle{ .black, .white, .amber };

    pub fn label(c: CursorStyle) []const u8 {
        return switch (c) {
            .black => "Black",
            .white => "White",
            .amber => "Amber",
        };
    }
};

pub const Style = struct {
    background: usize = backgrounds.len,
    aspect: Aspect = .auto,
    padding: f32 = 90,
    radius: f32 = 14,
    shadow: f32 = 0.6,
    zoom: f32 = 2,
    auto_zoom: bool = true,
    cursor_style: CursorStyle = .black,
    cursor_visible: bool = true,
    cursor_size: f32 = 1.6,
    cursor_smoothing: f32 = 0.6,
    click_ripple: bool = true,
    motion_blur: f32 = 0.5,
    /// 0 slow, 0.5 default, 1 fast: the pace of zooms and pans together.
    camera_speed: f32 = 0.5,
    camera_visible: bool = true,
    camera_size: f32 = 0.24,
    camera_corner: u8 = 3,
    camera_circle: bool = false,
    keys_visible: bool = true,
    keys_position: u8 = 4,
    /// nanostudio's own: a solid color or a picture (a file) instead of the
    /// preset, and how much a picture behind is blurred (0 to 1).
    background_color: ?u24 = null,
    background_image: ?[]const u8 = null,
    background_blur: f32 = 0,
};

/// Looks to start from, as Screen Studio's presets.
pub const Preset = struct { name: []const u8, style: Style };

pub const presets = [_]Preset{
    .{ .name = "Default", .style = .{} },
    .{ .name = "Minimal", .style = .{ .background_color = 0x16140f, .padding = 40, .radius = 10, .shadow = 0.3, .cursor_size = 1.3 } },
    .{ .name = "Bold", .style = .{ .background = 2, .padding = 140, .radius = 24, .shadow = 1, .zoom = 2.4, .cursor_style = .amber, .cursor_size = 2 } },
    .{ .name = "Social vertical", .style = .{ .background = 4, .aspect = .vertical, .padding = 60, .radius = 20, .zoom = 2.6 } },
    .{ .name = "Clean light", .style = .{ .background_color = 0xfaf8f3, .padding = 80, .radius = 16, .shadow = 0.5, .cursor_style = .black } },
};

test "the canvas keeps its shape, even" {
    try std.testing.expectEqual([2]u32{ 1920, 1080 }, canvasSize(.wide, 3024, 1964, 1080));
    try std.testing.expectEqual([2]u32{ 1080, 1920 }, canvasSize(.vertical, 3024, 1964, 1080));
    try std.testing.expectEqual([2]u32{ 1662, 1080 }, canvasSize(.auto, 3024, 1964, 1080));
    try std.testing.expectEqual(Fill{ .wallpaper = 0 }, fill(backgrounds.len));
    try std.testing.expectEqualStrings("Ocean", fill(1).gradient.name);
}
