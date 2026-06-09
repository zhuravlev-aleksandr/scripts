#!/usr/bin/env bash
# create_bastion_template.sh — Download a cloud image, customise it, and import as a Proxmox template
#
# Usage:
#   ./create_bastion_template.sh [options]
#
# Options:
#   -u URL        Cloud image URL (default: Debian 13 genericcloud amd64)
#   -i VMID       Template VM ID (default: 9000)
#   -s STORAGE    Proxmox storage pool (default: local-lvm)
#   -d DIR        Working directory for image download (default: /tmp)
#   -k FILE       SSH public keys file (default: ~/.ssh/authorized_keys)
#   -h            Show this help
#
# Examples:
#   ./create_bastion_template.sh
#   ./create_bastion_template.sh -i 9001 -s local-lvm
#   ./create_bastion_template.sh -u https://example.com/custom.qcow2 -i 9002

set -euo pipefail

# ── Defaults ──────────────────────────────────────────────────────────────────

DEFAULT_URL="https://cloud.debian.org/images/cloud/trixie/latest/debian-13-genericcloud-amd64.qcow2"
DEFAULT_VMID=9001
DEFAULT_STORAGE="local-lvm"
DEFAULT_WORKDIR="/tmp"
DEFAULT_SSHKEYS="$HOME/.ssh/authorized_keys"

# ── Colours ───────────────────────────────────────────────────────────────────

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log()  { echo -e "${CYAN}==>${NC} $*"; }
ok()   { echo -e "${GREEN}  ✓${NC} $*"; }
warn() { echo -e "${YELLOW}  ⚠${NC} $*"; }
die()  { echo -e "${RED}  ✗ ERROR:${NC} $*" >&2; exit 1; }

# ── Usage ─────────────────────────────────────────────────────────────────────

usage() {
  grep '^#' "$0" | grep -v '#!/' | sed 's/^# \{0,1\}//'
  exit 0
}

# ── Argument parsing ──────────────────────────────────────────────────────────

IMAGE_URL="$DEFAULT_URL"
VMID="$DEFAULT_VMID"
STORAGE="$DEFAULT_STORAGE"
WORKDIR="$DEFAULT_WORKDIR"
SSHKEYS="$DEFAULT_SSHKEYS"

while getopts "u:i:s:d:k:h" opt; do
  case $opt in
    u) IMAGE_URL="$OPTARG" ;;
    i) VMID="$OPTARG" ;;
    s) STORAGE="$OPTARG" ;;
    d) WORKDIR="$OPTARG" ;;
    k) SSHKEYS="$OPTARG" ;;
    h) usage ;;
    *) die "Unknown option. Use -h for help." ;;
  esac
done

# Derive image filename and template name from URL
IMAGE_FILE="${IMAGE_URL##*/}"           # debian-13-genericcloud-amd64.qcow2
TEMPLATE_NAME="${IMAGE_FILE%.qcow2}"   # debian-13-genericcloud-amd64
IMAGE_PATH="${WORKDIR}/${IMAGE_FILE}"

# ── Preflight checks ──────────────────────────────────────────────────────────

preflight() {
  log "Running preflight checks"

  [[ $EUID -eq 0 ]] || die "This script must be run as root."

  for cmd in qm wget virt-customize virt-sysprep; do
    command -v "$cmd" &>/dev/null || die "'$cmd' not found. Install libguestfs-tools and ensure qm is in PATH."
  done

  [[ -f "$SSHKEYS" ]] || die "SSH keys file not found: ${SSHKEYS}. Use -k to specify a different path."

  ok "All required tools present"
}

# ── Template existence check ──────────────────────────────────────────────────

template_exists() {
  local vmid="$1"
  if qm status "$vmid" &>/dev/null; then
    local config
    config=$(qm config "$vmid" 2>/dev/null)
    if echo "$config" | grep -q "^template: 1"; then
      return 0   # exists and is a template
    else
      die "VMID ${vmid} already exists but is NOT a template. Remove it first: qm destroy ${vmid} --purge"
    fi
  fi
  return 1   # does not exist
}

# ── Download ──────────────────────────────────────────────────────────────────

download_image() {
  log "Downloading cloud image"
  echo "  URL:  $IMAGE_URL"
  echo "  Dest: $IMAGE_PATH"

  if [[ -f "$IMAGE_PATH" ]]; then
    warn "Image already exists at ${IMAGE_PATH} — skipping download."
    warn "Delete it manually to force a fresh download."
  else
    wget --show-progress -q -O "$IMAGE_PATH" "$IMAGE_URL" \
      || die "Download failed."
    ok "Downloaded ${IMAGE_FILE}"
  fi
}

# ── Customise ─────────────────────────────────────────────────────────────────

customise_image() {
  log "Switching apt sources to HTTPS"
  virt-customize -a "$IMAGE_PATH" \
    --run-command 'sed -i "s|http://|https://|g" /etc/apt/sources.list /etc/apt/sources.list.d/*.list /etc/apt/sources.list.d/*.sources 2>/dev/null || true'
  ok "apt sources rewritten to HTTPS"

  log "Installing packages into image"
  virt-customize -a "$IMAGE_PATH" \
    --install apt-transport-https,qemu-guest-agent \
    --run-command 'systemctl enable qemu-guest-agent'
  ok "packages installed and enabled"

  log "Disabling IPv6 at kernel level"
  # Append ipv6.disable=1 to the existing GRUB_CMDLINE_LINUX_DEFAULT using a
  # capture group (no '&', which grub-mkconfig would choke on). If the line is
  # missing entirely, create it.
  virt-customize -a "$IMAGE_PATH" \
    --run-command 'if grep -q "^GRUB_CMDLINE_LINUX_DEFAULT=" /etc/default/grub; then sed -i "s/^\(GRUB_CMDLINE_LINUX_DEFAULT=\"[^\"]*\)\"/\1 ipv6.disable=1\"/" /etc/default/grub; else echo "GRUB_CMDLINE_LINUX_DEFAULT=\"ipv6.disable=1\"" >> /etc/default/grub; fi' \
    --run-command 'update-grub'
  ok "IPv6 disabled via kernel cmdline"

  log "Generalising image with virt-sysprep"
  virt-sysprep -a "$IMAGE_PATH"
  ok "virt-sysprep complete"

  log "Truncating machine-id"
  virt-customize -a "$IMAGE_PATH" --truncate /etc/machine-id
  ok "machine-id truncated"
}

# ── Import and template ───────────────────────────────────────────────────────

import_template() {
  log "Creating VM ${VMID} (${TEMPLATE_NAME})"
  qm create "$VMID" \
    --name "$TEMPLATE_NAME" \
    --memory 1024 \
    --balloon 0 \
    --cores 1 \
    --cpu host \
    --machine q35 \
    --bios ovmf \
    --efidisk0 "${STORAGE}:0,efitype=4m,pre-enrolled-keys=0" \
    --net0 virtio,bridge=vmbr0 \
    --net1 virtio \
    --ostype l26 \
    --agent enabled=1 \
    --serial0 socket \
    --vga serial0 \
    --scsihw virtio-scsi-single
  ok "VM created"

  log "Importing disk to ${STORAGE}"
  qm importdisk "$VMID" "$IMAGE_PATH" "$STORAGE"
  ok "Disk imported"

  log "Attaching disk and drives"
  qm set "$VMID" --scsi0 "${STORAGE}:vm-${VMID}-disk-1,discard=on,ssd=1,iothread=1"
  qm set "$VMID" --ide2 "${STORAGE}:cloudinit"
  qm set "$VMID" --boot order=scsi0
  ok "Disk and cloud-init drive attached"

  log "Setting cloud-init defaults"
  qm set "$VMID" \
    --ciuser debian \
    --sshkeys "$SSHKEYS" \
    --ipconfig0 ip=dhcp \
    --ipconfig1 ip=dhcp
  ok "Cloud-init defaults set"

  log "Converting VM ${VMID} to template"
  qm template "$VMID"
  ok "Template created: ${TEMPLATE_NAME} (VMID ${VMID})"
}

# ── Cleanup ───────────────────────────────────────────────────────────────────

cleanup_image() {
  log "Removing local image file"
  rm -f "$IMAGE_PATH"
  ok "Removed ${IMAGE_PATH}"
}

# ── Main ──────────────────────────────────────────────────────────────────────

main() {
  echo ""
  echo -e "${CYAN}Proxmox Cloud Image Template Builder${NC}"
  echo "  Image:    $IMAGE_URL"
  echo "  VMID:     $VMID"
  echo "  Name:     $TEMPLATE_NAME"
  echo "  Storage:  $STORAGE"
  echo "  SSH keys: $SSHKEYS"
  echo "  Workdir:  $WORKDIR"
  echo ""

  preflight

  if template_exists "$VMID"; then
    warn "Template VMID ${VMID} ($(qm config "$VMID" | grep '^name:' | awk '{print $2}')) already exists — nothing to do."
    exit 0
  fi

  download_image
  customise_image
  import_template
  cleanup_image

  echo ""
  ok "Done. Clone with: qm clone ${VMID} <new-vmid> --name <hostname> --full"
  echo ""
}

main
