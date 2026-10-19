//! nanostudio's window: the home screen (library and capture) or the editor.
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const App = @import("app.zig").App;

pub fn view(a: *App, c: *ui.Context) void {
    switch (a.screen) {
        .home => @import("view_home.zig").view(c, a),
        .editor => @import("view_editor.zig").view(c, a),
    }
}
