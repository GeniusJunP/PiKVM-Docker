# syntax=docker/dockerfile:1
#
# Image for running PiKVM's kvmd in an unprivileged container.
# BASE is the rootfs image build.sh creates via docker import; this
# Dockerfile never runs pacman, to avoid diverging from the package set
# build.sh already baked in.

ARG BASE
FROM ${BASE}

# Mask units this container doesn't need. kvmd's units are ordered with
# After=/Before=, not Requires=, so masking one here never blocks another.
RUN systemctl mask \
        # networking: the container runtime configures the interface
        systemd-networkd.service \
        systemd-networkd.socket \
        systemd-networkd-wait-online.service \
        systemd-network-generator.service \
        systemd-resolved.service \
        systemd-timesyncd.service \
        # udev: not present in a container; pikvm-prepare and pikvm-switch
        # create /dev/kvmd-video and /dev/kvmd-hid-* themselves
        systemd-udevd.service \
        systemd-udevd-control.socket \
        systemd-udevd-kernel.socket \
        systemd-udev-trigger.service \
        systemd-udev-settle.service \
        # module loading / random seed / root remount: the container
        # shares the host kernel and has no separate root filesystem to
        # remount
        systemd-modules-load.service \
        systemd-random-seed.service \
        systemd-remount-fs.service \
        # no physical console; entry/exit goes through docker exec
        getty.target \
        serial-getty@.service \
        console-getty.service \
        # no separate SSH endpoint; entry/exit goes through docker exec
        sshd.service \
        # no hardware RNG device is passed into the container
        rngd.service \
        # fstab.find_pst() is called eagerly and raises if /etc/fstab has
        # no PST entry; this design doesn't offer PST
        # (https://github.com/pikvm/kvmd/blob/v4.213/kvmd/apps/pst/server.py#L55,
        #  https://github.com/pikvm/kvmd/blob/v4.213/kvmd/fstab.py#L57)
        kvmd-pst.service \
        # no RTC/i2c watchdog device is passed into the container
        kvmd-watchdog.service \
        # NAT for OTG ethernet needs CAP_NET_ADMIN; OTG is disabled by
        # default
        kvmd-otgnet.service \
        # direct CSI capture; this design targets a USB (hdmiusb) capture
        # dongle
        kvmd-tc358743.service \
        # Let's Encrypt; this design uses the self-signed cert from
        # kvmd-gencert
        kvmd-certbot.service kvmd-certbot.timer \
        # needs CAP_SYS_ADMIN + configfs to assemble the OTG gadget;
        # masked by default, unmasked by the privileged OTG-mode compose
        # file
        kvmd-otg.service

# kvmd-bootconfig.service is deliberately NOT masked: it exits 0
# immediately when /boot/pikvm.txt doesn't exist
# (https://github.com/pikvm/kvmd/blob/v4.213/scripts/kvmd-bootconfig#L39-L40).

# container/ mirrors the host filesystem's paths (container/etc/... ->
# /etc/..., container/usr/local/bin/... -> /usr/local/bin/..., etc).
COPY container/ /

# git only tracks the executable bit, so COPY leaves this file 0644,
# which sudo silently skips. visudo -c catches syntax errors at build time.
RUN chown root:root /etc/sudoers.d/pikvm-container \
    && chmod 0440 /etc/sudoers.d/pikvm-container \
    && visudo -c -f /etc/sudoers.d/pikvm-container

# --do-the-thing is a real required flag, not a placeholder
# (https://github.com/pikvm/kvmd/blob/v4.213/scripts/kvmd-gencert#L32-L43).
# VNC is unused, so --vnc is omitted.
RUN kvmd-gencert --do-the-thing

RUN systemctl enable pikvm-prepare.service

# No VOLUME (persistence is the compose file's concern); no EXPOSE (port
# assignment is the operator's concern).

STOPSIGNAL SIGRTMIN+3

CMD ["/usr/lib/systemd/systemd"]
