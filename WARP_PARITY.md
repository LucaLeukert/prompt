# Prompt ↔ Warp Functional Parity Contract

This document tracks functional parity with Warp as documented in July 2026.
Prompt will not copy Warp trademarks, proprietary implementation, copywriting,
or visual assets. “Parity” means an independently implemented capability that
solves the same user problem while preserving Prompt’s terminal-first product
hierarchy.

## Product rule

The terminal is always the primary surface. AI may annotate, retrieve, explain,
propose, monitor, or act with permission, but it never replaces the shell by
default. A clean terminal must remain one shortcut away.

## Terminal core

- [x] GPU-native terminal engine, PTY, keyboard, mouse, IME, selection, links,
  alternate screen, shell integration, themes, tabs, splits, search, quick
  terminal, session restoration, and macOS services through libghostty.
- [ ] **Partial:** semantic command blocks capture completion, duration, exit status, CWD, and a
  bounded terminal snapshot are captured in memory and used as context. Precise
  prompt/command/output row ranges, persistence, Git/environment/agent metadata,
  and visible rendering remain.
- [ ] Block selection/navigation, copy command/output, re-input, bookmark,
  share/export, save as workflow, attach as context, and failure decoration.
- [ ] IDE-like multiline input with soft wrap, paired delimiters, selections,
  multiple cursors, Vim/Emacs modes, synchronized input, and configurable
  top/bottom pinning.
- [ ] Spec-driven completions, path/flag/resource completion, history-based
  autosuggestions, partial acceptance, corrections, and command-not-found help.
- [ ] Rich per-session history plus fuzzy unified search across commands,
  blocks, workflows, prompts, notebooks, plans, and assistant conversations.
- [ ] Searchable command palette and fully customizable shortcuts.
- [ ] Global hotkey modes, named/colorized tabs, pane navigation/zoom/dimming,
  session switcher, nested launch configurations, and project restoration.
- [ ] **Partial:** SSH sessions use tmux control mode for reconnectable native
  panes and inline terminal-context AI, with an attached-TTY compatibility mode.
  Remote filesystem tools, mosh, containers, and Kubernetes remain.
  degradation shown explicitly.
- [ ] Secret redaction, secure input, dynamic secret-manager references, and
  privacy controls.

## Knowledge and reusable workflows

- [ ] Local Prompt Library: folders of parameterized workflows, notebooks,
  prompts, rules, environment sets, plans, and launch configurations.
- [ ] Workflow arguments, defaults, static/dynamic enums, aliases, environment
  injection, subshell isolation, YAML import/export, and searchable execution.
- [ ] Executable Markdown notebooks with runnable shell blocks.
- [ ] Project/global rules, AGENTS.md compatibility, skills, saved commands,
  reusable plans, and citations when any knowledge object is retrieved.
- [ ] Optional encrypted sync and team sharing with secret scrubbing; local-only
  remains the default.

## Project and code tools

- [ ] Project explorer with create/open/rename/move, context attachment, file
  watching, icons, and fuzzy file/symbol search.
- [ ] Lightweight native editor with tabs, shared buffers, syntax highlighting,
  find/replace, Vim bindings, and external-editor handoff.
- [ ] LSP client: diagnostics, hover, definition, references, implementations,
  rename, code actions, and format-on-save.
- [ ] Live Git status and diff chip, side-by-side/unified review, editable hunks,
  per-hunk/file/all revert, arbitrary-base comparison, comments, and attach to
  assistant.
- [ ] Worktree creation/switching and branch/PR metadata on sessions.

## Ambient assistance and agents

- [x] Compact terminal-context assistant, streaming Codex threads, Spark default,
  model/rate-limit discovery, approvals, command insert/run, and Codex handoff.
- [x] Live terminal viewport, project root, Git, rules/manifests, and relevant
  Git-tracked files retrieved locally with provenance.
- [ ] `@` attachments for blocks, files, folders, symbols, diffs, images, URLs,
  rules, skills, workflows, notebooks, plans, and MCP resources.
- [ ] Slash commands, editable/versioned plans, task lists, interrupt/steer/retry,
  checkpoints, and selective execution.
- [ ] Full terminal use for running TUIs/REPLs/servers with take-over, visibility,
  and per-process write permission controls.
- [ ] Multiple concurrent local/remote agents, status monitor, notifications,
  worktree isolation, audit trail, and local↔remote handoff.
- [ ] Profiles covering read/write/diff/command/PTY/MCP/network permissions,
  allow/deny rules, session grants, and secret boundaries.
- [ ] MCP server discovery/configuration/status/logs/OAuth, resources, prompts,
  tools, and safe team export.
- [ ] Voice, image/URL context, web search, and sandboxed computer-use providers.

## Cloud and organization features

- [ ] Provider-neutral remote runner API, reproducible environments, schedules,
  triggers, logs, steering, audit, and reconnect.
- [ ] Optional organization identity, role/policy controls, usage reporting,
  zero-retention modes, BYO model/compute, and password-manager integrations.

## Source audit

Primary references: [Warp terminal](https://www.warp.dev/terminal),
[Blocks](https://docs.warp.dev/terminal/blocks),
[Modern text editing](https://docs.warp.dev/terminal/editor),
[Command history](https://docs.warp.dev/terminal/entry/command-history),
[Command search](https://docs.warp.dev/terminal/entry/command-search),
[Session management](https://docs.warp.dev/terminal/sessions),
[Workflows](https://docs.warp.dev/knowledge-and-collaboration/warp-drive/workflows),
[Code editor](https://docs.warp.dev/code/code-editor),
[Code review](https://docs.warp.dev/code/code-review), and
[Agent capabilities](https://docs.warp.dev/agent-platform/capabilities).
