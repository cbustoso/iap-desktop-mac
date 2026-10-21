import Foundation

/// (i) CLI del spike. Parser propio para no añadir dependencias.
public struct SpikeOptions: Sendable, Equatable {
    public enum Mode: String, Sendable, Equatable {
        case ssh
        case rdp
    }

    public enum Command: Sendable, Equatable {
        case help
        case listAccounts
        case tunnel
    }

    public var command: Command = .tunnel
    public var subscription = ""
    public var resourceGroup = ""
    public var bastion = ""
    /// Nombre de la VM o su resource ID completo (`/subscriptions/...`).
    public var vm = ""
    public var vmResourceGroup: String?
    public var tenant: String?
    public var port: Int?
    public var mode: Mode = .ssh
    public var listenPort = 0
    public var user: String?
    public var verbose = false
    /// A0.4: tras el DELETE de cierre, repite el DELETE para registrar el 404.
    public var doubleDelete = false

    public var targetPort: Int { port ?? (mode == .rdp ? 3389 : 22) }

    public var vmResourceID: String {
        if vm.hasPrefix("/subscriptions/") { return vm }
        return ResourceID.virtualMachine(subscription: subscription, resourceGroup: vmResourceGroup ?? resourceGroup, name: vm)
    }

    public var bastionResourceID: String {
        ResourceID.bastionHost(subscription: subscription, resourceGroup: resourceGroup, name: bastion)
    }

    public static let usage = """
    Uso:
      bastion-spike --subscription <id> --resource-group <rg> --bastion <nombre> --vm <nombre|resourceId>
                    [--vm-resource-group <rg>] [--tenant <id>] [--port 22|3389]
                    [--mode ssh|rdp] [--listen-port <n>] [--user <usuario>] [--double-delete] [--verbose]
      bastion-spike --list-accounts
      bastion-spike --help

    Auth: solo la sesión de Azure CLI (`az login`). Sin client ID ni secretos.
    --resource-group es el del Bastion; la VM usa el mismo salvo --vm-resource-group.
    --port por defecto: 22 en modo ssh, 3389 en modo rdp. --listen-port 0 = puerto efímero.
    """

    public struct ParseError: Error, Equatable, CustomStringConvertible {
        public let message: String
        public var description: String { message }
    }

    public static func parse(_ arguments: [String]) throws -> SpikeOptions {
        var options = SpikeOptions()
        var iterator = arguments.makeIterator()

        func value(for flag: String) throws -> String {
            guard let next = iterator.next(), !next.hasPrefix("--") else {
                throw ParseError(message: "Falta el valor de \(flag).")
            }
            return next
        }

        func integer(for flag: String, in range: ClosedRange<Int>) throws -> Int {
            let raw = try value(for: flag)
            guard let number = Int(raw), range.contains(number) else {
                throw ParseError(message: "\(flag) debe ser un entero en \(range.lowerBound)...\(range.upperBound).")
            }
            return number
        }

        while let argument = iterator.next() {
            switch argument {
            case "-h", "--help": options.command = .help
            case "--list-accounts": options.command = .listAccounts
            case "--subscription": options.subscription = try value(for: argument)
            case "--resource-group": options.resourceGroup = try value(for: argument)
            case "--bastion": options.bastion = try value(for: argument)
            case "--vm": options.vm = try value(for: argument)
            case "--vm-resource-group": options.vmResourceGroup = try value(for: argument)
            case "--tenant": options.tenant = try value(for: argument)
            case "--port": options.port = try integer(for: argument, in: 1...65_535)
            case "--listen-port": options.listenPort = try integer(for: argument, in: 0...65_535)
            case "--user": options.user = try value(for: argument)
            case "--verbose", "-v": options.verbose = true
            case "--double-delete": options.doubleDelete = true
            case "--mode":
                let raw = try value(for: argument)
                guard let mode = Mode(rawValue: raw) else { throw ParseError(message: "--mode debe ser ssh o rdp.") }
                options.mode = mode
            default:
                throw ParseError(message: "Argumento desconocido: \(argument)")
            }
        }

        if options.command == .tunnel {
            let missing = [
                ("--subscription", options.subscription), ("--resource-group", options.resourceGroup),
                ("--bastion", options.bastion), ("--vm", options.vm),
            ].filter { $0.1.isEmpty }.map(\.0)
            guard missing.isEmpty else {
                throw ParseError(message: "Faltan: \(missing.joined(separator: ", ")).")
            }
        }
        return options
    }
}
