# HueLens

KOReader plugin that temporarily re-renders the current PDF page in color and maps
colors to distinguishable grays, or isolates one color at a time. Useful for reading
charts on grayscale e-ink screens.

The normal page rendering is never modified: the color render is momentary and shown
in an image viewer.

## Modes

- **All**: every hue band present on the page (red, orange, yellow, green, cyan, blue,
  purple, magenta) gets its own gray level, spread over the full range with
  neighbouring hues getting distant grays, plus a fill pattern (solid, hatch, dots,
  crosshatch...). A legend above the selector shows which pattern is which color.
- **Single color**: one hue band is shown in black, other colors in light gray and
  neutral content (text, axes) faded. Only bands present on the page are offered,
  sorted by area.

Switch modes with the selector at the bottom of the viewer. The viewer shows the part of
the page currently on screen, keeping the reader's zoom, rendered at 1.5x for extra
detail; pinch/pan to zoom further. Reflowed pages fall back to the whole page.

## Installation

1. Download `huelens.koplugin-<version>.zip` from the
   [releases page](https://github.com/jaeusamio/huelens.koplugin/releases).
2. Extract it into KOReader's `plugins/` directory, so you end up with
   `plugins/huelens.koplugin/main.lua`.
3. Restart KOReader.

## Usage

With a paged document (PDF, CBZ, ...) open, use any of:

- Bottom panel, contrast tab: **Color separation -> show**
- Main menu, Tools: **Color separation of current page**
- Gestures / profiles: action **Color separation of current page**

Requires a document backend that supports color rendering (MuPDF).

Any image viewer showing a color image (for example a figure opened by another
plugin) also gets a **Colors** button that opens it in the same viewer.

## Releasing

Push a `v*` tag pointing to a commit on `main`:

```sh
git tag v1.0.0
git push origin v1.0.0
```

The `Release` workflow packages `_meta.lua` and `main.lua` into
`huelens.koplugin-<tag>.zip` and creates a GitHub release whose notes list the commits
since the previous tag.
