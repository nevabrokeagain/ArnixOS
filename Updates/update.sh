#!/bin/bash
# update.sh: updates arnix to the newest version in the ArnixOS repo.
#
# Works on every version of arnix, also 0.1.0, which has no 'arnix self-update'.
# Published in the repo's Updates folder; on an installed system:
#
#   curl -fsSLO https://raw.githubusercontent.com/nevabrokeagain/ArnixOS/main/Updates/update.sh
#   sudo bash update.sh
#
#   sudo bash update.sh --dry-run    only show what it would do
#
# It reads Updates/LATEST, downloads that update with its checksum (and its
# signature, if this system requires one), checks them, and runs the update's
# own install-update.sh. From arnix 0.1.1 on, 'sudo arnix upgrade' does this.
set -euo pipefail

URL=${ARNIX_UPDATE_URL:-https://raw.githubusercontent.com/nevabrokeagain/ArnixOS/main/Updates}
KEY=/usr/share/arnix/update-key.asc

die() { echo "update.sh: error: $*" >&2; exit 1; }

DRY=0
for arg in "$@"; do
    [[ $arg == --dry-run ]] && DRY=1
done
[[ $EUID -eq 0 || $DRY == 1 ]] || die "run it with sudo: sudo bash update.sh"
command -v arnix >/dev/null || die "arnix isn't installed here; install it with setup.sh or the ArnixOS ISO"
for tool in curl tar sha256sum vercmp; do
    command -v "$tool" >/dev/null || die "$tool is missing"
done

# https only (a local folder given as file:// works too, for offline mirrors)
proto="=https"
[[ $URL == file://* ]] && proto="=file"
get() { curl -fsSL --proto "$proto" --max-time 600 "$@"; }

latest=$(get "$URL/LATEST" 2>/dev/null) || die "could not reach $URL (no internet, or nothing published yet)"
latest=${latest//[$'\r\n\t ']/}
[[ $latest =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "$URL/LATEST doesn't hold a version number"
name=arnix-update-$latest.tar.gz
echo "==> newest arnix: $latest"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
cd "$tmp"
echo "==> downloading $name"
get -o "$name" "$URL/$latest/$name" || die "could not download $name"
get -o "$name.sha256" "$URL/$latest/$name.sha256" || die "could not download $name.sha256"
sha256sum -c --quiet "$name.sha256" || die "the download is damaged, try again"

# systems that carry the update key only accept updates signed with it
if [[ -f $KEY ]]; then
    get -o "$name.sig" "$URL/$latest/$name.sig" 2>/dev/null ||
        die "$name isn't signed, but this system only accepts signed updates"
    gpg --batch --quiet --dearmor -o key.gpg "$KEY"
    gpgv --keyring "$tmp/key.gpg" "$name.sig" "$name" 2>/dev/null ||
        die "the signature of $name is not valid, refusing it"
    echo "==> signature valid"
fi

tar -xzf "$name"
cd "arnix-update-$latest"
# install-update.sh refuses versions that aren't newer, and shows what it does
bash install-update.sh "$@"
