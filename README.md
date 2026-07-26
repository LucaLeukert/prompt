# Prompt

Prompt is a native macOS terminal built around Ghostty with Codex integrated
into the terminal workflow. It keeps the terminal as the primary interface:
commands, output, and AI responses share the same workspace instead of splitting
your attention between a terminal and a separate chat application.

> [!IMPORTANT]
> Prompt is early-stage software. The `v0.1` codebase is intended for
> developers, and its published build is an unsigned macOS application. Expect
> breaking changes to behavior, configuration, and stored workspace state.

## Why Prompt?

- **A real terminal first.** Rendering, PTY I/O, selection, accessibility,
  keyboard and mouse input, IME, splits, and shell integration are provided by
  Ghostty.
- **AI where the work happens.** Ask Codex about the active terminal and project
  from the command bar. Responses, approvals, diffs, and suggested commands stay
  attached to the terminal session.
- **Useful session workflows.** Open projects, worktrees, containers, remote
  hosts, persistent tmux sessions, scratch directories, and privileged shells
  from one command palette.
- **Explicit control.** Suggested commands can be inserted for review or run
  directly. Codex command and file-change requests remain subject to approval.
- **Native macOS UI.** Prompt uses AppKit, SwiftUI, and Metal rather than a web
  shell around a terminal process.

## Current capabilities

- Local terminal sessions, tabs, native split panes, workspace restoration, and
  searchable/selectable terminal history.
- A bottom command bar with Shell and AI routing.
- Codex app-server startup, account and model discovery, project-scoped threads,
  streaming responses, approval requests, and thread handoff to the Codex CLI
  or desktop app.
- Bounded terminal context supplied to Codex as untrusted evidence; project
  files and Git state are inspected by Codex through its own tools.
- Post-command analysis that stays silent unless it finds a concrete next
  action.
- SSH sessions using headless tmux control mode, with a legacy attached-TTY
  transport available as a fallback.
- Project, Git worktree, container, Compose service, scratch, task, and
  privileged-session launchers.
- Optional discovery of Tailscale SSH peers and GitHub Copilot-powered inline
  shell completions when their local tools and credentials are available.

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for the project's technical
boundaries and feature-first source layout.

## Requirements

To run Prompt:

- macOS 13 Ventura or newer.
- The [Codex CLI](https://github.com/openai/codex) installed and authenticated
  for AI features.
- `ssh` and `tmux` on the relevant hosts for persistent remote sessions.

To build Prompt:

- A full Xcode installation.
- Git and Homebrew.
- XcodeGen, SwiftFormat, SwiftLint, and actionlint. Install them with
  `make lint-install`.
- Zig 0.15. The build installs Homebrew's `zig@0.15` formula when necessary, or
  you can pass an executable with `ZIG=/path/to/zig`.

The Ghostty build normally produces its own runtime resources. If it does not,
the current build fallback expects an installed copy of Ghostty at
`/Applications/Ghostty.app`.

## Build from source

Clone the repository with its Ghostty submodule:

```sh
git clone --recurse-submodules https://github.com/LucaLeukert/prompt.git
cd prompt
make lint-install
make run
```

`make run` builds and opens `Artifacts/Debug/Prompt.app`. The first build is
substantial because Prompt compiles its pinned Ghostty revision.

Common development commands:

```text
make build        Build the app without opening it
make test         Run the unit test suite
make lint         Check formatting, SwiftLint, Actions, project generation,
                  patch application, and the pristine vendor checkout
make format       Apply SwiftFormat to project sources and tests
make patch-check  Apply all Prompt patches to the pinned Ghostty revision
make xcode        Generate and open Prompt.xcodeproj
make clean        Remove repository-local generated output
make help         Print the complete command summary
```

Use `CONFIGURATION=Release` for a local release build:

```sh
make build CONFIGURATION=Release
```

Generated files stay under `Artifacts/`, `DerivedData/`, `.build/`, and
`Prompt.xcodeproj`. Do not edit generated Ghostty sources in `.build/ghostty`;
the source of truth is the pinned submodule plus the patches in
`Patches/ghostty`.

## Configuration and local data

Prompt stores its settings, restored workspace state, caches, and rotating logs
under `~/.prompt`. Codex authentication and configuration remain owned by the
Codex CLI under `~/.codex`.

Terminal output may contain secrets. Prompt treats captured output as untrusted
input, bounds the context it sends, and does not make terminal text equivalent
to instructions. You should still review the active terminal content before
asking an AI question.

## Contributing

Contributions are welcome. Keep changes focused, add tests for behavior changes,
and run `make lint` and `make test` before opening a pull request. For substantial
features or changes to the Ghostty patch stack, open an issue before investing
in a large implementation.

For bugs, include the Prompt version, macOS version, reproduction steps, and the
smallest relevant excerpt from `~/.prompt/logs/prompt.log`. Remove tokens,
commands, paths, hostnames, and terminal output that you do not intend to make
public.

## Project status and releases

Release builds are currently unsigned and not notarized, so macOS will display a
Gatekeeper warning. A signed and notarized distribution path is a
release-readiness requirement, not a completed feature.

## License and acknowledgements

Prompt's original source code is available under the [MIT License](LICENSE).
Third-party components and assets retain their own licenses.

Prompt embeds a pinned revision of
[Ghostty](https://github.com/ghostty-org/ghostty), also licensed under MIT.
Geist font license information is included in
`Resources/Prompt/Fonts/LICENSE.txt`. The OpenAI Blossom is used under OpenAI's
brand guidelines and is not licensed under MIT; details are recorded in
`Resources/Prompt/Fonts/TRADEMARKS.txt`. Codex, OpenAI, Ghostty, and other names
and marks belong to their respective owners; this project is not an official
OpenAI or Ghostty project.
