# Ghostty integration patches

Prompt embeds the exact Ghostty revision pinned at `Vendor/ghostty` without
modifying that checkout. `make sync` creates a detached integration worktree at
`.build/ghostty`, resets it to the pinned revision, and applies every patch in
this directory in lexical order.

## Patch inventory

- `0001-embedding-api.patch` adds the narrow C and Zig API used to host
  Ghostty's terminal runtime inside Prompt.
- `0002-appkit-hooks.patch` adds optional AppKit integration hooks consumed by
  `Sources/GhosttyAppKit`.
- `0003-embedded-split-click-target.patch` preserves correct click targeting
  when embedded Ghostty surfaces are arranged as Prompt split panes.

The patches must not add Prompt-owned targets, dependencies, resources, tests,
lockfiles, or application source to Ghostty. Those belong in this repository's
`project.yml`, `Config`, `Resources`, `Sources`, and `Tests` directories.

## Validate the patch stack

Run:

```sh
make patch-check
```

The command verifies the vendor checkout is pristine, recreates the isolated
worktree when necessary, and applies the complete stack. `make lint`, `make
test`, and `make build` also pass through the same synchronization path.

## Update the pinned Ghostty revision

1. Update `Vendor/ghostty` to the intended upstream commit.
2. Run `make patch-check`.
3. Rebase only the patches that no longer apply.
4. Run `make test` and `make lint`.
5. Inspect `git -C Vendor/ghostty status --porcelain`; it must be empty.
6. Commit the submodule pointer and patch changes together.

Never repair a patch by editing `.build/ghostty`. That worktree is disposable
build output and is reset on the next synchronization.

Keep patches small, ordered, and independently explainable. When a patch could
benefit Ghostty generally, prefer proposing it upstream and remove the local
patch once Prompt can build against the released upstream API.
