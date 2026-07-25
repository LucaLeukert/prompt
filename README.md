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
the build creates an isolated worktree under `.build/ghostty` and applies two
small, ordered integration patches there. Prompt sources are compiled directly
from `Sources` and are never copied into Ghostty.

Start from a full clone with submodules:

```sh
git clone --recurse-submodules https://github.com/LucaLeukert/prompt.git
cd prompt
```

From the repository root, the complete local development loop is:

```sh
make run
```

For native Xcode development, generate and open Prompt's project:

```sh
make xcode
```

This prepares Ghostty, generates `Prompt.xcodeproj` from the checked-in
`project.yml`, and opens the shared **Prompt** scheme. Run, Test, Profile,
Analyze, and Archive are configured against Prompt's own application target.
Xcode indexes the canonical files under `Sources`, so there are no disposable
copies to edit accidentally.

The root `Makefile` is the build-system entry point. It owns the isolated
Ghostty integration worktree, native Ghostty framework build, Xcode project
generation, app build, artifact validation, tests, and launching. The runnable
bundle always lands at:

```text
Artifacts/Debug/Prompt.app
```

Other useful commands are:

```sh
make build  # build without launching
make test   # run the Prompt test suite
make format # apply Swift formatting
make lint   # check Swift formatting/rules and GitHub Actions
make clean  # remove repo-local generated build output
make help   # show the command summary
```

Install the local build and lint tools once with `make lint-install`. Prompt
uses XcodeGen, SwiftFormat, SwiftLint, and actionlint with checked-in repository
configuration. CI runs the same `make lint` target used locally.

All generated development state stays under `Artifacts/`, `DerivedData/`, and
`.build/`. The checked-out Ghostty submodule remains pristine after sync,
builds, and tests. Prompt-owned fonts and icons are vendored under `Resources/`
and Xcode copies them into the app; the finished bundle is checked for required
resources before a build is reported successful.

Set `CONFIGURATION=Release` to use the same targets for a local Release build.
The project targets macOS and requires Xcode, XcodeGen, and Zig 0.15. The build
installs the Homebrew Zig formula if it is unavailable.

## Git worktrees

Prompt treats both a `.git` directory and Git's `.git` worktree file as a
project-root marker, so terminal commands and Codex sessions stay scoped to
the active worktree. Build and test from the worktree itself; the scripts
initialize its Ghostty submodule, create a separate integration worktree under
`.build`, apply the pinned Prompt patches, and build an XCFramework there. This
keeps the submodule and all generated artifacts isolated between worktrees.

```sh
git worktree add ../prompt-feature -b feature
cd ../prompt-feature
make test
```
