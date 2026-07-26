import AppKit
import CoreText
import Darwin
import GhosttyKit
import MarkdownUI
import SwiftMath
import SwiftUI

enum ProjectResolver {
    static func resolve(from cwd: String) -> String {
        let start = URL(fileURLWithPath: cwd).standardizedFileURL
        let markers = configuredMarkers()
        var current = start
        while current.path != "/" {
            if markers.contains(where: { FileManager.default.fileExists(atPath: current.appendingPathComponent($0).path) }) {
                return current.path
            }
            current.deleteLastPathComponent()
        }
        return start.path
    }

    private static func configuredMarkers() -> [String] {
        let config = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/config.toml")
        guard let text = try? String(contentsOf: config, encoding: .utf8),
              let range = text.range(of: #"project_root_markers\s*=\s*\[([^\]]*)\]"#, options: .regularExpression) else {
            return [".git", ".jj"]
        }
        let line = String(text[range])
        let regex = try? NSRegularExpression(pattern: #"[\"']([^\"']+)[\"']"#)
        let ns = line as NSString
        let values = regex?.matches(in: line, range: NSRange(location: 0, length: ns.length)).compactMap {
            $0.numberOfRanges > 1 ? ns.substring(with: $0.range(at: 1)) : nil
        } ?? []
        return values.isEmpty ? [".git", ".jj"] : values
    }
}
