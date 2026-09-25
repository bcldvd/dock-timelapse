# Dock Timelapse

Record how your macOS Dock evolves and render Apple-style timelapse videos of it.

![Landscape timelapse](https://raw.githubusercontent.com/bcldvd/dock-timelapse/main/docs/landscape.gif)

Your Dock tells the story of the tools you live in. Dock Timelapse records it every day and turns its
evolution into a timelapse: apps springing in, others handing over their spot, a day counter ticking,
all drawn over your own wallpaper. Landscape 1920×1080 and portrait 1080×1920, H.264 at 60 fps.

## What the plugin adds

- **Skill** `dock-timelapse`: Claude knows how to start recording, preview, render and answer questions
  about your Dock history.
- **MCP server** `dock-timelapse`: tools `dock_status`, `current_dock`, `dock_history`,
  `install_recording`, `uninstall_recording`, `capture_now`, `render_timelapse`, `render_preview`,
  `render_frame`.

## Try it

Ask Claude:

- *"Start recording my Dock"*
- *"Show me a preview of my Dock timelapse"*
- *"Make a timelapse of my Dock"*
- *"Which apps did I add since June?"*

`preview` invents a plausible past that ends with your real Dock, so you can see a video on day one.

## Requirements

macOS and [uv](https://docs.astral.sh/uv/). ffmpeg comes bundled. The MCP server starts from
`scripts/mcp-server.sh`, which runs `dock-timelapse` 0.2.0 from PyPI in an environment pinned by
`uv.lock` (`uv run --locked`).

## Privacy

Everything stays on your Mac. Recording reads the Dock's own preferences once an hour and saves the app
list, icons and wallpaper to `~/Library/Application Support/dock-timelapse/`. Videos are rendered
locally to `~/Movies/Dock Timelapse/`. Nothing is uploaded.

## Links

- Source and full docs: https://github.com/bcldvd/dock-timelapse
- Website: https://bcldvd.github.io/dock-timelapse/
- License: MIT
