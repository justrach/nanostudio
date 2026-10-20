# Third-party notices

nanostudio's own code is licensed under the MIT License in [`LICENSE`](LICENSE).

## Shitty Screen Studio

nanostudio follows [Shitty Screen Studio](https://github.com/hewliyang/shitty-screen-studio)
by Li Yang ([@hewliyang](https://github.com/hewliyang)), by way of
[Recorder](https://github.com/justrach/shitty-screen-studio), a fork of it.
That upstream repository doesn't carry a license. Li Yang gave his permission
for nanostudio to take from it, and he's credited as a contributor.

What nanostudio takes from it, rewritten in Zig:
- the camera's motion: its springs and eases, the push in toward a click, the
  dead zone the cursor moves in, the ease out (`src/motion.zig`);
- zooms made from clicks, and the trim of the reach for the stop button
  (`src/recording.zig`);
- the style's settings and their names, and the compositor's layout
  (`src/style.zig`, `src/canvas.zig`);
- the recording format (`recording.json` beside `screen.mp4`), so recordings
  open in either app.

## nanoui

[nanoui](https://github.com/justrach/nanoui) is MIT licensed. Its own
third-party notices (mygo, GPUI, gpui-motion, GPUI Kit) are in its repository.
