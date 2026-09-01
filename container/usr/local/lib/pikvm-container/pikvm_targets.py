"""Shared helpers for pikvm-prepare and pikvm-switch.

Holds targets.conf parsing, device verification, the /dev/kvmd-targets
symlink layout, and the current-target state file.

Uses only the standard library. Depends on no kvmd module and no
pyserial.
"""

from __future__ import annotations

import errno
import os
import re
import stat
import sys
from typing import NamedTuple


TARGETS_CONF = "/etc/pikvm-container/targets.conf"
HOSTDEV_DIR = "/hostdev"
TARGETS_DIR = "/dev/kvmd-targets"
STATE_DIR = "/var/lib/pikvm-container"
STATE_FILE = os.path.join(STATE_DIR, "current-target")
KVMD_VIDEO_LINK = "/dev/kvmd-video"
KVMD_HID_LINK = "/dev/kvmd-hid"

# Target names from targets.conf are used as file names, systemd unit
# names (%i), and WebUI button names, so they are restricted tightly
# (full rule and rationale: targets.conf.example).
NAME_RE = re.compile(r"^[a-z0-9][a-z0-9-]*$")

# argv[0] is pikvm-prepare or pikvm-switch, whichever is actually
# running, so the journal prefix always matches the systemd unit that
# produced it, with nothing to keep in sync between the two scripts.
PREFIX = os.path.basename(sys.argv[0])


def log_info(msg: str) -> None:
    print(f"{PREFIX}: {msg}", flush=True)


def log_warn(msg: str) -> None:
    print(f"{PREFIX}: warning: {msg}", file=sys.stderr, flush=True)


def log_err(msg: str) -> None:
    print(f"{PREFIX}: error: {msg}", file=sys.stderr, flush=True)


def die(msg: str) -> None:
    log_err(msg)
    sys.exit(1)


def errno_name(err: OSError) -> str:
    if err.errno is None:
        return "?"
    return errno.errorcode.get(err.errno, str(err.errno))


class Target(NamedTuple):
    name: str
    video_host: str  # Absolute path on the host side (still /dev/..., unconverted)
    hid_host: str
    label: str  # What the web UI shows; defaults to name


def parse_targets_conf(path: str) -> list[Target]:
    """Reads whitespace-separated <name> <video> <hid> [label] rows. The
    label is everything left on the line, so it may contain spaces; it
    defaults to <name>. Anything after # is a comment; blank lines are
    ignored. Duplicate names, names that violate the naming rule, paths not
    starting with /dev/, and labels containing the character kvmd's view
    table separates on are all reported as errors with their line number."""
    if not os.path.isfile(path):
        die(f"targets.conf not found: {path}")

    try:
        with open(path, encoding="utf-8") as f:
            raw_lines = f.readlines()
    except UnicodeDecodeError as e:
        # Labels may be non-ASCII, so say which encoding is expected rather
        # than letting the decode error surface as a traceback.
        die(f"{path} is not valid UTF-8 (byte {e.start}); save it as UTF-8")

    targets: list[Target] = []
    seen: dict[str, int] = {}

    for (lineno, raw) in enumerate(raw_lines, start=1):
        line = raw.split("#", 1)[0].strip()
        if not line:
            continue

        cols = line.split()
        if len(cols) < 3:
            die(
                f"{path}:{lineno}: expected at least 3 columns "
                f"(<name> <video device> <hid device> [label]), got: {raw.strip()!r}"
            )

        (name, video, hid) = cols[:3]
        label = " ".join(cols[3:]) or name

        if not NAME_RE.match(name):
            die(
                f"{path}:{lineno}: target name {name!r} does not match "
                f"the naming rule ^[a-z0-9][a-z0-9-]*$"
            )

        if name in seen:
            die(f"{path}:{lineno}: target name {name!r} is a duplicate of line {seen[name]}")
        seen[name] = lineno

        for (kind, devpath) in (("video", video), ("hid", hid)):
            if not devpath.startswith("/dev/"):
                die(f"{path}:{lineno}: {kind} path {devpath!r} does not start with /dev/")

        # kvmd's view table encodes a cell as "<channel>|<text>", so a label
        # carrying that character would be cut in half.
        if "|" in label:
            die(f"{path}:{lineno}: label {label!r} must not contain '|'")

        targets.append(Target(name=name, video_host=video, hid_host=hid, label=label))

    if not targets:
        die(f"{path}: no target definitions found (only blank lines and/or comments)")

    return targets


def host_path_to_container(host_path: str) -> str:
    """Converts a host-side /dev/... path from targets.conf into the
    /hostdev/... path this container can actually read. Assumes the
    host's /dev is bind-mounted read-only into the container as
    /hostdev."""
    assert host_path.startswith("/dev/"), host_path
    return HOSTDEV_DIR + host_path[len("/dev"):]


def verify_device(path: str) -> tuple[bool, str]:
    """Actually open(O_RDWR)s path (following symlinks) to check it.
    Returns: (usable, reason string)."""
    try:
        st = os.stat(path)  # follows symlinks
    except OSError as e:
        return (False, f"cannot resolve {path}: {errno_name(e)}: {e.strerror}")

    if not stat.S_ISCHR(st.st_mode):
        return (False, f"{path} is not a character device (st_mode={oct(st.st_mode)})")

    try:
        fd = os.open(path, os.O_RDWR)
    except OSError as e:
        return (False, f"open(O_RDWR) on {path} failed: {errno_name(e)}: {e.strerror}")
    else:
        os.close(fd)
        return (True, "open(O_RDWR) succeeded")


class VerifiedTarget(NamedTuple):
    name: str
    video_link: str
    hid_link: str
    video_ok: bool
    video_reason: str
    hid_ok: bool
    hid_reason: str

    @property
    def usable(self) -> bool:
        return self.video_ok and self.hid_ok


def verify_target(name: str) -> VerifiedTarget:
    """Verifies the target's already-created /dev/kvmd-targets/<name>-video
    and -hid links (pikvm-prepare is what creates them; by the time this
    runs, either from prepare itself or from a later switch, they are
    assumed to already point at the right host device)."""
    video_link = os.path.join(TARGETS_DIR, f"{name}-video")
    hid_link = os.path.join(TARGETS_DIR, f"{name}-hid")
    (video_ok, video_reason) = verify_device(video_link)
    (hid_ok, hid_reason) = verify_device(hid_link)
    return VerifiedTarget(name, video_link, hid_link, video_ok, video_reason, hid_ok, hid_reason)


def force_symlink(link_target: str, link_path: str) -> None:
    """Equivalent to ln -sfn: removes any existing entry first, then
    creates the symlink."""
    try:
        if os.path.lexists(link_path):
            os.remove(link_path)
        os.symlink(link_target, link_path)
    except OSError as e:
        die(f"failed to create symlink {link_path} -> {link_target}: {errno_name(e)}: {e.strerror}")


def read_current_target() -> "str | None":
    try:
        with open(STATE_FILE, encoding="utf-8") as f:
            value = f.read().strip()
    except FileNotFoundError:
        return None
    except OSError as e:
        log_warn(f"could not read {STATE_FILE}: {errno_name(e)}: {e.strerror}")
        return None
    return (value or None)


def write_current_target(name: str) -> None:
    atomic_write(STATE_FILE, name + "\n")


def atomic_write(path: str, content: str) -> None:
    directory = os.path.dirname(path)
    os.makedirs(directory, exist_ok=True)
    tmp_path = path + ".tmp"
    with open(tmp_path, "w", encoding="utf-8") as f:
        f.write(content)
        f.flush()
        os.fsync(f.fileno())
    # Makes the result 0o644 regardless of the process umask, rather than
    # leaving it to open()'s mode argument.
    os.chmod(tmp_path, 0o644)
    os.replace(tmp_path, path)
