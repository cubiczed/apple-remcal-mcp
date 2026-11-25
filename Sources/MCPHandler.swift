import Foundation

final class MCPHandler {
    private let store: EventKitStore

    init(store: EventKitStore) {
        self.store = store
    }

    func handleRPC(body: Data) -> (status: Int, data: Data?) {
        guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            return (400, jsonData(rpcError(id: NSNull(), code: -32700, message: "Parse error")))
        }

        let id = json["id"]
        guard let method = json["method"] as? String else {
            return (400, jsonData(rpcError(id: id ?? NSNull(), code: -32600, message: "Invalid Request")))
        }

        // Notifications have no "id" -> 202 Accepted with empty body per MCP Streamable HTTP spec.
        if id == nil {
            return (202, nil)
        }

        let rpcId = id!
        let params = json["params"] as? [String: Any] ?? [:]

        switch method {
        case "initialize":
            let requestedVersion = (params["protocolVersion"] as? String) ?? "2025-03-26"
            let result: [String: Any] = [
                "protocolVersion": requestedVersion,
                "capabilities": [
                    "tools": [
                        "listChanged": false
                    ]
                ],
                "serverInfo": [
                    "name": "apple-remcal-mcp",
                    "version": "1.0.0"
                ]
            ]
            return (200, jsonData(rpcResult(id: rpcId, result: result)))

        case "ping":
            return (200, jsonData(rpcResult(id: rpcId, result: [:])))

        case "tools/list":
            return (200, jsonData(rpcResult(id: rpcId, result: ["tools": toolDefinitions()])))

        case "tools/call":
            guard let toolName = params["name"] as? String else {
                return (200, jsonData(rpcError(id: rpcId, code: -32602, message: "Missing tool name")))
            }
            let args = params["arguments"] as? [String: Any] ?? [:]
            let result = executeTool(name: toolName, args: args)
            return (200, jsonData(rpcResult(id: rpcId, result: result)))

        default:
            return (200, jsonData(rpcError(id: rpcId, code: -32601, message: "Method not found: \(method)")))
        }
    }

    private func executeTool(name: String, args: [String: Any]) -> [String: Any] {
        do {
            let payload: Any
            switch name {
            case "check_permissions":
                payload = store.checkPermissions()
            case "list_calendars":
                payload = try store.listCalendars()
            case "list_events":
                guard let from = args["from"] as? String, let to = args["to"] as? String else {
                    throw StoreError.invalidArgument("'from' and 'to' are required.")
                }
                let calendars = args["calendars"] as? [String]
                payload = try store.listEvents(from: from, to: to, calendarNames: calendars)
            case "create_event":
                payload = try store.createEvent(args: args)
            case "update_event":
                payload = try store.updateEvent(args: args)
            case "delete_event":
                payload = try store.deleteEvent(args: args)
            case "list_reminder_lists":
                payload = try store.listReminderLists()
            case "list_reminders":
                let filter = args["filter"] as? String
                let list = args["list"] as? String
                payload = try store.listReminders(filter: filter, listName: list)
            case "create_reminder":
                payload = try store.createReminder(args: args)
            case "update_reminder":
                payload = try store.updateReminder(args: args)
            case "complete_reminder":
                payload = try store.completeReminder(args: args)
            case "delete_reminder":
                payload = try store.deleteReminder(args: args)
            default:
                throw StoreError.invalidArgument("Unknown tool: \(name)")
            }

            let prettyData = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
            let text = String(data: prettyData, encoding: .utf8) ?? "{}"
            return [
                "content": [["type": "text", "text": text]],
                "isError": false
            ]
        } catch {
            return [
                "content": [["type": "text", "text": "Error: \(error.localizedDescription)"]],
                "isError": true
            ]
        }
    }

    private func rpcResult(id: Any, result: Any) -> [String: Any] {
        return ["jsonrpc": "2.0", "id": id, "result": result]
    }

    private func rpcError(id: Any, code: Int, message: String) -> [String: Any] {
        return ["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]]
    }

    private func jsonData(_ obj: Any) -> Data {
        return (try? JSONSerialization.data(withJSONObject: obj, options: [])) ?? Data("{}".utf8)
    }

    private func tool(_ name: String, _ desc: String, properties: [String: Any], required: [String] = []) -> [String: Any] {
        var schema: [String: Any] = [
            "type": "object",
            "properties": properties
        ]
        if !required.isEmpty {
            schema["required"] = required
        }
        return [
            "name": name,
            "description": desc,
            "inputSchema": schema
        ]
    }

    private func toolDefinitions() -> [[String: Any]] {
        return [
            tool("check_permissions", "Check macOS Calendar and Reminders authorization status.", properties: [:]),
            tool("list_calendars", "List all Apple Calendar calendars with IDs, titles, sources, and write permissions.", properties: [:]),
            tool("list_events", "List Apple Calendar events in a date range.", properties: [
                "from": ["type": "string", "description": "Start date (YYYY-MM-DD, YYYY-MM-DD HH:mm, or ISO-8601)."],
                "to": ["type": "string", "description": "End date (YYYY-MM-DD, YYYY-MM-DD HH:mm, or ISO-8601)."],
                "calendars": ["type": "array", "items": ["type": "string"], "description": "Optional list of calendar names to filter by (e.g. [\"School\", \"Home\"])."]
            ], required: ["from", "to"]),
            tool("create_event", "Create an Apple Calendar event. Use 'School' calendar for school tasks and 'Home' for personal tasks.", properties: [
                "title": ["type": "string", "description": "Event title."],
                "start": ["type": "string", "description": "Start date/time (YYYY-MM-DD for all-day, or YYYY-MM-DD HH:mm / ISO-8601)."],
                "end": ["type": "string", "description": "Optional end date/time."],
                "all_day": ["type": "boolean", "description": "Create as an all-day event (defaults to true if start is YYYY-MM-DD)."],
                "calendar": ["type": "string", "description": "Target calendar name (e.g. School or Home)."],
                "notes": ["type": "string", "description": "Optional event notes/description."],
                "location": ["type": "string", "description": "Optional location."],
                "url": ["type": "string", "description": "Optional URL."]
            ], required: ["title", "start"]),
            tool("update_event", "Update an existing Apple Calendar event by ID.", properties: [
                "id": ["type": "string", "description": "Event ID from list_events or create_event."],
                "title": ["type": "string", "description": "New title."],
                "start": ["type": "string", "description": "New start date/time."],
                "end": ["type": "string", "description": "New end date/time."],
                "all_day": ["type": "boolean", "description": "Set all-day flag."],
                "calendar": ["type": "string", "description": "Move to another calendar by name."],
                "notes": ["type": "string", "description": "New notes."],
                "location": ["type": "string", "description": "New location."],
                "span": ["type": "string", "enum": ["this", "future"], "description": "For recurring events: this or future."]
            ], required: ["id"]),
            tool("delete_event", "Delete an Apple Calendar event by ID.", properties: [
                "id": ["type": "string", "description": "Event ID to delete."],
                "span": ["type": "string", "enum": ["this", "future"], "description": "For recurring events: this or future."]
            ], required: ["id"]),
            tool("list_reminder_lists", "List all Apple Reminders lists.", properties: [:]),
            tool("list_reminders", "List Apple Reminders filtered by status/timeframe and optional list name.", properties: [
                "filter": ["type": "string", "enum": ["open", "today", "upcoming", "overdue", "completed", "all"], "description": "Filter mode (default: open)."],
                "list": ["type": "string", "description": "Optional reminder list name."]
            ]),
            tool("create_reminder", "Create a new Apple Reminder.", properties: [
                "title": ["type": "string", "description": "Reminder title."],
                "list": ["type": "string", "description": "Optional target reminder list name."],
                "due": ["type": "string", "description": "Optional due date (YYYY-MM-DD, YYYY-MM-DD HH:mm, or ISO-8601)."],
                "notes": ["type": "string", "description": "Optional notes."],
                "priority": ["type": "string", "enum": ["none", "low", "medium", "high"], "description": "Optional priority."]
            ], required: ["title"]),
            tool("update_reminder", "Update an existing Apple Reminder by ID.", properties: [
                "id": ["type": "string", "description": "Reminder ID."],
                "title": ["type": "string", "description": "New title."],
                "list": ["type": "string", "description": "Move to another reminder list."],
                "due": ["type": "string", "description": "New due date."],
                "clear_due": ["type": "boolean", "description": "Clear due date if true."],
                "notes": ["type": "string", "description": "New notes."],
                "priority": ["type": "string", "enum": ["none", "low", "medium", "high"], "description": "New priority."],
                "completed": ["type": "boolean", "description": "Set completion state."]
            ], required: ["id"]),
            tool("complete_reminder", "Mark an Apple Reminder as completed by ID.", properties: [
                "id": ["type": "string", "description": "Reminder ID to complete."]
            ], required: ["id"]),
            tool("delete_reminder", "Delete an Apple Reminder by ID.", properties: [
                "id": ["type": "string", "description": "Reminder ID to delete."]
            ], required: ["id"])
        ]
    }
}
