import Foundation

/// Apps launched from Finder, Spotlight, or the Dock do not inherit the
/// interactive shell's `PATH`, so an AWS profile whose `credential_process`
/// names a helper by bare name works in Terminal but not here. This appends a
/// fixed list of standard tool directories to this process's own `PATH` so
/// those helpers resolve.
///
/// It never starts a shell and never reads AWS or shell configuration files.
/// Only directories that already exist are added, they go after the existing
/// entries so nothing already on `PATH` is overridden, and entries already
/// present are not repeated.
enum ToolPath {
    /// Directories relative to the user's home directory.
    private static let homeRelativeDirectories = [".toolbox/bin", ".local/bin"]
    private static let systemDirectories = ["/opt/homebrew/bin", "/usr/local/bin"]

    static func augmented(
        current: String?,
        home: String,
        directoryExists: (String) -> Bool
    ) -> String {
        var entries = (current ?? "").split(separator: ":").map(String.init)
        let candidates = homeRelativeDirectories.map { "\(home)/\($0)" } + systemDirectories

        for directory in candidates where !entries.contains(directory) && directoryExists(directory) {
            entries.append(directory)
        }

        return entries.joined(separator: ":")
    }

    /// Updates this process's `PATH` so child processes, such as a
    /// `credential_process` helper, inherit it.
    static func applyToProcessEnvironment() {
        let current = ProcessInfo.processInfo.environment["PATH"]
        let updated = augmented(
            current: current,
            home: NSHomeDirectory(),
            directoryExists: { path in
                var isDirectory: ObjCBool = false
                return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
            }
        )

        guard updated != current else { return }
        setenv("PATH", updated, 1)
        DebugLog.write("ToolPath.applyToProcessEnvironment extended PATH")
    }
}
