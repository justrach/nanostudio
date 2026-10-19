const std = @import("std");

/// What recording and encoding use, beyond what nanoui links.
const frameworks = [_][]const u8{ "AVFoundation", "CoreMedia", "CoreVideo", "ScreenCaptureKit", "CoreGraphics", "AppKit" };

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const nanoui = b.dependency("nanoui", .{ .target = target, .optimize = optimize }).module("nanoui");
    const filters = b.option([]const []const u8, "test-filter", "Run only the tests whose names contain this") orelse &.{};

    const mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "nanoui", .module = nanoui }},
    });
    for (frameworks) |f| mod.linkFramework(f, .{});
    const exe = b.addExecutable(.{ .name = "nanostudio", .root_module = mod });
    b.installArtifact(exe);
    const run = b.addRunArtifact(exe);
    run.addPassthruArgs();
    b.step("run", "Run nanostudio").dependOn(&run.step);

    const tests = b.addTest(.{ .filters = filters, .root_module = b.createModule(.{
        .root_source_file = b.path("src/tests.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "nanoui", .module = nanoui }},
    }) });
    for (frameworks) |f| tests.root_module.linkFramework(f, .{});
    b.step("test", "Run nanostudio's tests").dependOn(&b.addRunArtifact(tests).step);
}
