# Agentic Claude VM Deployer for Proxmox — Design Spec

**Date:** 2026-06-26
**Status:** Implemented (`agentic-vm.sh`)

A hardened fork of the third-party `agentic.sh` LXC deployer. Goal: run an
automated Claude Code agent on a home Proxmox server that is **securely
separated from the host**, while still being able to run repository test
suites that depend on **Docker** (e.g. Postgres-in-Docker, Dockerfiles). The
primary development language is **Java**.

## Why a VM, not an LXC

The original creates a **privileged** LXC with `AppArmor: unconfined`,
`nesting=1`, and `keyctl=1` so Docker works inside the container. That
configuration effectively removes the container/host security boundary: root
in the container is close to root on the Proxmox host. An automated agent
running arbitrary repo code under that posture can reach the host. Docker in an
**unprivileged** LXC avoids that but is fragile (`fuse-overlayfs` instead of
`overlay2`, idmap/nesting tweaks, breakage on upgrades) and still shares the
host kernel.

**Decision: use a VM.** Hardware virtualization gives a real boundary (separate
guest kernel), and Docker runs natively with `overlay2`, so any repo's
container-based tests work unmodified.

## Requirements

1. Isolated from the Proxmox host (no privileged container; VM boundary).
2. Automated Claude Code runs inside (auto-approved tools, no prompts).
3. Native Docker for repo test suites.
4. Java toolchain by default; other language SDKs added on demand.
5. **No unattended auto-updates** (the real problem with the original's
   Watchtower) — but without freezing the box into a maintenance burden.

## Supply-chain strategy: snapshot + verify (not pinning)

The original's risk was **Watchtower auto-applying mutable `:latest` tags,
unattended, with no review and no rollback.** Version pinning is only one way
to address that (freeze everything) and it carries a real cost: no security
patches and ongoing maintenance. This design instead uses two cheaper,
composable mitigations that the VM decision unlocks:

- **Verify everything downloaded.** GPG-signed apt repos (Ubuntu archive for
  OpenJDK/Maven, Docker), SHA256 verification of the Ubuntu cloud image.
  Verification is orthogonal to
  freezing and always on.
- **Reversible instead of frozen — VM snapshots.** Automatic apt upgrades are
  disabled (`/etc/apt/apt.conf.d/20auto-upgrades` set to `0`/`0`, the
  `apt-daily-upgrade` timer disabled), so nothing changes unattended. To
  update, you snapshot on the host, `apt upgrade` in the guest, and `qm
  rollback` instantly if an update is bad or compromised.

This keeps the box *current* (you can take security patches whenever) while
making every update reviewable and instantly undoable — strictly better than
Watchtower, and lighter than maintaining frozen pins. Project-level dependency
versions (e.g. `pom.xml`) remain the repo's concern (lockfiles / Renovate).

## Architecture

`agentic-vm.sh` runs as root on the Proxmox host:

1. **Preflight** — root + required tools (`qm`, `qemu-img`, `pvesh`, `wget`,
   `curl`, `sha256sum`, `base64`).
2. **Config** — interactive: VM ID/name/cores/RAM/disk/storage/bridge/VLAN,
   network (DHCP or static), DNS, and a **required SSH public key** (password
   auth is disabled, so a key is mandatory and validated).
3. **Image** — download the Ubuntu 26.04 LTS (`resolute`) cloud image,
   **verified against Ubuntu's published `SHA256SUMS`**; cached under
   `/var/lib/vz/template/cloudimg`. 26.04 is chosen because its archive
   packages `openjdk-26-jdk` directly (no third-party JDK repo needed).
4. **Cloud-init** — generate `#cloud-config` user-data that injects the SSH key
   (key-only, `ssh_pwauth: false`) and runs the embedded provisioning script
   once via `runcmd`. Written to the snippets storage and attached via
   `qm set --cicustom`. The script verifies the snippets content type first.
5. **Create VM** — `qm create` (virtio-scsi, `cpu host`, guest agent, serial
   console), import the cloud image as the boot disk
   (`--scsi0 <storage>:0,import-from=...`), resize, attach cloud-init drive,
   set network, start.
6. **Report** — wait for the guest agent and print IP + connect/update info.

## In-guest provisioning (lean)

- Disable automatic apt upgrades; set timezone/locale.
- Core packages: git, common CLI utilities, `ripgrep`/`fd`/`fzf`/`jq`,
  `build-essential`, `qemu-guest-agent`, `postgresql-client`, `sqlite3`.
- **Java**: distro `openjdk-${JDK_MAJOR}-jdk` (default 26) + Maven from
  Ubuntu's own GPG-signed archive — genuine upstream OpenJDK, no third-party
  trust root. `JAVA_HOME` set system-wide via `/etc/environment` and
  `/etc/profile.d/java.sh`.
- **Docker**: official GPG-verified apt repo, native `overlay2`.
- **Claude Code**: native installer; permissive `settings.json` (all tools
  auto-approved — safe because the VM *is* the sandbox boundary).
- Plugins (code-review, commit-commands, security-guidance, context7,
  superpowers) installed best-effort, non-fatal.
- SSH hardened to key-only; `/project` workspace + `CLAUDE.md`.
- On the DHCP path, a netplan drop-in sets `dhcp-identifier: mac` so MAC-based
  router reservations (e.g. Eero) are honored — Ubuntu's netplan otherwise
  sends a DUID-based client-id that breaks them.

No Node/Go/Rust/Python build stack is installed by default — added on demand.

## Security posture

| Concern | Original (LXC) | This design (VM) |
|---|---|---|
| Isolation | Privileged LXC, AppArmor unconfined | **Full VM / hypervisor boundary** |
| Docker | Privileged-container hack | **Native, overlay2** |
| SSH | Root + password auth | **Key-only**, `PermitRootLogin prohibit-password` |
| Web IDE | code-server, root FS mount, pw `admin` | **Removed** |
| Updates | Watchtower + apt cron (automatic) | **Auto-upgrades off; snapshot + verify** |
| Downloads | mixed | **GPG/SHA256-verified repos + image** |
| Claude perms | Auto-approve everything | Auto-approve, **but behind the VM boundary** |

## Residual trust / known trade-offs

- **You apply updates manually.** The flip side of "no unattended upgrades":
  snapshot + `apt upgrade` on your own cadence to take security fixes.
- **`curl | bash` for Claude's installer** can't be cryptographically pinned;
  it's first-party (Anthropic). Docker/Java/image are all verified.
- **Claude plugins/marketplaces** are fetched once from upstream GitHub at
  provision time and not auto-updated thereafter.
- **OpenJDK 26** comes from Ubuntu 26.04's `universe` archive
  (`openjdk-26-jdk`, verified `26.0.1+8-2~26.04.2` at design time). Changing
  `JDK_MAJOR` requires that version to be packaged for the chosen release.
- **`import-from` disk syntax** requires Proxmox VE 8.x.
- Network placement (VLAN/firewall/egress) is left to the operator; a VLAN tag
  field is provided as a hook.

## Out of scope (YAGNI)

code-server, Watchtower, per-tool version pinning + `update-stack.sh`, Node/Go/
Rust defaults, Playwright, agent-teams flag, remote control, and the weekly
auto-update cron from the original are intentionally dropped.
