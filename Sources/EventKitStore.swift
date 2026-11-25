import Foundation
import EventKit

enum StoreError: LocalizedError {
    case permissionDenied(String)
    case invalidArgument(String)
    case notFound(String)
    case operationFailed(String)

    var errorDescription: String? {
        switch self {
        case .permissionDenied(let msg): return msg
        case .invalidArgument(let msg): return msg
        case .notFound(let msg): return msg
        case .operationFailed(let msg): return msg
        }
    }
}

final class EventKitStore {
    private let store = EKEventStore()
    private let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = TimeZone.current
        return f
    }()
    private let isoFracFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        f.timeZone = TimeZone.current
        return f
    }()
    private let dateOnlyFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        return f
    }()
    private let dateTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        return f
    }()

    // MARK: - Permissions

    func statusString(_ status: EKAuthorizationStatus) -> String {
        switch status {
        case .notDetermined: return "not_determined"
        case .restricted: return "restricted"
        case .denied: return "denied"
        case .fullAccess: return "full_access"
        case .writeOnly: return "write_only"
        @unknown default: return "unknown"
        }
    }

    func checkPermissions() -> [String: Any] {
        let calStatus = EKEventStore.authorizationStatus(for: .event)
        let remStatus = EKEventStore.authorizationStatus(for: .reminder)
        return [
            "calendar": statusString(calStatus),
            "reminders": statusString(remStatus)
        ]
    }

    func requestAccessIfNeeded() {
        let calStatus = EKEventStore.authorizationStatus(for: .event)
        if calStatus == .notDetermined {
            let sem = DispatchSemaphore(value: 0)
            store.requestFullAccessToEvents { _, _ in sem.signal() }
            _ = sem.wait(timeout: .now() + 60)
        }
        let remStatus = EKEventStore.authorizationStatus(for: .reminder)
        if remStatus == .notDetermined {
            let sem = DispatchSemaphore(value: 0)
            store.requestFullAccessToReminders { _, _ in sem.signal() }
            _ = sem.wait(timeout: .now() + 60)
        }
    }

    private func ensureCalendarAccess() throws {
        let status = EKEventStore.authorizationStatus(for: .event)
        if status == .notDetermined {
            let sem = DispatchSemaphore(value: 0)
            var grantedResult = false
            store.requestFullAccessToEvents { granted, _ in
                grantedResult = granted
                sem.signal()
            }
            _ = sem.wait(timeout: .now() + 60)
            if !grantedResult {
                throw StoreError.permissionDenied("Calendar access denied. Grant Full Access to AppleRemCalMCP in System Settings > Privacy & Security > Calendars.")
            }
            return
        }
        guard status == .fullAccess else {
            throw StoreError.permissionDenied("Calendar access is \(statusString(status)). Grant Full Access to AppleRemCalMCP in System Settings > Privacy & Security > Calendars.")
        }
    }

    private func ensureRemindersAccess() throws {
        let status = EKEventStore.authorizationStatus(for: .reminder)
        if status == .notDetermined {
            let sem = DispatchSemaphore(value: 0)
            var grantedResult = false
            store.requestFullAccessToReminders { granted, _ in
                grantedResult = granted
                sem.signal()
            }
            _ = sem.wait(timeout: .now() + 60)
            if !grantedResult {
                throw StoreError.permissionDenied("Reminders access denied. Grant Full Access to AppleRemCalMCP in System Settings > Privacy & Security > Reminders.")
            }
            return
        }
        guard status == .fullAccess else {
            throw StoreError.permissionDenied("Reminders access is \(statusString(status)). Grant Full Access to AppleRemCalMCP in System Settings > Privacy & Security > Reminders.")
        }
    }

    // MARK: - Date Helpers

    private func parseDate(_ raw: String, endOfDayIfDateOnly: Bool = false) throws -> (date: Date, isDateOnly: Bool) {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let d = isoFracFormatter.date(from: s) {
            return (d, false)
        }
        if let d = isoFormatter.date(from: s) {
            return (d, false)
        }
        if let d = dateTimeFormatter.date(from: s) {
            return (d, false)
        }
        if let d = dateOnlyFormatter.date(from: s) {
            if endOfDayIfDateOnly {
                let cal = Calendar.current
                if let nextDay = cal.date(byAdding: .day, value: 1, to: d),
                   let end = cal.date(byAdding: .second, value: -1, to: nextDay) {
                    return (end, true)
                }
            }
            return (d, true)
        }
        throw StoreError.invalidArgument("Invalid date '\(raw)'. Use YYYY-MM-DD, YYYY-MM-DD HH:mm, or ISO-8601.")
    }

    private func formatDate(_ date: Date, dateOnly: Bool = false) -> String {
        return dateOnly ? dateOnlyFormatter.string(from: date) : isoFormatter.string(from: date)
    }

    private func calendarTypeString(_ type: EKCalendarType) -> String {
        switch type {
        case .local: return "local"
        case .calDAV: return "caldav"
        case .exchange: return "exchange"
        case .subscription: return "subscription"
        case .birthday: return "birthday"
        @unknown default: return "other"
        }
    }

    private func findCalendar(named name: String, entityType: EKEntityType) -> EKCalendar? {
        let calendars = store.calendars(for: entityType)
        if let exact = calendars.first(where: { $0.title == name }) {
            return exact
        }
        return calendars.first(where: { $0.title.caseInsensitiveCompare(name) == .orderedSame })
    }

    // MARK: - Calendars & Events

    func listCalendars() throws -> [[String: Any]] {
        try ensureCalendarAccess()
        return store.calendars(for: .event)
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
            .map { cal in
                [
                    "id": cal.calendarIdentifier,
                    "title": cal.title,
                    "source": cal.source?.title ?? "",
                    "type": calendarTypeString(cal.type),
                    "writable": cal.allowsContentModifications
                ]
            }
    }

    private func serializeEvent(_ event: EKEvent) -> [String: Any] {
        var dict: [String: Any] = [
            "id": event.eventIdentifier ?? "",
            "title": event.title ?? "",
            "calendar": event.calendar?.title ?? "",
            "all_day": event.isAllDay,
            "start": formatDate(event.startDate, dateOnly: event.isAllDay),
            "end": formatDate(event.endDate, dateOnly: event.isAllDay)
        ]
        if let loc = event.location, !loc.isEmpty { dict["location"] = loc }
        if let notes = event.notes, !notes.isEmpty { dict["notes"] = notes }
        if let url = event.url?.absoluteString, !url.isEmpty { dict["url"] = url }
        return dict
    }

    func listEvents(from: String, to: String, calendarNames: [String]?) throws -> [[String: Any]] {
        try ensureCalendarAccess()
        let start = try parseDate(from, endOfDayIfDateOnly: false).date
        let end = try parseDate(to, endOfDayIfDateOnly: true).date
        guard end >= start else {
            throw StoreError.invalidArgument("'to' date must be on or after 'from' date.")
        }

        var calendars: [EKCalendar]? = nil
        if let names = calendarNames, !names.isEmpty {
            let matched = names.compactMap { findCalendar(named: $0, entityType: .event) }
            if matched.isEmpty {
                throw StoreError.notFound("None of the specified calendars were found: \(names.joined(separator: ", "))")
            }
            calendars = matched
        }

        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: calendars)
        let events = store.events(matching: predicate).sorted { $0.startDate < $1.startDate }
        return events.map { serializeEvent($0) }
    }

    func createEvent(args: [String: Any]) throws -> [String: Any] {
        try ensureCalendarAccess()
        guard let title = args["title"] as? String, !title.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw StoreError.invalidArgument("'title' is required.")
        }
        guard let startRaw = args["start"] as? String else {
            throw StoreError.invalidArgument("'start' is required.")
        }

        let parsedStart = try parseDate(startRaw, endOfDayIfDateOnly: false)
        let isAllDay = (args["all_day"] as? Bool) ?? parsedStart.isDateOnly

        let startDate = parsedStart.date
        let endDate: Date
        if let endRaw = args["end"] as? String, !endRaw.isEmpty {
            endDate = try parseDate(endRaw, endOfDayIfDateOnly: isAllDay).date
        } else if isAllDay {
            endDate = try parseDate(startRaw, endOfDayIfDateOnly: true).date
        } else {
            endDate = startDate.addingTimeInterval(3600)
        }

        let event = EKEvent(eventStore: store)
        event.title = title
        event.startDate = startDate
        event.endDate = endDate
        event.isAllDay = isAllDay

        if let calName = args["calendar"] as? String, !calName.isEmpty {
            guard let cal = findCalendar(named: calName, entityType: .event) else {
                throw StoreError.notFound("Calendar '\(calName)' not found.")
            }
            event.calendar = cal
        } else {
            event.calendar = store.defaultCalendarForNewEvents
        }

        if let notes = args["notes"] as? String { event.notes = notes }
        if let location = args["location"] as? String { event.location = location }
        if let urlStr = args["url"] as? String, !urlStr.isEmpty {
            event.url = URL(string: urlStr)
        }

        do {
            try store.save(event, span: .thisEvent, commit: true)
        } catch {
            throw StoreError.operationFailed("Failed to save event: \(error.localizedDescription)")
        }
        return serializeEvent(event)
    }

    func updateEvent(args: [String: Any]) throws -> [String: Any] {
        try ensureCalendarAccess()
        guard let id = args["id"] as? String, !id.isEmpty else {
            throw StoreError.invalidArgument("'id' is required.")
        }
        guard let event = store.event(withIdentifier: id) else {
            throw StoreError.notFound("Event with id '\(id)' not found.")
        }

        if let title = args["title"] as? String { event.title = title }
        if let allDay = args["all_day"] as? Bool { event.isAllDay = allDay }
        if let startRaw = args["start"] as? String {
            let parsed = try parseDate(startRaw, endOfDayIfDateOnly: false)
            let duration = event.endDate.timeIntervalSince(event.startDate)
            event.startDate = parsed.date
            if args["end"] == nil {
                event.endDate = event.isAllDay
                    ? (try parseDate(startRaw, endOfDayIfDateOnly: true).date)
                    : parsed.date.addingTimeInterval(max(duration, 3600))
            }
        }
        if let endRaw = args["end"] as? String {
            event.endDate = try parseDate(endRaw, endOfDayIfDateOnly: event.isAllDay).date
        }
        if let calName = args["calendar"] as? String, !calName.isEmpty {
            guard let cal = findCalendar(named: calName, entityType: .event) else {
                throw StoreError.notFound("Calendar '\(calName)' not found.")
            }
            event.calendar = cal
        }
        if let notes = args["notes"] as? String { event.notes = notes }
        if let location = args["location"] as? String { event.location = location }

        let span: EKSpan = ((args["span"] as? String)?.lowercased() == "future") ? .futureEvents : .thisEvent
        do {
            try store.save(event, span: span, commit: true)
        } catch {
            throw StoreError.operationFailed("Failed to update event: \(error.localizedDescription)")
        }
        return serializeEvent(event)
    }

    func deleteEvent(args: [String: Any]) throws -> [String: Any] {
        try ensureCalendarAccess()
        guard let id = args["id"] as? String, !id.isEmpty else {
            throw StoreError.invalidArgument("'id' is required.")
        }
        guard let event = store.event(withIdentifier: id) else {
            throw StoreError.notFound("Event with id '\(id)' not found.")
        }
        let title = event.title ?? ""
        let span: EKSpan = ((args["span"] as? String)?.lowercased() == "future") ? .futureEvents : .thisEvent
        do {
            try store.remove(event, span: span, commit: true)
        } catch {
            throw StoreError.operationFailed("Failed to delete event: \(error.localizedDescription)")
        }
        return ["deleted": true, "id": id, "title": title]
    }

    // MARK: - Reminders

    func listReminderLists() throws -> [[String: Any]] {
        try ensureRemindersAccess()
        return store.calendars(for: .reminder)
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
            .map { cal in
                [
                    "id": cal.calendarIdentifier,
                    "title": cal.title,
                    "source": cal.source?.title ?? "",
                    "writable": cal.allowsContentModifications
                ]
            }
    }

    private func priorityToString(_ p: Int) -> String {
        switch p {
        case 1...4: return "high"
        case 5: return "medium"
        case 6...9: return "low"
        default: return "none"
        }
    }

    private func parsePriority(_ raw: Any?) -> Int? {
        if let i = raw as? Int { return i }
        if let s = (raw as? String)?.lowercased() {
            switch s {
            case "high": return 1
            case "medium": return 5
            case "low": return 9
            case "none": return 0
            default: return nil
            }
        }
        return nil
    }

    private func serializeReminder(_ rem: EKReminder) -> [String: Any] {
        var dict: [String: Any] = [
            "id": rem.calendarItemIdentifier,
            "title": rem.title ?? "",
            "list": rem.calendar?.title ?? "",
            "completed": rem.isCompleted,
            "priority": priorityToString(rem.priority)
        ]
        if let dueComps = rem.dueDateComponents, let dueDate = Calendar.current.date(from: dueComps) {
            let hasTime = dueComps.hour != nil
            dict["due"] = formatDate(dueDate, dateOnly: !hasTime)
        }
        if let notes = rem.notes, !notes.isEmpty { dict["notes"] = notes }
        return dict
    }

    private func fetchReminders(in calendars: [EKCalendar]?) -> [EKReminder] {
        let predicate = store.predicateForReminders(in: calendars)
        let sem = DispatchSemaphore(value: 0)
        var fetched: [EKReminder] = []
        store.fetchReminders(matching: predicate) { items in
            fetched = items ?? []
            sem.signal()
        }
        _ = sem.wait(timeout: .now() + 30)
        return fetched
    }

    func listReminders(filter: String?, listName: String?) throws -> [[String: Any]] {
        try ensureRemindersAccess()
        var calendars: [EKCalendar]? = nil
        if let name = listName, !name.isEmpty {
            guard let cal = findCalendar(named: name, entityType: .reminder) else {
                throw StoreError.notFound("Reminder list '\(name)' not found.")
            }
            calendars = [cal]
        }

        let all = fetchReminders(in: calendars)
        let mode = (filter ?? "open").lowercased()
        let cal = Calendar.current
        let now = Date()
        let startOfToday = cal.startOfDay(for: now)
        let startOfTomorrow = cal.date(byAdding: .day, value: 1, to: startOfToday)!

        let filtered = all.filter { rem in
            let dueDate: Date? = rem.dueDateComponents.flatMap { cal.date(from: $0) }
            switch mode {
            case "all":
                return true
            case "completed":
                return rem.isCompleted
            case "open":
                return !rem.isCompleted
            case "today":
                guard !rem.isCompleted, let d = dueDate else { return false }
                return d >= startOfToday && d < startOfTomorrow
            case "overdue":
                guard !rem.isCompleted, let d = dueDate else { return false }
                return d < startOfToday
            case "upcoming":
                guard !rem.isCompleted, let d = dueDate else { return false }
                return d >= startOfToday
            default:
                return !rem.isCompleted
            }
        }

        return filtered.map { serializeReminder($0) }
    }

    private func dueComponents(from raw: String) throws -> DateComponents {
        let parsed = try parseDate(raw, endOfDayIfDateOnly: false)
        let cal = Calendar.current
        if parsed.isDateOnly {
            return cal.dateComponents([.year, .month, .day], from: parsed.date)
        }
        return cal.dateComponents([.year, .month, .day, .hour, .minute], from: parsed.date)
    }

    func createReminder(args: [String: Any]) throws -> [String: Any] {
        try ensureRemindersAccess()
        guard let title = args["title"] as? String, !title.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw StoreError.invalidArgument("'title' is required.")
        }
        let rem = EKReminder(eventStore: store)
        rem.title = title

        if let listName = args["list"] as? String, !listName.isEmpty {
            guard let cal = findCalendar(named: listName, entityType: .reminder) else {
                throw StoreError.notFound("Reminder list '\(listName)' not found.")
            }
            rem.calendar = cal
        } else {
            rem.calendar = store.defaultCalendarForNewReminders()
        }

        if let dueRaw = args["due"] as? String, !dueRaw.isEmpty {
            rem.dueDateComponents = try dueComponents(from: dueRaw)
        }
        if let notes = args["notes"] as? String { rem.notes = notes }
        if let p = parsePriority(args["priority"]) { rem.priority = p }

        do {
            try store.save(rem, commit: true)
        } catch {
            throw StoreError.operationFailed("Failed to save reminder: \(error.localizedDescription)")
        }
        return serializeReminder(rem)
    }

    private func findReminder(id: String) throws -> EKReminder {
        if let item = store.calendarItem(withIdentifier: id) as? EKReminder {
            return item
        }
        throw StoreError.notFound("Reminder with id '\(id)' not found.")
    }

    func updateReminder(args: [String: Any]) throws -> [String: Any] {
        try ensureRemindersAccess()
        guard let id = args["id"] as? String, !id.isEmpty else {
            throw StoreError.invalidArgument("'id' is required.")
        }
        let rem = try findReminder(id: id)

        if let title = args["title"] as? String { rem.title = title }
        if let listName = args["list"] as? String, !listName.isEmpty {
            guard let cal = findCalendar(named: listName, entityType: .reminder) else {
                throw StoreError.notFound("Reminder list '\(listName)' not found.")
            }
            rem.calendar = cal
        }
        if (args["clear_due"] as? Bool) == true {
            rem.dueDateComponents = nil
        } else if let dueRaw = args["due"] as? String, !dueRaw.isEmpty {
            rem.dueDateComponents = try dueComponents(from: dueRaw)
        }
        if let notes = args["notes"] as? String { rem.notes = notes }
        if let p = parsePriority(args["priority"]) { rem.priority = p }
        if let completed = args["completed"] as? Bool {
            rem.isCompleted = completed
            rem.completionDate = completed ? Date() : nil
        }

        do {
            try store.save(rem, commit: true)
        } catch {
            throw StoreError.operationFailed("Failed to update reminder: \(error.localizedDescription)")
        }
        return serializeReminder(rem)
    }

    func completeReminder(args: [String: Any]) throws -> [String: Any] {
        var mutable = args
        mutable["completed"] = true
        return try updateReminder(args: mutable)
    }

    func deleteReminder(args: [String: Any]) throws -> [String: Any] {
        try ensureRemindersAccess()
        guard let id = args["id"] as? String, !id.isEmpty else {
            throw StoreError.invalidArgument("'id' is required.")
        }
        let rem = try findReminder(id: id)
        let title = rem.title ?? ""
        do {
            try store.remove(rem, commit: true)
        } catch {
            throw StoreError.operationFailed("Failed to delete reminder: \(error.localizedDescription)")
        }
        return ["deleted": true, "id": id, "title": title]
    }
}
