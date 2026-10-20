//! Sound through the editor: a recording with a tone (its loudness telling
//! the time), cut and sped up, exported: the file has sound as long as the
//! timeline, and at each output time it's as loud as the source time the
//! timeline maps it to. Nothing is played aloud.
const std = @import("std");
const testvideo = @import("testvideo.zig");
const audio = @import("audio.zig");
const reader = @import("reader.zig");
const Project = @import("project.zig").Project;
const Export = @import("export.zig").Export;
const rec = @import("recording.zig");

test "a recording's sound follows the timeline into the export" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const dir = "/tmp/nanostudio-test-audio";
    std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    try std.Io.Dir.cwd().createDirPath(io, dir);
    try testvideo.videoWith(gpa, dir, 3, true);
    try rec.save(gpa, io, dir, .{ .width = testvideo.width, .height = testvideo.height, .fps = testvideo.fps, .duration = 3, .points_width = testvideo.width / 2, .cursor = &.{} });
    try std.testing.expect(audio.has(dir ++ "/screen.mp4"));
    // The source: louder second by second.
    const src = try audio.loudness(gpa, dir ++ "/screen.mp4", 10);
    defer gpa.free(src);
    try std.testing.expect(src.len >= 28);
    try std.testing.expectApproxEqAbs(testvideo.loudnessOf(0.55), src[5], 0.03);
    try std.testing.expectApproxEqAbs(testvideo.loudnessOf(2.55), src[25], 0.03);

    // Cut 1.0 to 2.0; the last clip at 2x: 1.5 s.
    const p = try Project.open(gpa, io, dir);
    defer p.deinit();
    _ = p.timeline.split(gpa, 1.0);
    _ = p.timeline.split(gpa, 2.0);
    try std.testing.expect(p.timeline.remove(1));
    p.timeline.slices.items[1].speed = 2;
    p.changed();
    const out = dir ++ "/export.mp4";
    const e = try Export.start(gpa, p, out, 200);
    defer e.deinit();
    while (!e.step(10)) {}
    try std.testing.expectEqual(@as(?[]const u8, null), e.failed);
    try std.testing.expect(audio.has(out));
    const got = try audio.loudness(gpa, out, 10);
    defer gpa.free(got);
    try std.testing.expectApproxEqAbs(@as(f64, 15), @as(f64, @floatFromInt(got.len)), 1.5);
    // Output 0.5 s is source 0.5 s; output 1.25 s is source 2.5 s (2x).
    try std.testing.expectApproxEqAbs(testvideo.loudnessOf(0.55), got[5], 0.04);
    try std.testing.expectApproxEqAbs(testvideo.loudnessOf(2.5), got[12], 0.06);
    const i = try reader.info(out);
    try std.testing.expectApproxEqAbs(@as(f64, 1.5), i.duration, 0.1);
}
