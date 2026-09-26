#!/bin/sh
# Starts the dock-timelapse MCP server.
# Prefers the engine inside Dock Timelapse.app (native, no Python needed); otherwise runs the Python
# package from the environment pinned in uv.lock.
for app in "/Applications/Dock Timelapse.app" "$HOME/Applications/Dock Timelapse.app"; do
  if [ -x "$app/Contents/MacOS/dock-timelapse" ]; then
    exec "$app/Contents/MacOS/dock-timelapse" mcp
  fi
done
# Apps launched from the Dock have a short PATH, so also look where uv installs itself.
PATH="$PATH:$HOME/.local/bin:$HOME/.cargo/bin:/opt/homebrew/bin:/usr/local/bin"
export PATH
exec uv run --locked --no-dev --project "${CLAUDE_PLUGIN_ROOT}" dock-timelapse mcp
