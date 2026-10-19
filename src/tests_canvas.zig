//! The canvas drawn: the gradient behind, the screen inset by the padding,
//! the cursor where it points, and a zoom that magnifies around its focus.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const canvas = @import("canvas.zig");
const style_mod = @import("style.zig");
const testvideo = @import("testvideo.zig");

const Scene = struct {
    art: canvas.Art,
    frame: canvas.Frame,
    fn view(s: *Scene, c: *ui.Context) void {
        canvas.draw(c, &s.art, 480, 270, s.frame);
    }
};

fn at(p: anytype, scale: f32, x: f32, y: f32) [4]u8 {
    const px: usize = @intFromFloat(x * scale);
    const py: usize = @intFromFloat(y * scale);
    return p.bytes[(py * p.width + px) * 4 ..][0..4].*;
}

test "the canvas: background, padded screen, cursor; a zoom magnifies" {
    const gpa = std.testing.allocator;
    const px = try gpa.alloc(u8, testvideo.width * testvideo.height * 4);
    defer gpa.free(px);
    testvideo.frame(px, 1.0);
    var s: Scene = .{ .art = .{ .gpa = gpa }, .frame = .{
        .screen = .{ .width = testvideo.width, .height = testvideo.height, .bgra = px },
        .src_w = testvideo.width,
        .src_h = testvideo.height,
        .points_width = testvideo.width / 2,
        .style = .{ .background = 1, .shadow = 0 },
        .camera = .{},
        .cursor = .{ 0.1, 0.1 },
        .clicks = &.{},
        .t = 1,
    } };
    defer s.art.deinit();
    var t: ui.Tester = undefined;
    try t.init(gpa, .init(&s, Scene.view), .{ .width = 480, .height = 270 });
    defer t.deinit();
    t.settle(0.1);
    const flat = try t.render(gpa);
    defer flat.deinit(gpa);
    try t.screenshot("/tmp/nanostudio-canvas.png");
    // Ocean's top-left color (0x2193b0) in the canvas's corner.
    const corner = at(flat, t.scale, 2, 2);
    try std.testing.expect(@abs(@as(i32, corner[2]) - 0x21) < 12 and @abs(@as(i32, corner[0]) - 0xb0) < 12);
    // The screen, inset by the padding (90 of 1080: 22.5 at this size),
    // shows the frame: its background's gray at the screen's middle left.
    const screen = canvas.screenRect(480, 270, testvideo.width, testvideo.height, 90);
    try std.testing.expectApproxEqAbs(@as(f32, 225), screen.h, 0.5);
    const inside = at(flat, t.scale, screen.x + 6, screen.y + screen.h / 2);
    try std.testing.expect(@abs(@as(i32, inside[1]) - testvideo.redOf(1.0)) < 8);
    // The cursor's black body just below and right of its tip.
    const tip_x = screen.x + 0.1 * screen.w;
    const tip_y = screen.y + 0.1 * screen.h;
    const k = screen.w / (testvideo.width / 2) * 1.6;
    const body = at(flat, t.scale, tip_x + 3 * k, tip_y + 9 * k);
    try std.testing.expect(body[0] < 30 and body[1] < 30 and body[2] < 30);

    // Zoomed 2x on the screen's center: the white square (at x 60 of 320 at
    // 1 s) moves away from the center, twice as far.
    s.frame.camera = .{ .scale = 2, .fx = 0.5, .fy = 0.5 };
    s.frame.cursor = .{ -1, -1 };
    t.settle(0.1);
    const zoomed = try t.render(gpa);
    defer zoomed.deinit(gpa);
    try t.screenshot("/tmp/nanostudio-canvas-zoomed.png");
    const sq_x = screen.x + (60.0 + 20.0) / @as(f32, testvideo.width) * screen.w;
    const center_x: f32 = 240;
    const zx = center_x + (sq_x - center_x) * 2;
    const white = at(zoomed, t.scale, zx, 135);
    try std.testing.expect(white[0] > 230 and white[1] > 230 and white[2] > 230);
}
