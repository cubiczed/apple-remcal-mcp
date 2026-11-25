import Foundation

signal(SIGPIPE, SIG_IGN)

var port: UInt16 = 8787
var authorizeOnly = false

let args = CommandLine.arguments
var idx = 1
while idx < args.count {
    switch args[idx] {
    case "--port":
        if idx + 1 < args.count, let p = UInt16(args[idx + 1]) {
            port = p
            idx += 1
        }
    case "--authorize":
        authorizeOnly = true
    default:
        break
    }
    idx += 1
}

let store = EventKitStore()

if authorizeOnly {
    store.requestAccessIfNeeded()
    let perms = store.checkPermissions()
    if let data = try? JSONSerialization.data(withJSONObject: perms, options: [.prettyPrinted]),
       let str = String(data: data, encoding: .utf8) {
        print(str)
    }
    exit(0)
}

let handler = MCPHandler(store: store)
let server = HTTPServer(port: port, handler: handler, store: store)

do {
    try server.start()
    fputs("apple-remcal-mcp listening on http://127.0.0.1:\(port)/mcp\n", stderr)
    fflush(stderr)
    DispatchQueue.global(qos: .userInitiated).async {
        store.requestAccessIfNeeded()
    }
    RunLoop.main.run()
} catch {
    fputs("Fatal: \(error.localizedDescription)\n", stderr)
    exit(1)
}
