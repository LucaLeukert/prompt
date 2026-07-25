import Foundation

enum PromptLocalSessionLauncher {
    struct Worktree: Equatable {
        let path: String
        let repository: String
        let branch: String?
        let isMain: Bool
    }

    struct GitLocation: Codable, Equatable, Sendable {
        let path: String
        let repository: String
        let branch: String?
        let isMainWorktree: Bool
    }

    struct Container: Equatable {
        let id: String
        let name: String
        let state: String
    }

    enum LaunchError: LocalizedError {
        case missingDirectory(String)
        case unavailableTool(String)
        case failed(String)
        case unsafeCleanupTarget

        var errorDescription: String? {
            switch self {
            case .missingDirectory(let path): "The directory is unavailable: \(path)"
            case .unavailableTool(let tool): "\(tool) is not installed or is not available in PATH."
            case .failed(let message): message
            case .unsafeCleanupTarget: "Prompt refused to clean up a directory it did not create."
            }
        }
    }

    static func projectRoot(containing directory: String) -> String {
        gitRoot(containing: directory) ?? directory
    }

    static func gitRoot(containing directory: String) -> String? {
        try? run("/usr/bin/git", ["-C", directory, "rev-parse", "--show-toplevel"])
    }

    static func gitLocations(
        searching directory: String,
        seeds: [String] = [],
        cached: [GitLocation] = []
    ) -> [GitLocation] {
        let searchURL = URL(fileURLWithPath: (directory as NSString).expandingTildeInPath).standardizedFileURL
        var locations = Dictionary(uniqueKeysWithValues: cached.map { ($0.path, $0) })
        let cachedPaths = Set(cached.flatMap { [$0.path, $0.repository] }.map {
            URL(fileURLWithPath: $0).standardizedFileURL.path
        })
        var roots = Set(seeds.filter {
            !cachedPaths.contains(URL(fileURLWithPath: $0).standardizedFileURL.path)
        }.compactMap(gitRoot))
        if !cachedPaths.contains(searchURL.path),
           let root = gitRoot(containing: searchURL.path) {
            roots.insert(root)
        }

        // A shallow recursive scan covers common layouts such as
        // ~/Developer/company/repository while keeping a home-directory search
        // bounded. Stop below repositories: nested worktrees are obtained from
        // Git metadata instead of another filesystem walk.
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isPackageKey, .isSymbolicLinkKey]
        let maximumDepth = 4
        let maximumDirectories = 2_000
        let enumerator = FileManager.default.enumerator(
            at: searchURL,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles, .skipsPackageDescendants],
            errorHandler: { _, _ in true })
        var inspectedDirectories = 0
        while let candidate = enumerator?.nextObject() as? URL {
            let depth = candidate.pathComponents.count - searchURL.pathComponents.count
            if depth > maximumDepth {
                enumerator?.skipDescendants()
                continue
            }
            guard let values = try? candidate.resourceValues(forKeys: keys),
                  values.isDirectory == true,
                  values.isPackage != true,
                  values.isSymbolicLink != true
            else {
                enumerator?.skipDescendants()
                continue
            }
            inspectedDirectories += 1
            if inspectedDirectories >= maximumDirectories {
                break
            }
            guard FileManager.default.fileExists(atPath: candidate.appendingPathComponent(".git").path),
                  let root = gitRoot(containing: candidate.path)
            else { continue }
            roots.insert(root)
            enumerator?.skipDescendants()
        }

        for root in roots {
            guard let values = try? worktrees(containing: root) else { continue }
            for value in values {
                locations[value.path] = .init(
                    path: value.path,
                    repository: value.repository,
                    branch: value.branch,
                    isMainWorktree: value.isMain)
            }
        }
        return locations.values.sorted {
            let lhs = URL(fileURLWithPath: $0.repository).lastPathComponent
            let rhs = URL(fileURLWithPath: $1.repository).lastPathComponent
            if lhs != rhs { return lhs.localizedStandardCompare(rhs) == .orderedAscending }
            if $0.isMainWorktree != $1.isMainWorktree { return $0.isMainWorktree }
            return ($0.branch ?? $0.path).localizedStandardCompare($1.branch ?? $1.path) == .orderedAscending
        }
    }

    static func createScratchDirectory(fileManager: FileManager = .default) throws -> String {
        let parent = fileManager.temporaryDirectory.appendingPathComponent("dev.prompt.scratch", isDirectory: true)
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        let directory = parent.appendingPathComponent(UUID().uuidString.lowercased(), isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: false)
        return directory.standardizedFileURL.path
    }

    static func cleanupScratchDirectory(_ path: String, fileManager: FileManager = .default) throws {
        let target = URL(fileURLWithPath: path).standardizedFileURL
        let parent = fileManager.temporaryDirectory
            .appendingPathComponent("dev.prompt.scratch", isDirectory: true).standardizedFileURL
        guard target.deletingLastPathComponent() == parent,
              UUID(uuidString: target.lastPathComponent) != nil else {
            throw LaunchError.unsafeCleanupTarget
        }
        guard fileManager.fileExists(atPath: target.path) else { return }
        try fileManager.removeItem(at: target)
    }

    static func worktrees(containing directory: String) throws -> [Worktree] {
        let common = try run("/usr/bin/git", ["-C", directory, "rev-parse", "--path-format=absolute", "--git-common-dir"])
        let repository = URL(fileURLWithPath: common).deletingLastPathComponent().path
        let output = try run("/usr/bin/git", ["-C", directory, "worktree", "list", "--porcelain"])
        var values: [Worktree] = []
        var path: String?
        var branch: String?
        var isBare = false
        func append() {
            guard let path else { return }
            values.append(.init(
                path: path,
                repository: repository,
                branch: branch?.replacingOccurrences(of: "refs/heads/", with: ""),
                isMain: values.isEmpty && !isBare))
        }
        for line in output.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            if line.isEmpty {
                append()
                path = nil
                branch = nil
                isBare = false
            } else if line.hasPrefix("worktree ") {
                path = String(line.dropFirst("worktree ".count))
            } else if line.hasPrefix("branch ") {
                branch = String(line.dropFirst("branch ".count))
            } else if line == "bare" {
                isBare = true
            }
        }
        append()
        return values
    }

    static func createWorktree(repository: String, path: String, branch: String) throws -> Worktree {
        let target = URL(fileURLWithPath: path).standardizedFileURL.path
        _ = try run("/usr/bin/git", ["-C", repository, "worktree", "add", "-b", branch, target])
        return .init(path: target, repository: repository, branch: branch, isMain: false)
    }

    static func removePromptWorktree(_ worktree: Worktree, ownership: PromptLocalSessionDetails.Ownership) throws {
        guard ownership == .prompt else {
            throw LaunchError.failed("Externally created worktrees require explicit confirmation before removal.")
        }
        _ = try run("/usr/bin/git", ["-C", worktree.repository, "worktree", "remove", "--", worktree.path])
    }

    static func containers() throws -> [Container] {
        guard let docker = executable(named: "docker") else { throw LaunchError.unavailableTool("Docker") }
        let output = try run(docker, ["container", "ls", "-a", "--format", "{{.ID}}\t{{.Names}}\t{{.State}}"])
        return output.split(whereSeparator: \.isNewline).compactMap { line in
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard fields.count == 3 else { return nil }
            return .init(id: fields[0], name: fields[1], state: fields[2])
        }
    }

    static func containerCommand(identity: String, shell: String = "/bin/sh") -> String {
        [executable(named: "docker") ?? "docker", "exec", "-it", identity, shell]
            .map(shellQuote).joined(separator: " ")
    }

    static func composeCommand(service: String, shell: String = "/bin/sh") -> String {
        [executable(named: "docker") ?? "docker", "compose", "exec", service, shell]
            .map(shellQuote).joined(separator: " ")
    }

    static func composeServices(directory: String) throws -> [String] {
        guard let docker = executable(named: "docker") else { throw LaunchError.unavailableTool("Docker") }
        let process = Process()
        let output = Pipe()
        let error = Pipe()
        process.executableURL = URL(fileURLWithPath: docker)
        process.arguments = ["compose", "config", "--services"]
        process.currentDirectoryURL = URL(fileURLWithPath: directory)
        process.standardOutput = output
        process.standardError = error
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return [] }
        return String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .split(whereSeparator: \.isNewline).map(String.init)
    }

    static func privilegedCommand(_ command: String?) -> String {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let arguments = command.map { ["sudo", "--", shell, "-lc", $0] } ?? ["sudo", "--", shell, "-l"]
        return arguments.map(shellQuote).joined(separator: " ")
    }

    static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func executable(named name: String, searchPath: String? = nil) -> String? {
        let inherited = searchPath ?? ProcessInfo.processInfo.environment["PATH"] ?? ""
        let standardPaths = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
        let paths = inherited.split(separator: ":").map(String.init) + standardPaths
        return Array(NSOrderedSet(array: paths)).compactMap { $0 as? String }
            .map { URL(fileURLWithPath: $0).appendingPathComponent(name).path }
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    @discardableResult
    private static func run(_ executable: String, _ arguments: [String]) throws -> String {
        let process = Process()
        let output = Pipe()
        let error = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = error
        do { try process.run() } catch {
            throw LaunchError.unavailableTool(URL(fileURLWithPath: executable).lastPathComponent)
        }
        process.waitUntilExit()
        let stdout = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard process.terminationStatus == 0 else {
            let stderr = String(decoding: error.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw LaunchError.failed(stderr.isEmpty ? "Command failed with exit code \(process.terminationStatus)." : stderr)
        }
        return stdout
    }
}
