# Prompt

Prompt is a macOS-only terminal with ambient AI assistance. The real libghostty
terminal owns the experience; Codex stays out of the way until it can help with
visible terminal context, an error, a command, or the current project.

Every terminal surface has one bottom command bar. Use **Shell** mode to submit
normal commands to the PTY and **AI** mode to ask Codex. AI questions and
visually labeled responses are rendered into the real Ghostty grid, so they live
beside ordinary command output in the same selectable, searchable scrollback.
**Command-Shift-Space** focuses the bar in AI mode. Spark is the default model.

## What works

- Native Ghostty Metal terminal, PTY, keyboard, mouse, selection, IME, splits,
  tabs, and shell integration.
- Codex app-server lifecycle and JSONL protocol initialization.
- Account, model, and rate-limit discovery (including Spark-capable models when
  the account exposes them).
- Project-root resolution using Codex `project_root_markers`, with `.git` and
  `.jj` defaults.
- Project-scoped thread listing, start, resume, read, fork, and archive.
- Streaming assistant messages and activity/diff cards.
- Terminal output attached as explicitly untrusted turn context.
- Bottom-aligned Shell/AI command bar integrated into every terminal surface.
- Sanitized, ANSI-styled AI blocks injected through libghostty's application
  output bridge into native terminal history—never a separate chat window.
- Approval cards for app-server command and file-change requests.
- Fenced-command **Insert** and **Run** actions against the active libghostty
  surface.
- Silent post-command analysis that suppresses routine results and adds only a
  compact set of AI-selected, SF Symbol-labeled actions when useful.
- SSH sessions backed by headless tmux control mode: Prompt renders panes as
  native splits, preserves inline AI cards locally, and reconnects without
  letting tmux own or repaint the terminal UI. A legacy attached-TTY mode
  remains available from the session launcher.
- `codex resume <thread-id>` and `codex://threads/<thread-id>` handoffs.

The full product and technical plan is in [PLAN.md](PLAN.md).

## Build

Prompt keeps its own sources, resources, and tests in this repository. The
pinned Ghostty source under `Vendor/ghostty` remains an unmodified submodule;
`Scripts/sync-ghostty.sh` copies Prompt-owned files into that checkout and
applies the small, versioned integration patch before every build or test.

Start from a full clone with submodules:

```sh
git clone --recurse-submodules https://github.com/LucaLeukert/prompt.git
cd prompt
```

```sh
./Scripts/build.sh
open DerivedData/Build/Products/Debug/Prompt.app
```

The project currently targets macOS and requires Xcode plus Zig 0.15 (the
build script installs the Homebrew package if it is unavailable).

Run the focused Prompt tests with:

```sh
./Scripts/test.sh
```
