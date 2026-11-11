import CodexWatchBridgeCore
import Darwin
import Foundation

struct BridgeArguments {
    var host = "127.0.0.1"
    var port: UInt16 = 8765
    var codexHome = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".codex")
    var bridgeHome = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".codex-watch-pet")
    var requireSignatures = true
    var allowNetworkPairing = false
    var printPairing = false
    var enableAppServerControl = true
    var appServerSocketPath = NSHomeDirectory() + "/.codex/app-server-control/app-server-control.sock"

    init(arguments: [String]) {
        var iterator = arguments.dropFirst().makeIterator()
        while let argument = iterator.next() {
            switch argument {
            case "--host":
                if let value = iterator.next() { host = value }
            case "--port":
                if let value = iterator.next(), let parsed = UInt16(value) { port = parsed }
            case "--codex-home":
                if let value = iterator.next() { codexHome = URL(fileURLWithPath: value) }
            case "--bridge-home":
                if let value = iterator.next() { bridgeHome = URL(fileURLWithPath: value) }
            case "--allow-unsigned-local":
                requireSignatures = false
            case "--allow-network-pairing":
                allowNetworkPairing = true
            case "--print-pairing":
                printPairing = true
            case "--disable-app-server-control":
                enableAppServerControl = false
            case "--app-server-socket":
                if let value = iterator.next() { appServerSocketPath = value }
            case "--help", "-h":
                Self.printHelpAndExit()
            default:
                break
            }
        }
    }

    static func printHelpAndExit() -> Never {
        print("""
        CodexWatchBridge

        Options:
          --host <host>              Host to listen on. Default: 127.0.0.1
          --port <port>              Port to listen on. Default: 8765
          --codex-home <path>        Codex home. Default: ~/.codex
          --bridge-home <path>       Bridge state dir. Default: ~/.codex-watch-pet
          --allow-unsigned-local     Disable HMAC command signatures for local testing.
          --allow-network-pairing    Allow /pairing from non-local clients. Default: false.
          --print-pairing            Print full pairing token and secret even when stdout is not a TTY.
          --disable-app-server-control
                                      Do not connect to Codex app-server for live approval routing.
          --app-server-socket <path>  Override Codex app-server control socket for testing.
        """)
        exit(0)
    }
}

let arguments = BridgeArguments(arguments: CommandLine.arguments)
let runtime = BridgeRuntime(
    codexHome: arguments.codexHome,
    bridgeHome: arguments.bridgeHome,
    requireSignatures: arguments.requireSignatures,
    appServerApprovalRouter: arguments.enableAppServerControl
        ? CodexAppServerApprovalRouter(socketPath: arguments.appServerSocketPath, bridgeHome: arguments.bridgeHome)
        : nil
)
let pairing = try runtime.ensurePairing()
let server = BridgeHTTPServer(
    configuration: HTTPServerConfiguration(
        host: arguments.host,
        port: arguments.port,
        allowNetworkPairing: arguments.allowNetworkPairing
    ),
    runtime: runtime
)
try server.start()

print("CodexWatchBridge listening on http://\(arguments.host):\(arguments.port)")
if arguments.printPairing || isatty(STDOUT_FILENO) != 0 {
    print("Pairing token: \(pairing.token)")
    print("Shared secret: \(pairing.sharedSecret)")
} else {
    print("Pairing token: \(String(pairing.token.prefix(8)))...")
    print("Shared secret: stored in \(arguments.bridgeHome.appendingPathComponent("pairing.json").path)")
}
if arguments.allowNetworkPairing {
    print("Warning: /pairing is reachable from non-local clients.")
}
print("Bridge state: \(arguments.bridgeHome.path)")
server.runForever()
