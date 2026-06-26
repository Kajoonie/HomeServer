#!/usr/bin/env bash
# ============================================================================
# Agentic Claude VM Deployer for Proxmox  (hardened fork)
# ----------------------------------------------------------------------------
# Creates an isolated Ubuntu 26.04 LTS *VM* (not an LXC) ready for automated
# Claude Code, with a native Docker engine for repo test suites and a Java
# (OpenJDK) toolchain.
#
# WHY A VM INSTEAD OF AN LXC:
#   The original LXC script needed a *privileged* container with AppArmor
#   unconfined to run Docker — which effectively removes the container/host
#   security boundary. Automated Claude running arbitrary repo code with that
#   posture can reach the Proxmox host. A VM gives a hardware-virtualization
#   boundary (separate guest kernel) AND lets Docker run natively with the
#   normal overlay2 driver, so test suites that spin up Postgres-in-Docker or
#   build Dockerfiles "just work".
#
# SECURITY POSTURE:
#   - Full VM isolation from the host (no privileged container).
#   - SSH key authentication only; root password login disabled.
#   - No code-server / web IDE exposed.
#   - SUPPLY CHAIN: instead of Watchtower's unattended auto-apply of mutable
#     :latest tags, this box uses "snapshot + verify":
#       * everything downloaded is verified (GPG-signed apt repos, SHA256 on
#         the cloud image);
#       * automatic apt upgrades are DISABLED — you update deliberately;
#       * because it's a VM, you snapshot before updating and roll back
#         instantly if an update is bad. See print_summary / SPEC.md.
#   - Claude Code remains auto-approved (no prompts) INSIDE the VM — that is
#     the point of an agentic sandbox — but it is now sealed behind the
#     hypervisor boundary instead of sitting on the host kernel.
#
# Run on your Proxmox host as root:
#   bash agentic-vm.sh
# ============================================================================

set -euo pipefail

# ── Colors & Helpers ────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

info()    { echo -e "${CYAN}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[OK]${NC} $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

header() {
  echo ""
  echo -e "${BOLD}╔══════════════════════════════════════════════════╗${NC}"
  echo -e "${BOLD}║      Agentic Claude VM Deployer (Proxmox)        ║${NC}"
  echo -e "${BOLD}║      isolated · key-only · snapshot-based        ║${NC}"
  echo -e "${BOLD}╚══════════════════════════════════════════════════╝${NC}"
  echo ""
}

# ── Base image (Ubuntu 26.04 LTS cloud image) ───────────────────────────────
# 26.04 LTS so the distro itself packages openjdk-26 (no third-party JDK repo).
# Override UBUNTU_CODENAME via env for a different release.
UBUNTU_CODENAME="${UBUNTU_CODENAME:-resolute}"  # resolute = 26.04 LTS
IMAGE_NAME="${UBUNTU_CODENAME}-server-cloudimg-amd64.img"
IMAGE_BASE_URL="https://cloud-images.ubuntu.com/${UBUNTU_CODENAME}/current"
IMAGE_URL="${IMAGE_BASE_URL}/${IMAGE_NAME}"
CHECKSUM_URL="${IMAGE_BASE_URL}/SHA256SUMS"
IMG_CACHE="/var/lib/vz/template/cloudimg"

# Snippets (cloud-init custom user-data). Uses the 'local' dir storage by
# default; the directory below must have the "snippets" content type enabled
# (Datacenter > Storage > local > Content > Snippets).
SNIPPET_STORAGE="${SNIPPET_STORAGE:-local}"
SNIPPET_DIR="${SNIPPET_DIR:-/var/lib/vz/snippets}"

# ── Pre-flight checks ──────────────────────────────────────────────────────
preflight() {
  [[ $(id -u) -eq 0 ]] || error "This script must be run as root on the Proxmox host."
  local c
  for c in qm qemu-img pvesh wget curl sha256sum base64; do
    command -v "$c" &>/dev/null || error "'$c' not found. Are you on a Proxmox host with standard tooling?"
  done
}

# ── Configuration ───────────────────────────────────────────────────────────
get_config() {
  local next_id
  next_id=$(pvesh get /cluster/nextid 2>/dev/null || echo "100")

  echo -e "${BOLD}VM Configuration${NC}"
  echo "─────────────────────────────────────────────────"

  read -rp "VM ID [$next_id]: " VMID
  VMID="${VMID:-$next_id}"
  [[ "$VMID" =~ ^[0-9]+$ ]] || error "VM ID must be a number."
  qm status "$VMID" &>/dev/null && error "VM ID $VMID already exists."

  read -rp "VM name [claude-agent]: " VM_NAME
  VM_NAME="${VM_NAME:-claude-agent}"

  read -rp "CPU cores [4]: " VM_CORES
  VM_CORES="${VM_CORES:-4}"

  read -rp "RAM in MB [8192]: " VM_RAM
  VM_RAM="${VM_RAM:-8192}"

  read -rp "Disk size in GB [40]: " VM_DISK
  VM_DISK="${VM_DISK:-40}"

  read -rp "Storage (for VM disk + cloud-init) [local-lvm]: " VM_STORAGE
  VM_STORAGE="${VM_STORAGE:-local-lvm}"

  read -rp "Bridge [vmbr0]: " VM_BRIDGE
  VM_BRIDGE="${VM_BRIDGE:-vmbr0}"

  # Optional VLAN tag for network isolation (blank = untagged).
  read -rp "VLAN tag (optional, blank for none): " VM_VLAN

  read -rp "IP address (dhcp or x.x.x.x/xx) [dhcp]: " VM_IP
  VM_IP="${VM_IP:-dhcp}"
  if [[ "$VM_IP" != "dhcp" ]]; then
    read -rp "Gateway: " VM_GW
    [[ -n "$VM_GW" ]] || error "Gateway is required for a static IP."
  fi

  read -rp "DNS server [1.1.1.1]: " VM_DNS
  VM_DNS="${VM_DNS:-1.1.1.1}"

  # SSH key is REQUIRED — password auth is disabled by design.
  while :; do
    read -rp "Path to SSH PUBLIC key (required): " SSH_KEY_PATH
    SSH_KEY_PATH="${SSH_KEY_PATH/#\~/$HOME}"
    if [[ -z "$SSH_KEY_PATH" ]]; then
      warn "An SSH public key is required (root password login is disabled)."
    elif [[ ! -f "$SSH_KEY_PATH" ]]; then
      warn "File not found: $SSH_KEY_PATH"
    elif ! grep -qE '^(ssh-(rsa|ed25519|dss)|ecdsa-|sk-)' "$SSH_KEY_PATH"; then
      warn "That doesn't look like an SSH public key. Point me at the .pub file."
    else
      SSH_KEY_CONTENT="$(< "$SSH_KEY_PATH")"
      break
    fi
  done

  echo ""
  echo -e "${BOLD}Summary${NC}"
  echo "─────────────────────────────────────────────────"
  echo "  VM ID:    $VMID"
  echo "  Name:     $VM_NAME"
  echo "  Image:    $IMAGE_NAME (checksum-verified)"
  echo "  CPU:      $VM_CORES cores"
  echo "  RAM:      $VM_RAM MB"
  echo "  Disk:     ${VM_DISK}G on $VM_STORAGE"
  echo "  Bridge:   $VM_BRIDGE${VM_VLAN:+ (VLAN $VM_VLAN)}"
  echo "  Network:  $VM_IP"
  echo "  DNS:      $VM_DNS"
  echo "  SSH key:  $SSH_KEY_PATH (key-only login, no password)"
  echo "─────────────────────────────────────────────────"
  echo ""
  read -rp "Proceed? (y/N): " confirm
  [[ "$confirm" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }
}

# ── Download + verify the Ubuntu cloud image ───────────────────────────────
get_image() {
  mkdir -p "$IMG_CACHE"
  IMG_PATH="$IMG_CACHE/$IMAGE_NAME"

  info "Fetching published checksums..."
  local sums="$IMG_CACHE/SHA256SUMS.${UBUNTU_CODENAME}"
  wget -q -O "$sums" "$CHECKSUM_URL" || error "Could not download SHA256SUMS from $CHECKSUM_URL"

  if [[ -f "$IMG_PATH" ]]; then
    info "Cloud image already cached; verifying checksum..."
  else
    info "Downloading $IMAGE_NAME (~600MB)..."
    wget -q --show-progress -O "$IMG_PATH" "$IMAGE_URL" || error "Image download failed."
  fi

  info "Verifying image checksum against Ubuntu's published SHA256SUMS..."
  local expected
  expected=$(grep " \*\?${IMAGE_NAME}\$" "$sums" | awk '{print $1}' | head -n1)
  [[ -n "$expected" ]] || error "Could not find $IMAGE_NAME in SHA256SUMS."
  local actual
  actual=$(sha256sum "$IMG_PATH" | awk '{print $1}')
  if [[ "$expected" != "$actual" ]]; then
    rm -f "$IMG_PATH"
    error "Checksum MISMATCH for $IMAGE_NAME (deleted). Re-run to re-download.
       expected: $expected
       actual:   $actual"
  fi
  success "Image verified: $IMAGE_NAME"
}

# ── Build cloud-init user-data (with the embedded provisioning script) ──────
build_cloudinit() {
  info "Building cloud-init user-data + provisioning payload..."

  # The snippet storage MUST have the "snippets" content type enabled, or
  # 'qm start' later fails with an opaque error. Check early and explain.
  if ! pvesh get "/storage/${SNIPPET_STORAGE}" --output-format json 2>/dev/null \
        | grep -qw 'snippets'; then
    error "Storage '${SNIPPET_STORAGE}' does not have the 'snippets' content type enabled.
       Enable it in: Datacenter > Storage > ${SNIPPET_STORAGE} > Edit > Content > Snippets
       (or:  pvesm set ${SNIPPET_STORAGE} --content snippets,<existing-content-types>)"
  fi

  mkdir -p "$SNIPPET_DIR"

  local prov_file; prov_file="$(mktemp)"
  write_provision_script "$prov_file"
  local prov_b64; prov_b64="$(base64 -w0 "$prov_file")"
  rm -f "$prov_file"

  USERDATA_FILE="$SNIPPET_DIR/${VMID}-agentic-user-data.yaml"
  # Indent the SSH key for the YAML list item.
  local key_line="      - ${SSH_KEY_CONTENT}"

  cat > "$USERDATA_FILE" <<EOF
#cloud-config
hostname: ${VM_NAME}
preserve_hostname: false
# Key-only login. No password auth anywhere.
ssh_pwauth: false
disable_root: false
users:
  - name: root
    lock_passwd: true
    ssh_authorized_keys:
${key_line}
write_files:
  - path: /usr/local/sbin/agentic-provision.sh
    permissions: '0750'
    owner: root:root
    encoding: b64
    content: ${prov_b64}
runcmd:
  - [ bash, /usr/local/sbin/agentic-provision.sh ]
EOF

  success "Cloud-init written: $USERDATA_FILE"
}

# ── Create + start the VM ──────────────────────────────────────────────────
create_vm() {
  info "Creating VM $VMID..."

  local net="virtio,bridge=${VM_BRIDGE}"
  [[ -n "${VM_VLAN:-}" ]] && net+=",tag=${VM_VLAN}"

  qm create "$VMID" \
    --name "$VM_NAME" \
    --cores "$VM_CORES" \
    --memory "$VM_RAM" \
    --cpu host \
    --net0 "$net" \
    --scsihw virtio-scsi-pci \
    --ostype l26 \
    --agent enabled=1 \
    --serial0 socket --vga serial0 \
    --onboot 1

  info "Importing + attaching the cloud image as the boot disk..."
  qm set "$VMID" --scsi0 "${VM_STORAGE}:0,import-from=${IMG_PATH}" >/dev/null
  qm set "$VMID" --boot order=scsi0 >/dev/null
  qm disk resize "$VMID" scsi0 "${VM_DISK}G" >/dev/null

  info "Attaching cloud-init drive + network config..."
  qm set "$VMID" --ide2 "${VM_STORAGE}:cloudinit" >/dev/null
  if [[ "$VM_IP" == "dhcp" ]]; then
    qm set "$VMID" --ipconfig0 "ip=dhcp" >/dev/null
  else
    qm set "$VMID" --ipconfig0 "ip=${VM_IP},gw=${VM_GW}" >/dev/null
  fi
  qm set "$VMID" --nameserver "$VM_DNS" >/dev/null
  qm set "$VMID" --cicustom "user=${SNIPPET_STORAGE}:snippets/$(basename "$USERDATA_FILE")" >/dev/null

  success "VM $VMID created."

  info "Starting VM $VMID (cloud-init provisioning runs on first boot)..."
  qm start "$VMID"
}

# ── Wait for guest agent + report IP ───────────────────────────────────────
wait_for_ip() {
  info "Waiting for the guest agent (provisioning takes several minutes)..."
  local attempts=0 ip=""
  while (( attempts < 150 )); do
    ip=$(qm guest cmd "$VMID" network-get-interfaces 2>/dev/null \
          | grep -oE '"ip-address" : "[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+"' \
          | grep -vE '127\.0\.0\.1' | head -n1 \
          | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' || true)
    [[ -n "$ip" ]] && { VM_REPORTED_IP="$ip"; return 0; }
    ((attempts++)); sleep 4
  done
  VM_REPORTED_IP=""
}

# ── Summary ────────────────────────────────────────────────────────────────
print_summary() {
  echo ""
  echo -e "${GREEN}${BOLD}╔══════════════════════════════════════════════════╗${NC}"
  echo -e "${GREEN}${BOLD}║            Agentic Claude VM created!            ║${NC}"
  echo -e "${GREEN}${BOLD}╚══════════════════════════════════════════════════╝${NC}"
  echo ""
  echo -e "  ${BOLD}VM:${NC}        $VMID ($VM_NAME)"
  echo -e "  ${BOLD}IP:${NC}        ${VM_REPORTED_IP:-pending (check 'qm guest cmd $VMID network-get-interfaces')}"
  echo -e "  ${BOLD}Resources:${NC} ${VM_CORES} vCPU / $(( VM_RAM / 1024 )) GB RAM / ${VM_DISK} GB disk"
  echo ""
  echo -e "  ${BOLD}Connect (key-only, no password):${NC}"
  echo -e "    Console: ${CYAN}qm terminal $VMID${NC}   (Ctrl-O to exit)"
  [[ -n "${VM_REPORTED_IP:-}" ]] && echo -e "    SSH:     ${CYAN}ssh root@${VM_REPORTED_IP}${NC}"
  echo ""
  echo -e "  ${BOLD}NOTE:${NC} cloud-init is still installing the stack on first boot."
  echo -e "        Watch it with:  ${CYAN}qm terminal $VMID${NC}  then  ${CYAN}cloud-init status --wait${NC}"
  echo ""
  echo -e "  ${BOLD}Start Claude:${NC}  ${CYAN}claude${NC}   (shell auto-cd's to /project)"
  echo ""
  echo -e "  ${BOLD}Installed:${NC} OpenJDK 26 + Maven · Docker (native) · git · Claude Code"
  echo -e "             ripgrep/fd/fzf/jq · psql client.  Other language SDKs: add as needed."
  echo ""
  echo -e "  ${BOLD}Updating safely (snapshot + verify — nothing auto-updates):${NC}"
  echo -e "    1. Snapshot first:  ${CYAN}qm snapshot $VMID preupdate${NC}"
  echo -e "    2. Update in guest: ${CYAN}ssh root@<ip> 'apt-get update && apt-get upgrade -y'${NC}"
  echo -e "    3. If something broke: ${CYAN}qm rollback $VMID preupdate${NC}"
  echo ""
  echo -e "  ${BOLD}Isolation:${NC} full VM boundary · key-only SSH · no code-server · auto-upgrades off"
  echo ""
}

# ============================================================================
# write_provision_script <outfile>
#   Emits the in-guest provisioning script. Runs ONCE via cloud-init runcmd.
#   No version pinning: this box uses snapshot-before-update + verified repos.
# ============================================================================
write_provision_script() {
  cat > "$1" <<'PROVISION_EOF'
#!/bin/bash
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

# ── Knobs (change as you like; not "pins" — just defaults) ──────────────────
JDK_MAJOR="26"   # OpenJDK major version (distro package openjdk-${JDK_MAJOR}-jdk)

log() { echo ">>> $*"; }

log "Timezone -> America/New_York..."
ln -sf /usr/share/zoneinfo/America/New_York /etc/localtime
echo "America/New_York" > /etc/timezone

log "Disabling AUTOMATIC apt upgrades (manual + snapshot workflow)..."
# Updates are deliberate: snapshot on the host, then apt upgrade. Nothing
# upgrades unattended. (apt itself still works normally when YOU run it.)
cat > /etc/apt/apt.conf.d/20auto-upgrades <<'AUTO'
APT::Periodic::Update-Package-Lists "0";
APT::Periodic::Unattended-Upgrade "0";
AUTO
systemctl disable --now apt-daily-upgrade.timer 2>/dev/null || true

log "apt update + locale..."
apt-get update -qq
apt-get install -y -qq locales
sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen
locale-gen en_US.UTF-8 >/dev/null 2>&1
update-locale LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8
export LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8

log "Installing core packages (lean)..."
apt-get install -y -qq \
  git curl wget unzip zip ca-certificates gnupg lsb-release \
  bash-completion htop nano vim tmux \
  jq tree net-tools iproute2 iputils-ping dnsutils \
  openssh-server qemu-guest-agent build-essential \
  ripgrep fd-find fzf rsync sqlite3 postgresql-client
systemctl enable --now qemu-guest-agent 2>/dev/null || true

# ── Java: distro OpenJDK + Maven (apt-signed; no third-party repo) ──────────
# Ubuntu 26.04 packages openjdk-26 directly, so this is genuine upstream
# OpenJDK from the distro's own GPG-signed archive — no extra trust root.
log "Installing OpenJDK ${JDK_MAJOR} + Maven (distro packages)..."
apt-get install -y -qq "openjdk-${JDK_MAJOR}-jdk" maven
JAVA_HOME_PATH="/usr/lib/jvm/java-${JDK_MAJOR}-openjdk-amd64"
# Make JAVA_HOME available to all sessions (incl. Claude's non-login shells).
echo "JAVA_HOME=${JAVA_HOME_PATH}" >> /etc/environment
echo "export JAVA_HOME=${JAVA_HOME_PATH}" > /etc/profile.d/java.sh
echo "    $(java -version 2>&1 | head -1)"
echo "    $(mvn -version 2>/dev/null | head -1 || echo 'maven installed')"

# ── Docker (official repo, GPG-verified; native overlay2) ──────────────────
log "Installing Docker (native)..."
install -m0755 -d /etc/apt/keyrings
. /etc/os-release
curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu ${VERSION_CODENAME} stable" \
  > /etc/apt/sources.list.d/docker.list
apt-get update -qq
apt-get install -y -qq docker-ce docker-ce-cli containerd.io \
  docker-buildx-plugin docker-compose-plugin
systemctl enable --now docker
echo "    $(docker --version)"

# ── Claude Code (native installer) ─────────────────────────────────────────
log "Installing Claude Code (native installer)..."
curl -fsSL https://claude.ai/install.sh | bash
if [[ -f "$HOME/.local/bin/claude" ]]; then
  ln -sf "$HOME/.local/bin/claude" /usr/local/bin/claude 2>/dev/null || true
elif [[ -f "$HOME/.claude/bin/claude" ]]; then
  ln -sf "$HOME/.claude/bin/claude" /usr/local/bin/claude 2>/dev/null || true
fi
CLAUDE_BIN="$(command -v claude || echo /usr/local/bin/claude)"
echo "    Claude Code: $("$CLAUDE_BIN" --version 2>/dev/null || echo 'version unknown')"

# ── Claude settings (auto-approved INSIDE the VM) ──────────────────────────
log "Writing Claude Code settings..."
mkdir -p /root/.claude
cat > /root/.claude/settings.json <<'SETTINGS'
{
  "$schema": "https://json.schemastore.org/claude-code-settings.json",
  "permissions": {
    "allow": [
      "Bash(*)", "Read(*)", "Write(*)", "Edit(*)", "MultiEdit(*)",
      "WebFetch(*)", "WebSearch(*)", "TodoRead(*)", "TodoWrite(*)",
      "Grep(*)", "Glob(*)", "LS(*)", "Task(*)", "mcp__*"
    ]
  },
  "env": {
    "CLAUDE_CODE_MAX_OUTPUT_TOKENS": "64000",
    "MAX_THINKING_TOKENS": "31999"
  },
  "alwaysThinkingEnabled": true
}
SETTINGS

# ── Claude plugins (best-effort; fetched once at build, not auto-updated) ────
log "Adding plugin marketplaces + installing plugins (non-fatal)..."
"$CLAUDE_BIN" plugin marketplace add anthropics/claude-plugins-official 2>/dev/null || echo "    [WARN] marketplace add failed"
"$CLAUDE_BIN" plugin marketplace add obra/superpowers-marketplace 2>/dev/null || echo "    [WARN] superpowers marketplace add failed"
install_plugin() {
  "$CLAUDE_BIN" plugin install "${1}@claude-plugins-official" 2>/dev/null \
    && echo "    installed $1" || echo "    [WARN] could not install $1"
}
install_plugin code-review
install_plugin commit-commands
install_plugin security-guidance
install_plugin context7
"$CLAUDE_BIN" plugin install superpowers@superpowers-marketplace 2>/dev/null \
  && echo "    installed superpowers" || echo "    [WARN] could not install superpowers"

# ── /project workspace + CLAUDE.md ─────────────────────────────────────────
log "Setting up /project workspace..."
mkdir -p /project
cat > /project/CLAUDE.md <<'CLAUDEMD'
# Claude Code Workspace (isolated VM)

## Environment
- **Host type**: Ubuntu 26.04 LTS **VM** on Proxmox (hardware-isolated from host)
- **Working directory**: /project
- **Timezone**: America/New_York
- **User**: root (key-only SSH; password login disabled)

## Tools
- **Java**: OpenJDK 26 + Maven (`java`, `mvn`; `JAVA_HOME` is set system-wide).
  Use the project's `./mvnw` / `./gradlew` wrapper when present.
- **Docker**: native engine (overlay2). `docker build`, `docker compose`, and
  test containers (e.g. Postgres) work normally.
- ripgrep (rg), fd-find (fdfind), fzf, jq, sqlite3, psql.
- Other language SDKs (Node, Go, Python tooling, etc.) are NOT preinstalled —
  add them when a project needs them.

## Updates (IMPORTANT)
No Watchtower, no auto-updates. Update deliberately:
1. On the Proxmox host: `qm snapshot <vmid> preupdate`
2. In this VM: `apt-get update && apt-get upgrade -y`
3. If anything breaks: `qm rollback <vmid> preupdate`

## Permissions
All tools are pre-approved (no prompts) — safe because this whole VM is the
sandbox boundary. Do NOT weaken the VM/host isolation.

## Conventions
- Prefer creating files over printing long code blocks
- Use git for version control on projects under /project
CLAUDEMD

# ── SSH hardening (belt-and-suspenders; cloud-init already set key-only) ────
log "Hardening SSH (key-only)..."
sed -i 's/^#*PermitRootLogin.*/PermitRootLogin prohibit-password/' /etc/ssh/sshd_config
sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
mkdir -p /etc/ssh/sshd_config.d
printf 'PasswordAuthentication no\nPermitRootLogin prohibit-password\n' \
  > /etc/ssh/sshd_config.d/00-agentic-hardening.conf
systemctl enable ssh 2>/dev/null || systemctl enable sshd 2>/dev/null || true
systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null || true

# ── Shell environment ──────────────────────────────────────────────────────
log "Shell environment..."
cat >> /root/.bashrc <<'BASHRC'

# ── Agentic Claude VM ──────────────────────────────────────
export EDITOR=nano
export LANG=en_US.UTF-8
export TZ=America/New_York
# JAVA_HOME is set system-wide via /etc/environment + /etc/profile.d/java.sh
export PATH="$HOME/.local/bin:$HOME/.claude/bin:$PATH"
alias ll="ls -lah --color=auto"
alias gs="git status"
alias gl="git log --oneline -20"
alias dc="docker compose"
alias dps="docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'"
cd /project 2>/dev/null || true
BASHRC

log "Git defaults..."
git config --global init.defaultBranch main
git config --global core.editor nano
git config --global pull.rebase false

log "Cleanup..."
apt-get autoremove -y -qq && apt-get clean -qq

echo ""
echo "╔══════════════════════════════════════════════════╗"
echo "║            Provisioning Complete!                ║"
echo "╚══════════════════════════════════════════════════╝"
PROVISION_EOF
}

# ── Main ──────────────────────────────────────────────────────────────────
main() {
  header
  preflight
  get_config
  get_image
  build_cloudinit
  create_vm
  wait_for_ip
  print_summary
}

main "$@"
