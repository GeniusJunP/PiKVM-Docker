#!/usr/bin/env bash
#
# builds a rootfs base image from the official PiKVM image, for
# import via docker import.
#
# Usage:
#   sudo ./build.sh --platform v2-hdmiusb-rpi4|v2-hdmiusb-rpi5 \
#                    [--version YYYYMMDD|latest] [--image <path>]
#
# This script is meant to run as root on a build host (not necessarily the
# Pi itself), because creating and mounting a loop device requires
# CAP_SYS_ADMIN.
#
set -euo pipefail

readonly BASE_URL="https://files.pikvm.org/images"

# The one tag compose.yml names. It moves here on every build, including a
# build of an earlier --version, which is what makes going back a rerun of
# this script rather than an edit of compose.yml. The versioned tag beside
# it is named by nothing and only records which release an image is.
readonly CURRENT_TAG="pikvm-rootfs:current"
readonly VALID_PLATFORMS=("v2-hdmiusb-rpi4" "v2-hdmiusb-rpi5")

# Left out of docker import: kernel/firmware/modules the container never
# uses, since it shares the host kernel as-is.
readonly TAR_EXCLUDES=(
  "--exclude=./boot/*"
  "--exclude=./lib/modules/*"
  "--exclude=./usr/lib/modules/*"
  "--exclude=./usr/lib/firmware/*"
  "--exclude=./var/cache/pacman/pkg/*"
  "--exclude=./var/log/*"
)

# Commands this script needs that can genuinely be missing on a build
# host; never installed automatically. coreutils (dd, df, numfmt, awk,
# id, mktemp, sha1sum, tr, tail) is assumed present.
readonly REQUIRED_CMDS=(
  curl xz fallocate losetup lsblk mount umount mountpoint tar docker
)

usage() {
  cat <<EOF
Usage: $0 --platform v2-hdmiusb-rpi4|v2-hdmiusb-rpi5 [--version YYYYMMDD|latest]
       $0 --image <path>

Downloads a release and builds it, or builds a .img.xz you already have.

  --platform  Which release to download. Either v2-hdmiusb-rpi4 or
              v2-hdmiusb-rpi5. Required unless --image is given.
  --version   Which release to download. Defaults to latest; a YYYYMMDD
              version can also be given.
  --image     Build this .img.xz. It is used as given and left where it is,
              and the download options do not apply.
EOF
}

platform=""
version="latest"
version_given=""
image=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --platform)
      [[ $# -ge 2 ]] || { echo "--platform requires a value." >&2; exit 1; }
      platform="$2"
      shift 2
      ;;
    --version)
      [[ $# -ge 2 ]] || { echo "--version requires a value." >&2; exit 1; }
      version="$2"
      version_given=1
      shift 2
      ;;
    --image)
      [[ $# -ge 2 ]] || { echo "--image requires a value." >&2; exit 1; }
      image="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

# --platform and --version say which release to fetch, so they mean nothing
# once a file is named. Rejecting them rather than ignoring them keeps a
# caller from believing the tag or the file was chosen by what they passed.
if [[ -n "$image" ]]; then
  if [[ ! -r "$image" ]]; then
    echo "--image is not a readable file: ${image}" >&2
    exit 1
  fi
  if [[ -n "$platform" ]]; then
    echo "--platform has no effect with --image: it selects a release to download." >&2
    exit 1
  fi
  if [[ -n "$version_given" ]]; then
    echo "--version has no effect with --image: it selects a release to download." >&2
    exit 1
  fi
  # The script cannot tell which release a given file is, so it records
  # nothing about it beyond the alias compose.yml reads.
  tag="$CURRENT_TAG"
else
  if [[ -z "$platform" ]]; then
    echo "--platform is required unless --image is given." >&2
    usage >&2
    exit 1
  fi
  if [[ ! " ${VALID_PLATFORMS[*]} " == *" ${platform} "* ]]; then
    echo "Invalid value for --platform: ${platform} (must be v2-hdmiusb-rpi4 or v2-hdmiusb-rpi5)" >&2
    exit 1
  fi
  if [[ "$version" != "latest" && ! "$version" =~ ^[0-9]{8}$ ]]; then
    echo "Invalid value for --version: ${version} (must be YYYYMMDD or latest)" >&2
    exit 1
  fi
  tag="pikvm-rootfs:${platform}-${version}"
fi

# Root check (this script never re-execs itself with sudo)
if [[ "$(id -u)" -ne 0 ]]; then
  echo "Root privileges are required: creating and mounting a loop device needs CAP_SYS_ADMIN. This script does not re-exec itself with sudo." >&2
  exit 1
fi

missing_cmds=()
for c in "${REQUIRED_CMDS[@]}"; do
  if ! command -v "$c" >/dev/null 2>&1; then
    missing_cmds+=("$c")
  fi
done
if [[ "${#missing_cmds[@]}" -gt 0 ]]; then
  echo "Missing commands: ${missing_cmds[*]}" >&2
  echo "This script does not install packages automatically." >&2
  exit 1
fi

if [[ -n "$image" ]]; then
  echo "source:   ${image}"
else
  img_name="${platform}-aarch64-${version}.img.xz"
  img_url="${BASE_URL}/${platform}/aarch64/${img_name}"
  sha1_url="${img_url}.sha1"

  echo "platform: ${platform}"
  echo "version:  ${version}"
  echo "source:   ${img_url}"
fi

# Working directory and cleanup (on every exit path: unmount, detach the
# loop device, remove the working directory, in that order)
workdir="$(mktemp -d)"
loopdev=""
mnt_dir="${workdir}/mnt"
mkdir -p "$mnt_dir"

cleanup() {
  local status=$?
  set +e
  if mountpoint -q "$mnt_dir" 2>/dev/null; then
    umount "$mnt_dir" 2>/dev/null
  fi
  if [[ -n "$loopdev" ]]; then
    losetup -d "$loopdev" 2>/dev/null
  fi
  rm -rf "$workdir"
  return "$status"
}
trap cleanup EXIT

img_path="${workdir}/rootfs.img"

# Called twice against the same filesystem (the working directory) with
# two different required sizes: once for the .img.xz download, once for
# the extracted .img.
require_free_space() {
  local required_bytes="$1" label="$2"
  local avail_bytes
  avail_bytes="$(df -B1 --output=avail "$workdir" | tail -n 1 | tr -d ' ')"
  if [[ "$avail_bytes" -lt "$required_bytes" ]]; then
    echo "Not enough free space in the working directory (${workdir}) for ${label}." >&2
    echo "Needed: at least $(numfmt --to=iec "$required_bytes"), available: $(numfmt --to=iec "$avail_bytes")" >&2
    exit 1
  fi
}

# The two paths meet again at the extraction below. Naming a file says the
# caller vouches for it, so that path touches no network at all; the sha1
# here checks the transfer this script itself made.
if [[ -n "$image" ]]; then
  img_xz_path="$image"
else
  img_xz_path="${workdir}/${img_name}"
  # tolower() rather than a case-insensitive match: IGNORECASE is a gawk
  # extension, and Debian's default awk is mawk, which silently treats it as
  # an ordinary variable and keeps matching case-sensitively.
  content_length="$(
    curl -fsSL -I "$img_url" 2>/dev/null \
      | tr -d '\r' \
      | awk 'tolower($1)=="content-length:"{v=$2} END{print v}'
  )"
  if [[ -z "$content_length" ]]; then
    echo "Could not get the download size from the HTTP headers: ${img_url}" >&2
    exit 1
  fi
  require_free_space "$content_length" "the downloaded .img.xz"

  echo "Downloading: ${img_name}"
  curl -fSL -o "$img_xz_path" "$img_url"

  sha1_path="${workdir}/${img_name}.sha1"
  curl -fSL -o "$sha1_path" "$sha1_url"
  expected_sha1="$(awk '{print $1; exit}' "$sha1_path")"
  if [[ ! "$expected_sha1" =~ ^[0-9a-fA-F]{40}$ ]]; then
    echo "The .sha1 file content is not a 40-digit hex string: '${expected_sha1}'" >&2
    exit 1
  fi

  actual_sha1="$(sha1sum "$img_xz_path" | awk '{print $1}')"
  if [[ "${actual_sha1,,}" != "${expected_sha1,,}" ]]; then
    echo "sha1 mismatch. expected: ${expected_sha1}, actual: ${actual_sha1}" >&2
    exit 1
  fi
  echo "sha1 verified: match (${actual_sha1})"
fi

# The xz container footer records the uncompressed size ("file" row, 5th
# field of --robot -l), so this reads it without extracting anything yet.
uncompressed_size="$(
  xz --robot -l "$img_xz_path" | awk -F'\t' '$1=="file"{print $5}'
)"
if [[ -z "$uncompressed_size" ]]; then
  echo "Could not get the uncompressed size from xz --list output." >&2
  exit 1
fi
require_free_space "$uncompressed_size" "the extracted .img"

echo "Extracting ..."
xz -dc "$img_xz_path" | dd conv=sparse of="$img_path" bs=4M status=none
# fallocate -d as a second pass, to sparsify anything dd's conv=sparse missed.
fallocate -d "$img_path"
# Frees the compressed copy before the mount and tar, which matters when the
# working directory is tight. A --image file belongs to the caller, so it
# stays.
if [[ -z "$image" ]]; then
  rm -f "$img_xz_path"
fi

# losetup picks a free device itself (--find --show); --partscan makes
# the kernel read the partition table so loopNp1/p2 show up.
loopdev="$(losetup --find --show --partscan "$img_path")"
echo "Loop device: ${loopdev}"

if command -v udevadm >/dev/null 2>&1; then
  udevadm settle 2>/dev/null || true
fi

# The root partition isn't hardcoded: PiKVM images have a small FAT boot
# partition at the start, so "the largest ext4 partition" uniquely
# identifies root. lsblk -P (key=value pairs, eval'd directly) avoids -r's
# column misalignment when a field is empty.
root_part=""
root_size=0

while IFS= read -r line; do
  eval "$line"
  if [[ "$FSTYPE" == "ext4" ]] && (( SIZE > root_size )); then
    root_size="$SIZE"
    root_part="/dev/${NAME}"
  fi
done < <(lsblk -P -b -o NAME,FSTYPE,SIZE "$loopdev")

if [[ -z "$root_part" ]]; then
  echo "No ext4 root partition found. The image's partition layout may differ from what this script expects." >&2
  exit 1
fi
echo "Root partition: ${root_part} ($(numfmt --to=iec "$root_size"))"

mount -o ro "$root_part" "$mnt_dir"

echo "Running docker import (tag: ${tag}) ..."
# Piped straight into docker import instead of writing a tar file to disk.
tar -C "$mnt_dir" \
  "${TAR_EXCLUDES[@]}" \
  --numeric-owner --xattrs --acls -cSpf - . \
  | docker import - "$tag"

echo ""
echo "Done."
if [[ -n "$image" ]]; then
  echo "source:   ${image}"
  echo "tag:      ${tag}"
else
  docker tag "$tag" "$CURRENT_TAG"
  echo "platform: ${platform}"
  echo "version:  ${version}"
  echo "source:   ${img_url}"
  echo "sha1:     ${actual_sha1}"
  echo "tag:      ${tag}"
  echo "also tagged: ${CURRENT_TAG}"
fi
echo ""
echo "Next command to run:"
echo "  docker compose up -d"
