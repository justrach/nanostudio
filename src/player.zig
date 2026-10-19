//! The editor's playhead: the final video's time, playing or not, and the
//! recording's frame for it, decoded in order (opening the file again to
//! go back, or to jump far ahead). While it plays, the view asks for a
//! frame each time the display can show one; stopped, nothing runs.
const std = @import("std");
const av = @import("av.zig");
const reader = @import("reader.zig");
const timeline = @import("timeline.zig");

/// Further ahead than this, opening the file again beats decoding there.
const jump = 1.5;

pub const Player = struct {
    path: []const u8,
    reader: ?reader.Reader = null,
    /// Output time.
    t: f64 = 0,
    playing: bool = false,
    last: f64 = 0,

    pub fn deinit(p: *Player) void {
        if (p.reader) |*r| r.deinit();
    }

    /// The recording's frame at source time `src` (null while it can't be had).
    pub fn frameAt(p: *Player, src: f64) ?av.CVPixelBufferRef {
        const stale = if (p.reader) |*r| !r.reaches(src) or (if (r.current) |c| src - c.t > jump else false) else true;
        if (stale) {
            if (p.reader) |*r| r.deinit();
            p.reader = reader.Reader.open(p.path, @max(0, src - 0.05)) catch null;
        }
        const r = &(p.reader orelse return null);
        return r.at(src);
    }

    pub fn toggle(p: *Player, tl: timeline.Timeline) void {
        if (!p.playing and p.t >= tl.duration() - 0.05) p.t = 0;
        p.playing = !p.playing;
        p.last = av.CACurrentMediaTime();
    }

    pub fn seek(p: *Player, t: f64, tl: timeline.Timeline) void {
        p.t = std.math.clamp(t, 0, tl.duration());
        p.last = av.CACurrentMediaTime();
    }

    /// Moves the playhead on by the time passed; true while it plays.
    pub fn tick(p: *Player, tl: timeline.Timeline) bool {
        if (!p.playing) return false;
        const now = av.CACurrentMediaTime();
        p.t += @min(now - p.last, 0.1);
        p.last = now;
        if (p.t >= tl.duration()) {
            p.t = tl.duration();
            p.playing = false;
        }
        return p.playing;
    }
};
