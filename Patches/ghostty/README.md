# Ghostty integration patches

Prompt builds against the exact Ghostty commit pinned by `Vendor/ghostty`.
`make sync` creates an isolated worktree at `.build/ghostty`, resets it to that
commit, and applies every `*.patch` file in lexical order.

- `0001-embedding-api.patch` adds the small C and Zig API surface required by
  Prompt's embedded terminal runtime.
- `0002-appkit-hooks.patch` adds the Swift/AppKit hooks used by
  `Sources/GhosttyAppKit`.

The patches intentionally contain no Prompt target, Xcode project, dependency
lockfile, resource, test, or Prompt-owned source changes. Those are owned by
`project.yml`, `Config`, `Resources`, `Sources`, and `Tests` in this repository.

Use `make patch-check` after changing the pinned Ghostty commit. A failure names
the exact patch that no longer applies. Rebase only that patch against the new
upstream revision; never edit the generated `.build/ghostty` worktree as a
source of truth.
