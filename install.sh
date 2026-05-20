#!/usr/bin/env bash
# =============================================================================
#  Artix Linux Custom Installer  ·  Phase 1: Pre-Chroot
#  Run from the Artix base ISO as root:
#    git clone <your-repo> && cd artix-install && bash install.sh
# =============================================================================
set -uo pipefail

# ── Colors ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

info()    { echo -e "${CYAN}${BOLD}  ➤  ${NC}$*"; }
ok()      { echo -e "${GREEN}${BOLD}  ✔  ${NC}$*"; }
warn()    { echo -e "${YELLOW}${BOLD}  ⚠  ${NC}$*"; }
err()     { echo -e "${RED}${BOLD}  ✘  ${NC}$*"; exit 1; }
ask()     { echo -e "${BLUE}${BOLD}  ?  ${NC}$*"; }
section() { echo -e "\n${BOLD}${CYAN}══  $*  ══${NC}\n"; }

# ── Banner ────────────────────────────────────────────────────────────────────
banner() {
    clear
    echo -e "${CYAN}${BOLD}"
    cat << 'BANNER'
  ╔═══════════════════════════════════════════════════════╗
  ║           A R T I X   L I N U X                      ║
  ║              Custom  Installer                        ║
  ║      rEFInd · AUR · DMS · yay · UEFI-only            ║
  ╚═══════════════════════════════════════════════════════╝
BANNER
    echo -e "${NC}"
}

# ── Preflight ─────────────────────────────────────────────────────────────────
preflight() {
    section "Preflight Checks"

    [[ $EUID -ne 0 ]] && err "Run this script as root."

    [[ ! -d /sys/firmware/efi/efivars ]] \
        && err "Not booted in UEFI mode. This installer is UEFI-only (rEFInd)."
    ok "UEFI detected."

    if ! ping -c 1 -W 4 1.1.1.1 &>/dev/null; then
        err "No internet. Connect first (ip link / iwctl) and retry."
    fi
    ok "Internet OK."

    # Ensure essential tools are available
    local missing=()
    for t in sgdisk mkfs.fat mkfs.ext4 mkfs.btrfs basestrap fstabgen artix-chroot; do
        command -v "$t" &>/dev/null || missing+=("$t")
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        info "Installing missing tools: ${missing[*]}"
        pacman -Sy --noconfirm gptfdisk dosfstools btrfs-progs 2>/dev/null || true
    fi

    # Sync system clock
    timedatectl set-ntp true 2>/dev/null || true
    ok "Preflight complete."
}

# ── Disk selection ────────────────────────────────────────────────────────────
select_disk() {
    section "Disk Selection"
    warn "ALL data on the chosen disk will be permanently destroyed."
    echo
    lsblk -d -o NAME,SIZE,MODEL,TYPE | grep disk
    echo
    ask "Enter disk name (e.g.  sda  nvme0n1  vda):"
    read -rp "  > " DISK_NAME
    DISK="/dev/${DISK_NAME}"
    [[ ! -b "$DISK" ]] && err "Block device $DISK not found."

    echo
    warn "Selected: $DISK"
    ask "Type 'yes' to confirm — this CANNOT be undone:"
    read -rp "  > " _confirm
    [[ "$_confirm" != "yes" ]] && err "Aborted."
}

# ── Partition layout ──────────────────────────────────────────────────────────
select_layout() {
    section "Partition Layout"
    echo "  1)  ext4   — single root partition"
    echo "  2)  btrfs  — with subvolumes  (@  @home  @snapshots)"
    echo "  3)  ext4   — separate /home partition"
    echo
    ask "Choose layout [1-3]:"
    read -rp "  > " _l
    case $_l in
        1) LAYOUT="ext4-single" ;;
        2) LAYOUT="btrfs"       ;;
        3) LAYOUT="ext4-home"   ;;
        *) err "Invalid choice." ;;
    esac
}

# ── Swap ──────────────────────────────────────────────────────────────────────
select_swap() {
    section "Swap"
    echo "  1)  None"
    echo "  2)  Swap partition (size you choose)"
    echo "  3)  Swapfile (4 GB, created inside chroot)"
    echo
    ask "Choose swap option [1-3]:"
    read -rp "  > " _s
    SWAP_SIZE=""
    case $_s in
        1) SWAP="none"      ;;
        2) SWAP="partition"
           ask "Swap size (e.g.  4G  8G  16G):"
           read -rp "  > " SWAP_SIZE ;;
        3) SWAP="swapfile"  ;;
        *) err "Invalid choice." ;;
    esac
}

# ── Init system ───────────────────────────────────────────────────────────────
select_init() {
    section "Init System"
    echo "  1)  runit   — simple, fast, process supervision"
    echo "  2)  openrc  — traditional, widely documented"
    echo "  3)  s6      — minimalist, supervision tree"
    echo "  4)  dinit   — modern, dependency-based  (auto-includes turnstiled)"
    echo
    ask "Choose init [1-4]:"
    read -rp "  > " _i
    case $_i in
        1) INIT="runit"  ;;
        2) INIT="openrc" ;;
        3) INIT="s6"     ;;
        4) INIT="dinit"  ;;
        *) err "Invalid choice." ;;
    esac
}

# ── Confirm summary ───────────────────────────────────────────────────────────
confirm_summary() {
    section "Installation Summary"
    echo -e "  Disk    : ${BOLD}${DISK}${NC}"
    echo -e "  Layout  : ${BOLD}${LAYOUT}${NC}"
    echo -e "  Swap    : ${BOLD}${SWAP}${SWAP_SIZE:+ (${SWAP_SIZE})}${NC}"
    echo -e "  Init    : ${BOLD}${INIT}${NC}"
    echo
    warn "This will irreversibly wipe $DISK."
    ask "Type 'go' to begin:"
    read -rp "  > " _go
    [[ "$_go" != "go" ]] && err "Aborted."
}

# ── Partition name helper ─────────────────────────────────────────────────────
# Returns e.g. /dev/nvme0n1p2  or  /dev/sda2
part_name() {
    local d="$1" n="$2"
    if [[ "$d" == *nvme* || "$d" == *mmcblk* ]]; then
        echo "${d}p${n}"
    else
        echo "${d}${n}"
    fi
}

# ── Partitioning ──────────────────────────────────────────────────────────────
do_partition() {
    section "Partitioning"
    info "Wiping existing partition table on $DISK..."
    sgdisk --zap-all "$DISK" &>/dev/null
    wipefs -a "$DISK"          &>/dev/null

    local n=1

    # 1 — EFI (always)
    sgdisk -n ${n}:0:+512M -t ${n}:ef00 -c ${n}:"EFI" "$DISK"
    EFI_PART=$(part_name "$DISK" $n)
    (( n++ ))

    # 2 — Swap partition (optional)
    SWAP_PART=""
    if [[ "$SWAP" == "partition" ]]; then
        sgdisk -n ${n}:0:+${SWAP_SIZE} -t ${n}:8200 -c ${n}:"swap" "$DISK"
        SWAP_PART=$(part_name "$DISK" $n)
        (( n++ ))
    fi

    # 3 — Root (and optionally home)
    HOME_PART=""
    if [[ "$LAYOUT" == "ext4-home" ]]; then
        ask "Root partition size (e.g.  40G  60G  100G):"
        read -rp "  > " _root_sz
        sgdisk -n ${n}:0:+${_root_sz} -t ${n}:8300 -c ${n}:"root" "$DISK"
        ROOT_PART=$(part_name "$DISK" $n)
        (( n++ ))
        sgdisk -n ${n}:0:0 -t ${n}:8300 -c ${n}:"home" "$DISK"
        HOME_PART=$(part_name "$DISK" $n)
    else
        sgdisk -n ${n}:0:0 -t ${n}:8300 -c ${n}:"root" "$DISK"
        ROOT_PART=$(part_name "$DISK" $n)
    fi

    partprobe "$DISK"
    sleep 2
    ok "Partitioning complete."
}

# ── Formatting ────────────────────────────────────────────────────────────────
do_format() {
    section "Formatting"

    info "EFI partition → FAT32..."
    mkfs.fat -F32 -n EFI "$EFI_PART"

    if [[ -n "$SWAP_PART" ]]; then
        info "Swap partition → swap..."
        mkswap -L swap "$SWAP_PART"
        swapon "$SWAP_PART"
    fi

    info "Root partition → ${LAYOUT}..."
    case $LAYOUT in
        ext4-single|ext4-home)
            mkfs.ext4 -L root "$ROOT_PART" ;;
        btrfs)
            mkfs.btrfs -L root -f "$ROOT_PART" ;;
    esac

    if [[ -n "$HOME_PART" ]]; then
        info "Home partition → ext4..."
        mkfs.ext4 -L home "$HOME_PART"
    fi

    ok "Formatting complete."
}

# ── Mounting ──────────────────────────────────────────────────────────────────
do_mount() {
    section "Mounting"

    case $LAYOUT in
        ext4-single)
            mount "$ROOT_PART" /mnt
            ;;
        ext4-home)
            mount "$ROOT_PART" /mnt
            mkdir -p /mnt/home
            mount "$HOME_PART" /mnt/home
            ;;
        btrfs)
            mount "$ROOT_PART" /mnt

            info "Creating btrfs subvolumes..."
            btrfs subvolume create /mnt/@
            btrfs subvolume create /mnt/@home
            btrfs subvolume create /mnt/@snapshots
            umount /mnt

            local btrfs_opts="noatime,compress=zstd:1,space_cache=v2"
            mount -o "${btrfs_opts},subvol=@"          "$ROOT_PART" /mnt
            mkdir -p /mnt/{home,.snapshots}
            mount -o "${btrfs_opts},subvol=@home"      "$ROOT_PART" /mnt/home
            mount -o "${btrfs_opts},subvol=@snapshots" "$ROOT_PART" /mnt/.snapshots
            ;;
    esac

    mkdir -p /mnt/boot/efi
    mount "$EFI_PART" /mnt/boot/efi

    ok "All partitions mounted."
}

# ── Basestrap ─────────────────────────────────────────────────────────────────
do_basestrap() {
    section "Base System  (basestrap)"

    info "Refreshing keyrings..."
    pacman -Sy --noconfirm artix-keyring archlinux-keyring 2>/dev/null || true

    local init_pkgs
    case $INIT in
        runit)  init_pkgs="runit runit-rc" ;;
        openrc) init_pkgs="openrc" ;;
        s6)     init_pkgs="s6 s6-rc s6-suite" ;;
        dinit)  init_pkgs="dinit dinit-rc" ;;
    esac

    info "basestrap: base + base-devel + ${INIT} + elogind-${INIT}  (grab a coffee)..."
    basestrap /mnt \
        base base-devel \
        ${init_pkgs} \
        "elogind-${INIT}" \
        linux-firmware \
        btrfs-progs \
        vim nano \
        bash-completion

    ok "Base system installed."
}

# ── fstab ─────────────────────────────────────────────────────────────────────
do_fstab() {
    section "fstab"
    fstabgen -U /mnt >> /mnt/etc/fstab
    ok "fstab generated."
    info "Contents:"
    cat /mnt/etc/fstab
}

# ── Hand off ──────────────────────────────────────────────────────────────────
do_chroot() {
    section "Entering Chroot (Phase 2)"

    # Write config for the chroot script
    cat > /mnt/root/install.conf << EOF
INIT="${INIT}"
DISK="${DISK}"
LAYOUT="${LAYOUT}"
SWAP="${SWAP}"
EFI_PART="${EFI_PART}"
ROOT_PART="${ROOT_PART}"
HOME_PART="${HOME_PART:-}"
SWAP_PART="${SWAP_PART:-}"
EOF

    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

    cp "${script_dir}/chroot.sh" /mnt/root/chroot.sh
    chmod +x /mnt/root/chroot.sh

    info "Entering artix-chroot..."
    artix-chroot /mnt /bin/bash /root/chroot.sh
}

# ── Cleanup ───────────────────────────────────────────────────────────────────
do_cleanup() {
    section "Cleanup"
    rm -f /mnt/root/chroot.sh /mnt/root/install.conf

    info "Unmounting filesystems..."
    umount -R /mnt 2>/dev/null || true
    [[ -n "${SWAP_PART:-}" ]] && swapoff "$SWAP_PART" 2>/dev/null || true

    echo
    echo -e "${GREEN}${BOLD}"
    cat << 'DONE'
  ╔══════════════════════════════════════════════════╗
  ║   Installation complete!  🎉                    ║
  ║                                                  ║
  ║   Remove the ISO/USB and reboot:                 ║
  ║     reboot                                       ║
  ╚══════════════════════════════════════════════════╝
DONE
    echo -e "${NC}"
}

# ── Main ──────────────────────────────────────────────────────────────────────
main() {
    banner
    preflight
    select_disk
    select_layout
    select_swap
    select_init
    confirm_summary
    do_partition
    do_format
    do_mount
    do_basestrap
    do_fstab
    do_chroot
    do_cleanup
}

main "$@"
