# Vendored player libraries

Loaded lazily by `lib/platform/video_web.dart`, only on the watch page and
only when the browser can't play the stream natively. Served from the app's
own origin, so playback never depends on a third-party CDN.

| Library | Version | Source | License |
|---|---|---|---|
| hls.js | 1.5.20 | `npm pack hls.js@1.5.20`, `dist/hls.min.js` | Apache-2.0 (`hls.js-1.5.20/LICENSE`) |
| dash.js | 4.7.4 | `npm pack dashjs@4.7.4`, `dist/dash.all.min.js` | BSD-3-Clause (`dashjs-4.7.4/LICENSE.md`) |

HLS (`hls_url`) is the default. dash.js only plays videos transcoded before
the pipeline wrote HLS, whose `hls_url` is null.

To upgrade: `npm pack <name>@<version>`, copy the same files into a new
versioned folder, update the paths in `video_web.dart`, and delete the old
folder.
