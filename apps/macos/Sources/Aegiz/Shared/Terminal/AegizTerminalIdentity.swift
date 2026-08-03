import Foundation

enum AegizTerminalIdentity {
    /// Loaded after the user's Ghostty files. Aegiz owns the embedded surface
    /// palette and spacing, while user font families and terminal behaviors
    /// continue to come from their normal Ghostty configuration.
    static let configurationText = """
    background = #0E1211
    foreground = #DCE8E3
    cursor-color = #73D6BD
    cursor-text = #0E1211
    cursor-style = bar
    selection-background = #284C43
    selection-foreground = #F1FAF7
    minimum-contrast = 3
    window-padding-x = 10
    window-padding-y = 8
    window-padding-balance = true
    background-opacity = 1
    palette = 0=#111715
    palette = 1=#EF6B73
    palette = 2=#73D6A5
    palette = 3=#EBCB75
    palette = 4=#79A9FF
    palette = 5=#C397E8
    palette = 6=#5FD0C3
    palette = 7=#DCE8E3
    palette = 8=#66736F
    palette = 9=#FF8790
    palette = 10=#8EE7B9
    palette = 11=#F4D889
    palette = 12=#94BBFF
    palette = 13=#D7ACEF
    palette = 14=#79E1D3
    palette = 15=#F5FBF8
    """

    static func preparedConfigurationPath(
        fileManager: FileManager = .default
    ) -> String? {
        do {
            let directory = try fileManager.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            .appending(path: "Aegiz", directoryHint: .isDirectory)
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )

            let destination = directory.appending(
                path: "embedded-terminal.conf",
                directoryHint: .notDirectory
            )
            let data = Data((configurationText + "\n").utf8)
            if (try? Data(contentsOf: destination)) != data {
                try data.write(to: destination, options: .atomic)
            }
            try fileManager.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: destination.path
            )
            return destination.path
        } catch {
            return nil
        }
    }
}
