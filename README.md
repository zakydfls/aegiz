# Aegiz

> *“Wait… is this server using Docker, Podman, Kubernetes, or did I SSH into the wrong company again?”*

I work with infrastructure across multiple companies.

Every company has:

- different servers;
- different SSH configs;
- different jump hosts;
- different tunnels;
- different Kubernetes clusters;
- different VPNs;
- and at least one machine named `prod` by someone who enjoys chaos.

Eventually my `~/.ssh/config` stopped looking like configuration and started
looking like an archaeological site.

Apps such as Termius exist. They are good. But putting the map to every server,
credential, and production database in somebody else’s cloud made my remaining
two security neurons file a complaint.

So I did what every sleep-deprived engineer does when a spreadsheet is no
longer enough:

**I accidentally started another side project.**

Welcome to **Aegiz**.

---

## What is Aegiz?

Aegiz is a local-first desktop cockpit for infrastructure work. It collects SSH
hosts, terminal sessions, tunnels, remote files, secrets, databases, containers,
and operational tools in one place—without requiring an Aegiz account or a
hosted control plane.

Your infrastructure metadata stays on your machine. Passwords stay in the
macOS Keychain. Private SSH keys stay exactly where OpenSSH expects them.

No mysterious sync cloud. No “enterprise workspace” pop-up before you can SSH
into your own box. No telemetry trying to determine how often you type `sudo`.

## Why?

Because these questions were becoming part of my daily stand-up:

- “Which production is this?”
- “Why are four hosts called `prod`?”
- “Was this one on port `22`, `2222`, or `2223`?”
- “Does `127.0.0.1` mean my Mac, the jump host, or the destination?”
- “Did I just restart the wrong Redis?”

Infrastructure is stressful enough. Remembering which company invented which
special way to reach it should not be a second job.

## What works today

- SSH inventory imported non-destructively from OpenSSH config;
- embedded libGhostty terminal sessions, splits, and per-host settings;
- local, remote, and SOCKS tunnels with explicit routes and lifecycle cleanup;
- SFTP browsing, preview, upload, download, and guarded mutations;
- PostgreSQL, MySQL, and Redis profiles with responsive result tables;
- passwords stored in local macOS Keychain with optional Touch ID gates;
- Docker and Podman containers, images, connections, logs, and guarded actions;
- workspace/company/environment/tag organization;
- local redacted audit history and encrypted backups.

Kubernetes and AWS are currently under maintenance. They are sitting behind a
small virtual traffic cone until their context and account safety flows are
boring enough to trust.

## Philosophy

- 🔒 Local-first.
- 🚫 No mandatory cloud.
- 🗝️ Secrets belong in the OS credential store.
- 🧯 Dangerous actions must name their target before running.
- ⚡ Fast enough that opening a normal terminal does not become a coffee break.
- 🪦 Hidden child processes should die when their parent dies.

Optional self-hosted synchronization is part of the direction—not permission
to quietly upload anything anywhere.

## Under the hood

```text
Native macOS UI       SwiftUI + AppKit
Terminal renderer     libGhostty / GhosttyKit + Metal
Local control core    Rust + Tokio
IPC                   protobuf/gRPC over a private Unix-domain socket
Inventory             SQLite (WAL, owner-only permissions)
Secrets               macOS Keychain / LocalAuthentication
SSH and transfers     OpenSSH + SFTP
Containers            Docker CLI or Podman CLI
Portable direction    Rust contracts, with a future Tauri shell for other OSes
```

The UI never executes arbitrary strings through a local shell. External tools
are launched as an executable plus validated argument arrays. The core uses a
per-launch authenticated local channel, and managed tunnels have parent-death
cleanup because zombie infrastructure is only funny in movies.

## Repository map

```text
apps/macos/             Native macOS application
crates/aegiz-core/      Local RPC core and operation orchestration
crates/aegiz-domain/    Shared infrastructure domain model
crates/aegiz-storage/   SQLite persistence
crates/aegiz-vault/     Secret-handling primitives
crates/aegiz-platform/  Portable transport and credential contracts
proto/                  Versioned protobuf API
scripts/                Build, package, and fixture helpers
```

## Build it

Requirements: macOS 15+, Xcode command-line tools, Swift 6.1+, Rust, Zig for
GhosttyKit, and a local Apple code-signing identity for the packaged app.

```sh
./scripts/build-ghostty-framework.sh
cargo build --release -p aegiz-core
./scripts/package-macos-app.sh release
open .build/Aegiz.app
```

Create the drag-to-Applications image:

```sh
./scripts/create-macos-dmg.sh
open dist/Aegiz-0.2.0-arm64.dmg
```

Public distribution still needs Developer ID signing and notarization. The
current development signature is intended for the maintainer’s Mac.

## Status

Very much under development.

If you find a bug, please report it. I probably found it too, stared at it for
twenty minutes, and briefly decided it was a feature of distributed systems.

Security issues should be reported privately. Please do not commit credentials,
private keys, database dumps, or local Aegiz application data.

---

Made with too much coffee, too many SSH sessions, and exactly enough frustration
to turn `ssh prod` into a user interface.

Licensed under Apache-2.0.
