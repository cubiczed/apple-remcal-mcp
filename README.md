# apple-remcal-mcp

Lightweight, zero-dependency native Swift EventKit MCP server for **Apple Calendar** and **Apple Reminders** on macOS. Runs locally as a background macOS app bundle and exposes 12 tools over MCP Streamable HTTP (`http://127.0.0.1:8787/mcp`).

## Requirements

- macOS with Apple Calendar and/or Apple Reminders
- Xcode Command Line Tools (`swiftc`)

## Build & Run

```zsh
./build.sh
./install-agent.sh
```

- `./build.sh` compiles the Swift source into `build/AppleRemCalMCP.app` and ad-hoc signs it.
- `./install-agent.sh` registers and starts a `launchd` LaunchAgent so the server runs automatically on login (listening on `127.0.0.1:8787`, logs at `/tmp/apple-remcal-mcp.log`).
- `./uninstall-agent.sh` stops and removes the LaunchAgent.

On first launch, macOS will prompt for **Calendars** and **Reminders** Full Access for `AppleRemCalMCP` (or grant access in **System Settings > Privacy & Security > Calendars / Reminders**).

## Connecting an MCP Client

This server implements stateless JSON-RPC 2.0 over **MCP Streamable HTTP** (`POST /mcp`) and binds strictly to loopback (`127.0.0.1:8787`), so it works with any local MCP-compatible AI client on macOS.

### Streamable HTTP Clients

Add the server URL to your client's MCP configuration file (Cursor, VS Code, Windsurf, Antigravity, Gemini CLI, etc.):

```json
{
  "mcpServers": {
    "apple-remcal": {
      "url": "http://127.0.0.1:8787/mcp"
    }
  }
}
```

For **Claude Code**:

```zsh
claude mcp add --transport http apple-remcal http://127.0.0.1:8787/mcp
```

### Stdio-Only Clients

For clients that only support `stdio` MCP servers (such as Claude Desktop's local config), connect through `mcp-remote`:

```json
{
  "mcpServers": {
    "apple-remcal": {
      "command": "npx",
      "args": ["-y", "mcp-remote", "http://127.0.0.1:8787/mcp"]
    }
  }
}
```

## Health & Smoke Test

```zsh
curl -s http://127.0.0.1:8787/health
curl -s -X POST http://127.0.0.1:8787/mcp \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}'
```

## Tools (12)

### Permissions

| Tool | Description | Parameters |
| --- | --- | --- |
| `check_permissions` | Check macOS Calendar and Reminders authorization status. | None |

### Apple Calendar

| Tool | Description | Parameters |
| --- | --- | --- |
| `list_calendars` | List all calendars with IDs, titles, sources, and write permissions. | None |
| `list_events` | List calendar events in a date range. | **`from`**, **`to`** (YYYY-MM-DD, YYYY-MM-DD HH:mm, or ISO-8601), `calendars` (optional array of calendar names) |
| `create_event` | Create a new calendar event. | **`title`**, **`start`**, `end`, `all_day`, `calendar`, `notes`, `location`, `url` |
| `update_event` | Update an existing calendar event by ID. | **`id`**, `title`, `start`, `end`, `all_day`, `calendar`, `notes`, `location`, `span` (`this` \| `future`) |
| `delete_event` | Delete a calendar event by ID. | **`id`**, `span` (`this` \| `future`) |

### Apple Reminders

| Tool | Description | Parameters |
| --- | --- | --- |
| `list_reminder_lists` | List all reminder lists. | None |
| `list_reminders` | List reminders filtered by status/timeframe and optional list name. | `filter` (`open` \| `today` \| `upcoming` \| `overdue` \| `completed` \| `all`, default `open`), `list` |
| `create_reminder` | Create a new reminder. | **`title`**, `list`, `due`, `notes`, `priority` (`none` \| `low` \| `medium` \| `high`) |
| `update_reminder` | Update an existing reminder by ID. | **`id`**, `title`, `list`, `due`, `clear_due`, `notes`, `priority`, `completed` |
| `complete_reminder` | Mark a reminder as completed by ID. | **`id`** |
| `delete_reminder` | Delete a reminder by ID. | **`id`** |

*Bold parameters are required.*
