# Prompt implementation plan

Prompt is a macOS-only terminal with native ambient assistance. It embeds
`libghostty` for terminal emulation and rendering and integrates Codex through
`codex app-server`. The terminal—not a chat timeline—is the permanent product
surface. Assistance appears temporarily over the terminal and may use or act on
terminal state with explicit permissions.

## Product principles

1. The terminal is complete and useful without AI.
2. AI is an ambient terminal capability, not the main navigation model, a web
   view, or a permanently visible sidebar.
3. Commands proposed by AI are inserted for review by default. Execution and
   file modification remain explicit approval actions.
4. Codex remains the source of truth for authentication, models, usage,
   conversation history, configuration, permissions, skills, hooks, and
   plugins.
5. Prompt uses Codex project-root semantics rather than assuming every project
   is a Git repository.
6. Terminal output is untrusted context. Prompt-generated session metadata is
   application context.

## Architecture

- The pinned Ghostty macOS app and real libghostty surface provide the terminal,
  windows, tabs, splits, renderer, PTY, and native macOS integration.
- `PromptController` owns the temporary assistant panel and active-surface bridge.
- `PromptModel` and `CodexAppServer` own JSONL transport, threads, streaming,
  models, usage, approvals, command insertion, and handoff.
- `ProjectResolver` owns Codex-compatible project-root discovery.
- `PromptBlockStore` receives unconditional OSC 133 completion events.
- `PromptContextEngine` fuses live terminal, semantic blocks, Git, rules,
  manifests, and relevant tracked source with visible provenance.

This describes the implementation that exists today. Proposed module extraction
is an internal refactor, not a claimed capability.

## Target functional scope

The bullets in this section are product targets, not completion claims. Actual
status is recorded in the evidence-based audit below.

### Terminal

- A real interactive shell rendered by libghostty.
- Keyboard, mouse, selection, clipboard, resize, focus, and Unicode/IME input.
- Command-boundary, current-directory, exit-code, and duration capture through
  shell integration.
- Full-screen terminal applications remain usable.

### Ambient assistance

- The shell always receives ordinary terminal input; `⌘⇧Space` opens a compact
  assistant composer for explicit AI input.
- Native streaming Codex messages and agent activity.
- Explain-last-error, investigate, fix-in-current-thread, and
  fix-in-new-thread actions.
- Command proposals with separate Insert and Run actions.
- Native approvals for command execution and file changes.
- Native diff presentation.
- Quiet, Helpful, and Proactive assistance modes.

### Codex integration

- Managed ChatGPT authentication through app-server.
- Runtime model discovery, including Spark only when actually available.
- Rate-limit and usage visibility.
- Persistent thread creation, listing, reading, naming, resume, fork, archive,
  interruption, and steering.
- Structured event decoding with forward-compatible unknown-event handling.
- Per-turn context input that explicitly labels retrieved terminal/project
  evidence as untrusted. Migrate to `additionalContext` if the installed
  app-server schema exposes it as a stable field.
- Effective Codex configuration, skills, hooks, permission profiles, and
  project-local instruction behavior inherited from the user installation.

### Projects and handoff

- Resolve the effective Codex project root using configured root markers.
- Preserve both project root and current working directory.
- Discover existing Codex threads anywhere under the project root.
- Resume or fork threads created by Prompt, Codex CLI, or desktop.
- Open a thread in Codex CLI.
- Open a project with `codex app <root>`.
- Open a specific desktop thread through the currently supported
  `codex://threads/<id>` route, with a project-opening fallback.

## Compatibility strategy

- Pin Ghostty to an exact revision. Introduce a narrower terminal boundary only
  when doing so does not discard useful native Ghostty macOS behavior.
- Generate app-server JSON Schema from the installed Codex CLI during
  development and test fixtures against it.
- Use stable app-server methods for core behavior.
- Keep dynamic Prompt tools and shared-daemon/live-handoff experiments behind
  capability checks so their absence cannot break terminal or chat behavior.
- Never parse private desktop application databases as a source of truth.

## Evidence-based gap audit (20 July 2026)

### Implemented and verified

- Real Prompt.app build using the pinned libghostty implementation.
- Interactive shell, tabs, splits, search, selection, IME, and Ghostty-native
  macOS terminal behavior.
- Bottom-aligned Shell/AI command bar inside each terminal surface; the former
  floating assistant window is no longer part of the interaction path.
- Sanitized AI request/response blocks rendered into Ghostty's actual grid and
  scrollback with distinct labels and colors.
- Codex app-server initialization, threads, streaming, approvals, model and
  rate-limit reads, CLI/desktop handoff, and Spark default.
- Codex-root resolution plus terminal/Git/rules/manifest/source retrieval.
- Unconditional OSC 133 command-completion bridge and bounded in-memory block
  evidence containing exit code, duration, CWD, and terminal snapshot.

### Partial—must not be represented as complete

- Semantic blocks are captured for context but are not yet drawn, selectable,
  persistent, or precisely ranged to command/output rows.
- Diffs and activity arrive as text cards; there is no native editable review UI.
- Structured app-server messages are decoded defensively, but generated schema
  compatibility and complete typed event coverage are not implemented.
- Desktop handoff uses the available URL route/fallback; cross-app live context
  transfer is not guaranteed by the app-server.
- Context retrieval is useful but still scan-based: durable FTS5, Tree-sitter,
  LSP/SCIP, embeddings, index invalidation, and user-visible context chips remain.

### Missing product surface

- Block actions/navigation, modern command editor, completions, unified search,
  workflows/notebooks/library, project explorer/editor/LSP, Git review,
  permission profiles, MCP manager, concurrent agents, and remote/team services.
- Quiet/Helpful/Proactive modes, explain/fix actions, interrupt/steer UI, native
  file-change approval detail, thread naming, and full project-wide discovery.
- Accessibility coverage and a new end-to-end video for the expanded parity scope.

The detailed Warp-sized backlog and its source links live in `WARP_PARITY.md`.

## Acceptance criteria for the current milestone

1. The application builds as a native macOS app and launches without Xcode.
2. A user can type and execute real shell commands in the libghostty surface.
3. Prompt observes cwd, command completion, output, and exit status.
4. The app connects to the installed Codex app-server and shows account, model,
   and rate-limit state.
5. A user can ask about a failed command and receive a streaming native reply
   with the failure attached as untrusted context.
6. A user can insert or explicitly run a suggested command.
7. Codex command and file-change approvals appear and can be answered.
8. Prompt detects the Codex project root and shows existing project threads.
9. A current thread can be resumed and forked; a failure can be delegated to a
   new fork while the original terminal remains usable.
10. The resulting thread can be opened in Codex CLI and the desktop app.
11. Automated unit and protocol compatibility tests pass.
12. The complete flow is manually exercised through macOS accessibility-based
    Computer Use and captured in a video walkthrough.

## Build order

1. Pin/build libghostty and prove one interactive terminal surface.
2. Build the app-server transport and protocol models.
3. Add project resolution and persistent thread integration.
4. Add semantic block capture and ambient assistance actions without replacing
   the terminal with a timeline UI.
5. Add approvals, diffs, suggestions, and handoff.
6. Add tests, accessibility identifiers, manual verification, and recording.
