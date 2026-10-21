import Foundation

/// (g) Modo `rdp`: `.rdp` temporal apuntando al listener y apertura con
/// Windows App (o el antiguo Microsoft Remote Desktop) si está instalado.
public enum RDPLauncher {
    public static let candidateApps = [
        "/Applications/Windows App.app",
        "\(NSHomeDirectory())/Applications/Windows App.app",
        "/Applications/Microsoft Remote Desktop.app",
    ]

    public static func fileContents(port: Int, username: String?) -> String {
        var lines = [
            "full address:s:127.0.0.1:\(port)",
            "prompt for credentials:i:1",
            "authentication level:i:2",
            "screen mode id:i:2",
        ]
        if let username { lines.append("username:s:\(username)") }
        return lines.joined(separator: "\r\n") + "\r\n"
    }

    /// Escribe el `.rdp` en un directorio temporal privado (0600).
    public static func writeTemporaryFile(port: Int, username: String?) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("bastion-spike-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let file = directory.appendingPathComponent("bastion-127.0.0.1-\(port).rdp")
        try Data(fileContents(port: port, username: username).utf8).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        return file
    }

    public static func installedApp() -> URL? {
        candidateApps.first { FileManager.default.fileExists(atPath: $0) }.map { URL(fileURLWithPath: $0) }
    }

    /// `open -a <app> <file>`. Devuelve `false` si no hay cliente RDP instalado.
    @discardableResult
    public static func open(_ file: URL) throws -> Bool {
        guard let app = installedApp() else { return false }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-a", app.path, file.path]
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus == 0
    }
}
