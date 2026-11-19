#!/bin/bash
# uninstall.sh: removes arnix from a system and undoes the changes it made.
#
#   curl -fsSLO https://raw.githubusercontent.com/nevabrokeagain/ArnixOS/main/Updates/uninstall.sh
#   sudo bash uninstall.sh
#
#   sudo bash uninstall.sh --dry-run          only show what it would do
#   sudo bash uninstall.sh --keep-branding    keep the ArnixOS name, logo and wallpaper
#
# What it does:
#   - stops the boot-time 'arnix rebuild' first, so nothing gets removed or installed
#   - turns off the network killswitch, encrypted DNS, MAC randomisation,
#     the telemetry opt-out files and the Firefox policies arnix wrote
#   - removes the arnix and arnixos-branding packages, the arnix-build user,
#     /var/cache/arnix and /var/lib/arnix
#   - puts Arch's os-release and /etc/issue back
#   - backs up /etc/arnix and /var/lib/arnix to /root/arnix-backup-<date> first
#
# What it leaves alone:
#   - every package you have installed, including ones arnix installed
#   - pacman.conf (multilib / chaotic-aur stay enabled) and the mirrorlist
#   - systemd-resolved and the /etc/resolv.conf link, so DNS keeps working
set -euo pipefail

die() { echo "uninstall.sh: error: $*" >&2; exit 1; }

DRY=0
KEEP_BRANDING=0
for arg in "$@"; do
    case $arg in
        --dry-run) DRY=1 ;;
        --keep-branding) KEEP_BRANDING=1 ;;
        -h|--help) sed -n '2,23p' "$0"; exit 0 ;;
        *) die "unknown option: $arg" ;;
    esac
done
[[ $EUID -eq 0 || $DRY == 1 ]] || die "run it with sudo: sudo bash uninstall.sh"

run() {
    echo "  \$ $*"
    [[ $DRY == 1 ]] || "$@"
}
step() { echo "==> $*"; }

installed() { pacman -Qq "$1" >/dev/null 2>&1; }
unit_exists() { systemctl list-unit-files "$1" >/dev/null 2>&1; }

# 1. stop arnix from changing the system ------------------------------------
step "stopping arnix services"
for unit in arnix-rebuild.service arnix-killswitch.service; do
    if unit_exists "$unit"; then
        systemctl is-enabled --quiet "$unit" 2>/dev/null && run systemctl disable "$unit"
        systemctl is-active --quiet "$unit" 2>/dev/null && run systemctl stop "$unit"
    fi
done
if command -v nft >/dev/null && nft list table inet arnix_killswitch >/dev/null 2>&1; then
    run nft delete table inet arnix_killswitch
fi

# 2. back up the config -----------------------------------------------------
BACKUP=/root/arnix-backup-$(date +%Y%m%d-%H%M%S)
if [[ -d /etc/arnix || -d /var/lib/arnix ]]; then
    step "backing up the arnix config to $BACKUP"
    run mkdir -p "$BACKUP"
    [[ -d /etc/arnix ]] && run cp -a /etc/arnix "$BACKUP/etc-arnix"
    [[ -d /var/lib/arnix ]] && run cp -a /var/lib/arnix "$BACKUP/var-lib-arnix"
fi

# 3. undo the privacy settings ----------------------------------------------
step "removing the files arnix wrote"
NM_CONF=/etc/NetworkManager/conf.d/90-arnix-privacy.conf
RESOLVED_CONF=/etc/systemd/resolved.conf.d/90-arnix-privacy.conf
for f in "$NM_CONF" "$RESOLVED_CONF" \
         /etc/profile.d/arnix-privacy.sh \
         /etc/environment.d/90-arnix-privacy.conf \
         /etc/arnix/killswitch.nft; do
    [[ -e $f ]] && run rm -f "$f"
done
if systemctl is-active --quiet NetworkManager 2>/dev/null; then
    run systemctl reload NetworkManager
fi
if systemctl is-active --quiet systemd-resolved 2>/dev/null; then
    run systemctl restart systemd-resolved
fi

# Firefox: take out only the two policies arnix adds, keep anything else
POLICIES=/etc/firefox/policies/policies.json
if [[ -f $POLICIES ]]; then
    step "removing arnix's Firefox policies"
    echo "  \$ (edit $POLICIES: drop DisableTelemetry, DisableFirefoxStudies)"
    if [[ $DRY == 0 ]]; then
        python3 -I - "$POLICIES" <<'EOF'
import json, os, sys
path = sys.argv[1]
try:
    data = json.load(open(path))
except (OSError, ValueError) as e:
    print(f"  leaving {path} alone, it can't be read: {e}")
    sys.exit(0)
pol = data.get("policies", {})
for key in ("DisableTelemetry", "DisableFirefoxStudies"):
    if pol.get(key) is True:
        del pol[key]
if data in ({}, {"policies": {}}):
    os.remove(path)
else:
    with open(path, "w") as f:
        json.dump(data, f, indent=2)
        f.write("\n")
EOF
    fi
fi

# 4. remove the packages ----------------------------------------------------
PKGS=()
installed arnix && PKGS+=(arnix)
[[ $KEEP_BRANDING == 0 ]] && installed arnixos-branding && PKGS+=(arnixos-branding)
if (( ${#PKGS[@]} )); then
    step "removing ${PKGS[*]}"
    # move the config away first so arnix's own pacman hook has nothing to edit
    [[ -d /etc/arnix ]] && run mv /etc/arnix "/etc/arnix.removed"
    run pacman -R --noconfirm "${PKGS[@]}"
    [[ -d /etc/arnix.removed ]] && run rm -rf /etc/arnix.removed
else
    step "arnix packages are already removed"
    [[ -d /etc/arnix ]] && run rm -rf /etc/arnix
fi

# 5. put Arch's name back ---------------------------------------------------
if [[ $KEEP_BRANDING == 0 ]]; then
    step "restoring Arch's os-release and /etc/issue"
    run pacman -S --noconfirm filesystem
    if grep -q -i arnix /etc/issue 2>/dev/null; then
        echo '  $ (write Arch Linux /etc/issue)'
        [[ $DRY == 1 ]] || printf 'Arch Linux \\r (\\l)\n\n' > /etc/issue
    fi
    # GRUB background pointed at a file that no longer exists
    if grep -q '^GRUB_BACKGROUND=.*arnix' /etc/default/grub 2>/dev/null; then
        run sed -i 's|^GRUB_BACKGROUND=.*arnix.*|#&|' /etc/default/grub
        command -v grub-mkconfig >/dev/null && [[ -d /boot/grub ]] && \
            run grub-mkconfig -o /boot/grub/grub.cfg
    fi
fi

# 6. leftovers --------------------------------------------------------------
step "removing arnix's build user, cache and state"
if id arnix-build >/dev/null 2>&1; then
    run userdel arnix-build
fi
for d in /var/cache/arnix /var/lib/arnix; do
    [[ -e $d ]] && run rm -rf "$d"
done

echo
if [[ $DRY == 1 ]]; then
    echo "dry run: nothing was changed"
else
    echo "arnix is removed. Your packages are untouched; use pacman/yay from now on."
    [[ -d $BACKUP ]] && echo "Your old config is in $BACKUP"
fi

exit 0
