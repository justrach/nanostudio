//! nanostudio's tests: the model (timeline, style, recording.json, motion),
//! video in and out through AVFoundation, the canvas, the editor and export,
//! all on generated videos in temporary folders: no screen is captured.
test {
    _ = @import("timeline.zig");
    _ = @import("style.zig");
    _ = @import("recording.zig");
    _ = @import("motion.zig");
    _ = @import("tests_video.zig");
    _ = @import("art.zig");
    _ = @import("canvas.zig");
    _ = @import("tests_canvas.zig");
    _ = @import("library.zig");
    _ = @import("tests_export.zig");
    _ = @import("tests_ui.zig");
}
