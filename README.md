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
the root build copies Prompt-owned files into that checkout and applies the
small, versioned integration patch before every build or test.

Start from a full clone with submodules:

```sh
git clone --recurse-submodules https://github.com/LucaLeukert/prompt.git
cd prompt
```

From the repository root, the complete local development loop is:

```sh
make run
```

For native Xcode development, open the checked-in workspace:

```sh
make xcode
```

This opens `Prompt.xcworkspace` with a shared **Prompt App** scheme backed by a
native macOS application target. Xcode Run, Test, Profile, Analyze, and Archive
are configured. The scheme prepares the Prompt sources, resources, integration
patch, and native Ghostty framework before Xcode builds, so editing in the
repository and pressing Run uses the current checkout.

The root `Makefile` is the build system entry point. It owns source/resource
synchronization, the patched native Ghostty framework build, the Xcode app
build, artifact validation, tests, and launching. The runnable bundle always
lands at:

```text
Artifacts/Debug/Prompt.app
```

Other useful commands are:

```sh
make build  # build without launching
make test   # run the Prompt test suite
make clean  # remove repo-local generated build output
make help   # show the command summary
```

All generated development state stays under `Artifacts/`, `DerivedData/`, and
the checked-out Ghostty submodule in this repository. Prompt-owned fonts and
icons are vendored under `Resources/` and Xcode copies them into the app as
part of the build; the finished bundle is checked for required resources
before a build is reported successful.

Set `CONFIGURATION=Release` to use the same targets for a local Release build.
The project targets macOS and requires Xcode plus Zig 0.15; the build installs
the Homebrew Zig formula if it is unavailable.

## Git worktrees

Prompt treats both a `.git` directory and Git's `.git` worktree file as a
project-root marker, so terminal commands and Codex sessions stay scoped to
the active worktree. Build and test from the worktree itself; the scripts
initialize its Ghostty submodule, apply the pinned Prompt patch, and build an
XCFramework in that checkout. This keeps generated terminal artifacts and
the `Artifacts`/`DerivedData` output isolated between worktrees.

```sh
git worktree add ../prompt-feature -b feature
cd ../prompt-feature
make test
```
