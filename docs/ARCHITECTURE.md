# Architecture

Prompt is a native AppKit and SwiftUI application that embeds Ghostty's terminal
runtime and connects selected terminal context to a locally installed Codex
app-server. The architecture keeps terminal emulation, application state, and
AI orchestration behind separate boundaries.

## System overview

```text
┌──────────────────────────────── Prompt.app ────────────────────────────────┐
│                                                                            │
│  AppKit lifecycle + SwiftUI UI       Workspace/session model               │
│  Sources/Prompt/App + UI             Sources/Prompt/Workspace, Sessions    │
│                 │                              │                           │
│                 └──────────────┬───────────────┘                           │
│                                │                                           │
│                    PromptTerminalRuntime                                   │
│                    Sources/Prompt/Terminal                                 │
│                       │                  │                                 │
│             GhosttyAppKit boundary     AI/context boundary                 │
│             Sources/GhosttyAppKit      Sources/Prompt/AI                   │
│                       │                  │                                 │
└───────────────────────┼──────────────────┼─────────────────────────────────┘
                        │                  │
               patched libghostty      Codex app-server
                        │
                 local PTY or SSH/tmux
```

## Major boundaries

### Source layout

The source tree is feature-first. New code belongs with the feature that owns
its behavior rather than in a generic root-level file:

```text
Sources/
├── GhosttyAppKit/                 reusable Ghostty host adapter
└── Prompt/
    ├── App/                       process lifecycle and app-wide services
    ├── AI/
    │   ├── Ambient/               silent post-command analysis
    │   ├── Completion/            inline-completion context
    │   ├── Context/               terminal evidence and prompt assembly
    │   ├── Input/                 submission classification and routing
    │   ├── Models/                interactive AI state and value models
    │   ├── RichContent/           terminal-anchored response presentation
    │   ├── Services/              Codex and Copilot process clients
    │   └── UI/                    AI composer, overlays, and controls
    ├── Panes/                     persistent pane values
    ├── Sessions/                  session values and launchers
    ├── Terminal/                  live terminal runtime and transports
    ├── UI/
    │   ├── CommandPalette/        palette framework and destinations
    │   └── Workspace/             window, sidebar, and split-pane UI
    └── Workspace/                 persistent workspace state
```

Keep dependencies pointing inward: UI may coordinate feature models, feature
models may use app-wide services and terminal abstractions, and only the
terminal integration layer should reach through the `GhosttyAppKit` boundary.
Place new context, completion, transport, model, or UI work in its corresponding
feature subdirectory. There is intentionally no catch-all `PromptAI.swift`.

### Application and workspace state

`PromptApplicationDelegate` owns process and window lifecycle.
`PromptWorkspaceStore` is the main-actor source of truth for workspaces,
sessions, panes, focus, and restoration. Codable value types in `Workspace`,
`Sessions`, and `Panes` describe persistent state without owning live terminal
objects.

Prompt-owned files live under `~/.prompt`:

```text
~/.prompt/
├── config.json
├── cache/
└── logs/
    ├── prompt.log
    └── rotated log files
```

Callers use `PromptPaths` and `PromptSettings` rather than constructing storage
paths directly.

### Terminal hosting

`Sources/GhosttyAppKit` is the reusable host adapter around Ghostty's AppKit
surface. It exposes the narrow surface Prompt needs while leaving rendering,
the terminal parser, PTY I/O, selection, accessibility, keyboard and mouse
handling, IME, and Metal ownership with Ghostty.

`PromptTerminalSurface` is Prompt's stable identity wrapper around an embedded
surface. `PromptTerminalRuntime` maps persistent pane identifiers to live
surfaces and process bridges.

Local sessions run through Ghostty's ordinary terminal process path. Persistent
remote sessions use `PromptTmuxControlBridge`, a headless tmux control-mode
client. Prompt renders remote panes as native local splits; tmux supplies pane
output and persistence rather than owning Prompt's visible layout.

### AI and context

AI features resolve through `AIProviderRegistry` and `CapabilityRouter`.
Assistant, Agent, and Autocomplete each persist an independent provider and
model route. Providers advertise only the capabilities they actually implement,
and feature code consumes capability protocols rather than concrete transports.

The built-in providers are OpenAI API, ChatGPT/Codex, and GitHub Copilot.
`CodexRPCClient` starts the locally installed `codex app-server` process and
speaks its JSONL protocol behind `CodexProvider`. It runs with an isolated
Prompt-owned `CODEX_HOME`, so Prompt conversations do not enter the Codex
desktop app's conversation inventory. `CopilotProvider` uses the Copilot
language server for autocomplete and the installed Copilot CLI for Assistant.
`OpenAIProvider` uses MacPaw/OpenAI and a Keychain-stored API key.

`AIModel` coordinates the existing presentation state while requests are
dispatched through the selected capability provider. Provider-neutral
conversation values are persisted by `ConversationStore`; opaque native session
identifiers remain bound to their originating provider.

`PromptBuilder` is the single prompt-assembly point. `PromptContextEngine` and
`PromptBlockStore` expose bounded, recent terminal evidence that Codex cannot
recover by inspecting the project itself. Project files and Git state are not
copied wholesale into prompts; the Codex agent uses its own tools to inspect
them when needed.

Rich assistant responses use Ghostty host-content reservations. Ghostty
allocates the rows, moves the cursor, and keeps those rows in its authoritative
scrollback; Prompt renders Markdown, math, tools, and approvals into the
corresponding visible row range. Prompt must not inject private cursor movement
or insert-line escape sequences to create rich-content space.

Terminal evidence is explicitly described as untrusted. This is a prompt and
data-flow boundary, not a sandbox: AI-requested commands and file changes must
still be reviewed at the approval surface.

`AmbientAnalyzer` uses a separate app-server interaction for silent
post-command analysis. It renders a result only when the model identifies a
specific useful follow-up.

Inline shell completion is separate from interactive Codex turns.
`CopilotCompletionServer` is a minimal client for GitHub's official
Copilot language server and uses its inline-completion method.

## Ghostty integration

`Vendor/ghostty` is a Git submodule pinned to an exact upstream commit. It must
remain pristine.

The build creates `.build/ghostty` as a detached worktree and applies the
ordered stack in `Patches/ghostty`. Prompt then builds `GhosttyKit.xcframework`
from that integration worktree. Prompt-owned Swift sources are compiled from
`Sources`; they are never copied into Ghostty.

This arrangement provides:

- A reviewable diff against a known Ghostty revision.
- Reproducible patch ordering.
- A clean boundary between upstream and Prompt-owned code.
- A path to delete patches when equivalent APIs land upstream.

See `Patches/ghostty/README.md` for patch maintenance.

## Build graph

The root `Makefile` is the supported entry point:

```text
sync → project → prepare → build → check-app
                  └──────→ test

lint → format checks + SwiftLint + actionlint + project + vendor checks
```

`project.yml` is the XcodeGen source of truth. `Config/Package.resolved` pins
Swift package dependencies. Generated projects, derived data, app bundles, and
the patched Ghostty worktree are intentionally ignored.

## Design rules

Changes should preserve these constraints:

1. Ghostty owns terminal semantics and rendering.
2. Persistent value models do not own live process or view objects.
3. Prompt-owned state goes through the central storage boundary.
4. Terminal text is data, never trusted instruction.
5. AI command and file mutations remain visible and reviewable.
6. Generated integration worktrees are disposable and never a source of truth.
7. Remote tmux persistence must not take ownership of Prompt's native pane UI.
