#!/bin/sh
# Starts the dock-timelapse MCP server from the environment pinned in uv.lock.
# Apps launched from the Dock have a short PATH, so also look where uv installs itself.
PATH="$PATH:$HOME/.local/bin:$HOME/.cargo/bin:/opt/homebrew/bin:/usr/local/bin"
export PATH
exec uv run --locked --no-dev --project "${CLAUDE_PLUGIN_ROOT}" dock-timelapse mcp
