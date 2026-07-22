# Prompt Context Engine

Prompt keeps prompt context deliberately small. Codex is running through the
app server with workspace tools, so repository contents are discovered by the
agent when they are needed instead of being copied into every turn.

## Retrieval pipeline

1. Resolve the workspace root from the pane CWD and Codex project markers.
2. Attach only relevant ephemeral state the agent cannot read from files: the
   active terminal viewport and recent semantic command blocks.
3. Label that state as untrusted evidence and keep it out when it does not match
   the request.
4. Let Codex use its app-server tools for files, Git state, manifests, rules,
   tests, and edits.

## Implemented first tier

`PromptContextEngine.swift` retrieves and labels:

- active libghostty viewport;
- recent OSC 133 command blocks, including exit status and CWD.

It does not scan repository files or run Git. All attached content is sent as
explicitly untrusted evidence rather than instructions.

## Action contract

Codex can inspect and change the workspace through the app server. For shell
actions that should remain under direct user control, `turn/start` supplies a
JSON output schema with a user-facing `response` and nullable single-line
`command`. Prompt parses that result, switches the native composer to Shell
mode, and inserts the command for review rather than executing it automatically.
