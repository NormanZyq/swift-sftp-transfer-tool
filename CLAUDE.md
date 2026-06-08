# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Native macOS SFTP dual-pane file-transfer GUI (SwiftUI), rewritten from an earlier Python/PySide6 version. Built on [Citadel](https://github.com/orlandos-nl/Citadel) (pure-Swift SSH/SFTP over swift-nio-ssh). macOS 14+, Swift 6 toolchain. No runtime dependencies — Citadel/NIO link statically into one binary.

UI strings and most code comments are in **Chinese** (a few build-script comments are Japanese); identifiers are English. Match the surrounding language when editing.

## Commands

```bash
swift build                       # debug build
swift run                         # build & launch the app
swift build -c release            # release binary
./make-app.sh                     # release build + assemble double-clickable "SSH 文件传输.app" (ad-hoc signed)
open Package.swift                # open in Xcode (then Run)
Resources/make-icon.sh            # regenerate AppIcon.icns from Resources/icon.swift
```

There is **no test target** and no linter config — `swift build` is the only correctness gate.

## Architecture

Single-window SwiftUI app. `SFTPTransferApp` creates one `AppModel` and injects it via `.environment()`; views read it through `@Environment(AppModel.self)`.

### Concurrency model (the central design)

- **`SFTPSession` is an `actor`** (`Models/SFTPSession.swift`) that owns the one SSH client + one SFTP channel and serializes every operation against it. This is the load-bearing decision — it replaces the Python version's manual "one thread on the channel at a time" rule. All remote I/O (list, CRUD, upload, download, recursive walk, search) goes through it.
- **Everything UI-facing is `@MainActor`** (`AppModel`, `TransferEngine`, `PaneModel`). Values crossing the actor boundary are `Sendable` (`FileItem`, `HostEntry`, `RemoteItemRef`).
- Progress callbacks fired from inside the actor hop back to the UI with `Task { @MainActor in ... }`.

A change touching remote behavior typically means: add an actor-isolated method on `SFTPSession`, call it from a `@MainActor` model via `await`, and pass only `Sendable` values across.

### State ownership

- `AppModel` (`@MainActor @Observable`) — top level: host list, connection state, the `SFTPSession`, the `TransferEngine`, two `PaneModel`s (`.local` / `.remote`), and all dialog state (passphrase / host-key / error). Holds `transferTask` for cancellation.
- `PaneModel` (`@MainActor @Observable`) — one instance per pane, generic over `kind`. Each pane independently handles browsing, back/forward history, sort, hidden-file toggle, filter-vs-recursive search, and CRUD. Local ops go through `LocalFileSystem`; remote ops go through `app.session`. `displayedItems` is the single computed source of truth for the table (hidden filter → search filter → sort, with directories always first).

### Connection & auth flow (spans AppModel + PrivateKeyLoader + KnownHosts)

The subtlest path in the app:

1. `AppModel.connect()` → `attemptConnect(host, passphrase: nil)`.
2. `PrivateKeyLoader.authMethod` loads the identity file (ed25519 / rsa only). An encrypted key throws `.needsPassphrase` → `AppModel` shows the passphrase sheet → user submits → retries `attemptConnect` with the passphrase. The passphrase is used only in memory to decrypt; never stored.
3. `KnownHosts.trustedKeys` collects trusted keys for the host into a `KnownHostsValidator` (an `NIOSSHClientServerAuthenticationDelegate`).
4. The validator can only succeed/fail NIO's promise, so it **records its verdict out-of-band** in a lock-guarded `outcome`. After `session.connect` throws, `AppModel` inspects `validator.outcome`:
   - `.unknown` → TOFU alert; on confirm, append the key to `~/.ssh/known_hosts` and reconnect.
   - `.mismatch` → refuse the connection (suspected MITM).
   - `nil` → generic failure (auth/network).

When changing connection logic, preserve this "validator records the verdict, AppModel reads it after the throw" pattern — do not try to recover the reason by parsing the NIO error. `KnownHosts` supports both plaintext and hashed (`|1|`) known_hosts entries; this strict checking (vs. the Python version's auto-accept) is a deliberate security property.

### Transfer pipeline (TransferEngine)

- A user action produces `Request`s (one per selected item; may be a directory). `run()` calls `expand()` to turn each into concrete `FileTask`s (individual files): uploads enumerate the local tree via `FileManager.enumerator`; downloads recurse the remote tree via `session.walkFiles`.
- Tasks run **sequentially** through the single channel. Parent dirs are created on demand (`makeDirectoryRecursive` remote / `createDirectory` local) and memoized in sets to avoid re-`stat`.
- Cancellation is cooperative: `Task.checkCancellation()` between files and inside the 256 KB chunk loops in `SFTPSession.upload`/`download`. `AppModel.cancelTransfer()` cancels `transferTask`.
- Published for the UI: per-file + queue progress, a 500-line-capped `log`, and `lastOutcome` (success / failure / cancelled, each with a fresh id) which drives the auto-fading toast.

### Drag & drop

- Local/Finder → remote pane = **upload**: local rows are `.draggable(URL)`; the remote pane has `.dropDestination(for: URL.self)`.
- Remote → local pane = **download**: remote rows are `.draggable(RemoteItemRef)` (a custom `Transferable`, since remote paths aren't real file URLs); the local pane has `.dropDestination(for: RemoteItemRef.self)`.
- `RemoteItemRef` uses a private UTType `local.shyulatte.sftptransfer.remote-item`, declared in **two places that must stay in sync**: `Models/RemoteItemRef.swift` and the `UTExportedTypeDeclarations` in `make-app.sh`'s Info.plist.

## Conventions & gotchas

- **Citadel is pinned to a specific commit** in `Package.swift` for reproducible builds (not a moving branch); `Package.resolved` is committed.
- **Don't commit `*.app/` or `.build/`** (see `.gitignore`). The built binary embeds the build machine's absolute home path, so the bundle is per-machine and is regenerated locally via `make-app.sh`.
- Public-facing identifiers use `shyulatte` (bundle id `local.shyulatte.sftptransfer`); keep the local macOS username out of committed/published artifacts.
- The macOS-14 minimum is dictated by Citadel (`Package.swift` `platforms`).
