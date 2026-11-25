# apple-remcal-mcp

Lightweight native Swift EventKit MCP server (Streamable HTTP on `http://127.0.0.1:8787/mcp`) for Apple Calendar and Apple Reminders.

## Build & Start

```zsh
./build.sh
./install-agent.sh
```

On first launch, macOS will prompt for **Calendars** and **Reminders** Full Access for `AppleRemCalMCP` (or grant them in **System Settings > Privacy & Security > Calendars / Reminders**).

## Health & Smoke Test

```zsh
curl -s http://127.0.0.1:8787/health
curl -s -X POST http://127.0.0.1:8787/mcp \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}'
```

## Connect in Antigravity (`~/.gemini/config/mcp_config.json`)

```json
{
  "mcpServers": {
    "apple-remcal": {
      "url": "http://127.0.0.1:8787/mcp"
    }
  }
}
```
