//! nanostudio's look: Codegraff's palettes (warm neutrals, an amber accent),
//! Codegraff Dark and Light as Harness and nanoterm have them, following
//! the system's appearance.
const nanoui = @import("nanoui");
const Color = nanoui.ui.Color;

const Seeds = struct {
    dark: bool,
    background: u24,
    shell: u24,
    raised: u24,
    text: u24,
    muted: u24,
    faint: u24,
    accent: u24,
    danger: u24,
    success: u24,
};

const codegraff_dark: Seeds = .{
    .dark = true,
    .background = 0x16140f,
    .shell = 0x1f1c16,
    .raised = 0x2a261e,
    .text = 0xedeae2,
    .muted = 0x9a9384,
    .faint = 0x5c564b,
    .accent = 0xe8a33d,
    .danger = 0xd2674f,
    .success = 0x7fa86b,
};

const codegraff_light: Seeds = .{
    .dark = false,
    .background = 0xfaf8f3,
    .shell = 0xf0ece3,
    .raised = 0xe7e1d5,
    .text = 0x1a1813,
    .muted = 0x6b6557,
    .faint = 0xa8a090,
    .accent = 0xc77d20,
    .danger = 0xb14228,
    .success = 0x5c7e47,
};

pub var dark = true;
pub var background: Color = undefined;
pub var panel: Color = undefined;
pub var raised: Color = undefined;
pub var hover: Color = undefined;
pub var selected: Color = undefined;
pub var border: Color = undefined;
pub var text: Color = undefined;
pub var muted: Color = undefined;
pub var faint: Color = undefined;
pub var accent: Color = undefined;
/// Text on an amber fill.
pub var on_accent: Color = undefined;
pub var danger: Color = undefined;
pub var success: Color = undefined;
/// The timeline's tracks: clips, and zooms.
pub var clip: Color = undefined;
pub var zoom: Color = undefined;

/// Takes the dark or light palette.
pub fn apply(is_dark: bool) void {
    const s = if (is_dark) codegraff_dark else codegraff_light;
    const tone: Color = if (is_dark) .{ .r = 1, .g = 1, .b = 1 } else .{};
    dark = is_dark;
    background = .hex(s.background);
    panel = .hex(s.shell);
    raised = .hex(s.raised);
    text = .hex(s.text);
    muted = .hex(s.muted);
    faint = .hex(s.faint);
    accent = .hex(s.accent);
    danger = .hex(s.danger);
    success = .hex(s.success);
    hover = background.mix(tone, if (is_dark) 0.07 else 0.05);
    selected = background.mix(accent, if (is_dark) 0.16 else 0.12);
    border = background.mix(tone, if (is_dark) 0.10 else 0.12);
    on_accent = if (is_dark) background else text;
    clip = background.mix(accent, if (is_dark) 0.28 else 0.22);
    zoom = background.mix(.hex(0x8a9bb0), if (is_dark) 0.45 else 0.35);
}

/// nanoui's theme in the palette.
pub fn ui() nanoui.ui.Theme {
    var t = if (dark) nanoui.ui.Theme.dark_theme else nanoui.ui.Theme.light;
    t.background = background;
    t.surface = panel;
    t.surface_hover = hover;
    t.text = text;
    t.muted = muted;
    t.border = border;
    t.accent = accent;
    t.accent_hover = accent.mix(text, 0.12);
    t.accent_text = on_accent;
    t.track = raised;
    t.danger = danger;
    t.success = success;
    return t;
}
