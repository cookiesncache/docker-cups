# syntax=docker/dockerfile:1@sha256:4edf897a3ffa55b89f906fc8cc78afdb3f1834cc9c7083565e611a8a7d5fe99e
# ^ The Dockerfile frontend BuildKit downloads and runs to parse this file, pinned by digest
#   (docker/dockerfile:1 = 1.27.1 when pinned) like everything else that executes in the build: a
#   bare `:1` tag would let a frontend release change how the published image is built with no
#   commit here. Bump it deliberately; NOTES.md ("Pinned build tooling") says how.

# ---- LinuxServer.io base (s6-overlay v3 + PUID/PGID + /config) on Ubuntu 26.04 "resolute" ----
# Pinned by digest so the base cannot move under us; Dependabot's docker ecosystem proposes bumps
# as a one-line PR. resolute is where CUPS 2.4.16 / cups-filters 2.0 / ghostscript 10.06 live; the
# image is arch-neutral (CI builds amd64 only, for Unraid).
FROM ghcr.io/linuxserver/baseimage-ubuntu:resolute@sha256:17f8127f438b5203c47149a87769ec8c82849d93c08cf8521c18949fd6ae8ee9

# LSIO_FIRST_PARTY=false: this is a custom/unofficial image on the LSIO base, so the base init must
# not overwrite our own init-adduser/branding (see LinuxServer's container-branding docs).
#
# S6_BEHAVIOUR_IF_STAGE2_FAILS=2: s6-overlay's default (0) keeps the container running when a
# oneshot fails. init-cups-config fails closed on purpose - a host D-Bus socket mounted into the
# container, or an access-control variable it cannot parse (CUPS_ALLOWED_NETWORKS=all, a newline in
# a value, ...) - and "running, but with nothing listening" is not a state an Unraid user can see.
# With 2, the container stops and the log's last lines say why. (Even with 0, cupsd still never
# starts: every service depends on init-cups-config through init-services.)
ENV LSIO_FIRST_PARTY="false" \
    S6_BEHAVIOUR_IF_STAGE2_FAILS="2"

# apt inputs, copied BEFORE the install so they are in effect during it:
#   - the systemd pin (also kept for runtime INSTALL_PACKAGES, see the file's comments)
#   - the debconf answers that decide which backends cups' postinst enables
#   - the package list, the single source of truth shared with CI's input fingerprint
# They are copied again, unchanged, by `COPY root/ /` below; copying them here first only orders them
# ahead of the apt layer.
COPY root/etc/apt/preferences.d/docker-cups-no-systemd /etc/apt/preferences.d/docker-cups-no-systemd
COPY root/etc/cups-image/ /etc/cups-image/

# Build-time only: an ARG (unlike ENV) does not leak into the runtime environment.
ARG DEBIAN_FRONTEND="noninteractive"

# Cache-busting handle for the apt layer below, and its POSITION IS DELIBERATE.
#
# An ARG declared ABOVE a RUN joins that RUN's cache key - visible in `docker history` as the
# `RUN |n NAME=value ...` prefix - so a new APT_FINGERPRINT forces this layer to re-execute and pick
# up whatever Ubuntu has published. CI computes it as a hash of the exact `pkg=version` set that
# `apt-get upgrade` + `apt-get install --no-install-recommends <packages.txt>` resolves to inside the
# pinned base, so the layer re-runs exactly when an Ubuntu package version changes - a CUPS or
# Ghostscript security update reaches the image on the next daily run, and a quiet archive day reuses
# the cache and publishes nothing.
#
# Do NOT move it down beside BUILD_DATE and VERSION. Those sit at the end precisely so they do NOT
# invalidate this layer; this one exists to do the opposite. Moving it would silently restore a warm
# layer cache reusing stale packages under a fresh label.
#
# It MUST be passed identically to BOTH build sites in build.yml - the smoke build and the
# build-push-action - or the image that gets smoke-tested is not the image that gets pushed.
ARG APT_FINGERPRINT
RUN <<'EOF'
set -eu
echo "**** apt inputs fingerprint: ${APT_FINGERPRINT:-unset} ****"

echo "**** preseed debconf (enabled backends) ****"
debconf-set-selections /etc/cups-image/debconf-selections

echo "**** upgrade base packages ****"
# LSIO bases do not run `apt-get upgrade` at build. Doing it here means the base's own libraries
# (glibc, openssl, gnutls, ...) carry current Ubuntu security updates even between base digest bumps;
# CI's fingerprint includes this upgrade set, so it also triggers a rebuild.
apt-get update
apt-get -y upgrade

echo "**** install cups ****"
# The list is validated before use: it is word-split into apt-get's argv, so a stray token must
# fail the build rather than be passed through.
pkgs="$(sed -e 's/#.*//' -e 's/[[:space:]]*$//' -e '/^$/d' /etc/cups-image/packages.txt)"
for p in ${pkgs}; do
  case "${p}" in
    *[!a-z0-9+.-]*|[!a-z0-9]*) echo "FATAL: bad package name '${p}' in packages.txt" >&2; exit 1 ;;
  esac
done
# shellcheck disable=SC2086 # intentional word splitting of the validated list
apt-get install -y --no-install-recommends ${pkgs}

echo "**** assert excluded packages are absent ****"
# cups-browsed: remote-printer auto-discovery, the 2024 RCE chain's entry point (only a Recommends).
# colord / ipp-usb: pull or expect systemd; ipp-usb would also grab the printer's USB interface.
# libnss-mdns: not needed to publish; would make .local resolution part of every getaddrinfo().
# hplip / printer-driver-all: hundreds of MiB of suite we do not need (hpps comes from postscript-hp).
# systemd & friends: cannot run under s6-overlay; the apt pin should already make this impossible.
for p in systemd systemd-sysv dbus-user-session libpam-systemd cups-browsed colord ipp-usb \
         libnss-mdns hplip printer-driver-hpcups printer-driver-all; do
  if dpkg-query -W -f='${Status}\n' "${p}" 2>/dev/null | grep -q 'install ok installed'; then
    echo "FATAL: excluded package '${p}' got installed" >&2
    exit 1
  fi
done

echo "**** trim CUPS backends ****"
# Backends are executed by cupsd for every `lpinfo -v` and every job on a queue using them; a
# backend that is not group/world-writable and not world-executable (0700/0744) runs as ROOT.
#   serial, parallel     - cups-filters, root-run serial (0744); no such ports in a container
#   beh, cups-brf        - cups-filters' error-handler wrapper and braille-embosser backend
#   driverless(-fax)     - DNS-SD discovery of IPP printers; queues for those use ipp:// directly
#   gutenprint53+usb     - Gutenprint's dye-sub USB backend; it runs as lp, which cannot open the
#                          root-owned USB device nodes in a container, so it can only fail
# What remains is checked against an exact list, so a package update that adds a backend fails the
# build and gets a deliberate decision instead of quietly widening what runs as root.
rm -f /usr/lib/cups/backend/serial /usr/lib/cups/backend/parallel \
      /usr/lib/cups/backend/beh /usr/lib/cups/backend/cups-brf \
      /usr/lib/cups/backend/driverless /usr/lib/cups/backend/driverless-fax \
      /usr/lib/cups/backend/gutenprint53+usb
expected="http https ipp ipps socket usb"
actual="$(find /usr/lib/cups/backend -mindepth 1 -maxdepth 1 -printf '%f\n' | LC_ALL=C sort | tr '\n' ' ' | sed 's/ $//')"
if [ "${actual}" != "${expected}" ]; then
  echo "FATAL: unexpected CUPS backends: '${actual}' (expected '${expected}')" >&2
  exit 1
fi

echo "**** remove the baked-in snakeoil TLS key ****"
# ssl-cert's postinst generates a private key + self-signed cert at BUILD time, so every container
# from this image would share one published private key. CUPS never uses it (it creates its own
# keychain under /config/cups/ssl), so delete the key, the cert, and the OpenSSL hash link that
# c_rehash made to it.
find /etc/ssl/certs -lname '*ssl-cert-snakeoil.pem' -delete
rm -f /etc/ssl/private/ssl-cert-snakeoil.key /etc/ssl/certs/ssl-cert-snakeoil.pem
if find /etc/ssl -name '*snakeoil*' | grep -q . ; then
  echo "FATAL: snakeoil material survived" >&2
  exit 1
fi

echo "**** neutralise the setuid D-Bus activation helper ****"
# dbus' postinst registers dbus-daemon-launch-helper as root:messagebus 4754 (setuid root). It only
# serves bus *activation* of system services, which nothing here uses (dbus-daemon and avahi-daemon
# are started by s6). A statoverride, rather than a chmod, so a later dpkg run keeps it neutralised.
helper=/usr/lib/dbus-1.0/dbus-daemon-launch-helper
dpkg-statoverride --remove "${helper}" 2>/dev/null || true
dpkg-statoverride --update --add root root 0755 "${helper}"
if [ -u "${helper}" ] || [ -g "${helper}" ]; then
  echo "FATAL: ${helper} is still setuid/setgid" >&2
  exit 1
fi

echo "**** relocate the CUPS ServerRoot onto /config ****"
# /etc/cups becomes a symlink to /config/cups, so queues, PPDs and the TLS keychain persist and the
# compiled-in paths of cupsd, lpadmin and cups-driverd keep working unchanged. The packaged contents
# become the first-boot seed under /defaults (LSIO idiom). cupsd.conf and cups-files.conf are NOT
# seeded: init-cups-config generates both from the environment (Ubuntu's stock cupsd.conf stays at
# /usr/share/cups/cupsd.conf.default for reference).
mkdir -p /defaults
mv /etc/cups /defaults/cups
rm -f /defaults/cups/cupsd.conf /defaults/cups/cups-files.conf
ln -s /config/cups /etc/cups

echo "**** extract Ubuntu's stock CUPS policies ****"
# The generated cupsd.conf reuses the <Policy default|authenticated|kerberos> blocks verbatim from the
# cupsd.conf.default THIS package version shipped, so Ubuntu's (CVE-patched) operation policy is kept
# exactly - extracted per build, never retyped. Everything from the first <Policy to the last
# </Policy> is taken; the counts are asserted so a layout change upstream fails the build loudly.
awk '/^<Policy /{p=1} p{l[++n]=$0; if ($0 ~ /^<\/Policy>/) e=n} END{for(i=1;i<=e;i++) print l[i]}' \
  /usr/share/cups/cupsd.conf.default > /defaults/cupsd-policies.conf
for pol in default authenticated kerberos; do
  if ! grep -qx "<Policy ${pol}>" /defaults/cupsd-policies.conf; then
    echo "FATAL: <Policy ${pol}> not found in cupsd.conf.default" >&2
    exit 1
  fi
done
if [ "$(grep -c '^<Policy ' /defaults/cupsd-policies.conf)" != 3 ] \
   || [ "$(grep -c '^</Policy>' /defaults/cupsd-policies.conf)" != 3 ]; then
  echo "FATAL: expected exactly 3 <Policy> blocks in cupsd.conf.default" >&2
  exit 1
fi

echo "**** record package versions ****"
# LSIO-style /package_versions.txt, `name=version` per line, sorted. CI reads the CUPS version for
# tags from here (the `cups-daemon=` line), and anyone can ask a running image what it ships.
dpkg-query -W -f='${Package}=${Version}\n' | sort > /package_versions.txt
grep -q '^cups-daemon=' /package_versions.txt

echo "**** cleanup ****"
apt-get clean
rm -rf \
  /var/lib/apt/lists/* \
  /tmp/* \
  /var/tmp/*
EOF

# s6 service definitions, init scripts, helpers, branding
COPY root/ /
RUN chmod +x \
    /etc/s6-overlay/s6-rc.d/init-cups-config/run \
    /etc/s6-overlay/s6-rc.d/init-cups-queue/run \
    /etc/s6-overlay/s6-rc.d/svc-cups/run \
    /etc/s6-overlay/s6-rc.d/svc-dbus/run \
    /etc/s6-overlay/s6-rc.d/svc-dbus/finish \
    /etc/s6-overlay/s6-rc.d/svc-avahi/run \
    /usr/local/bin/cups-env-bool \
    /usr/local/bin/cups-dbus-guard

# Build metadata last: these ARGs change on every published build, and declaring them here keeps
# them from invalidating the cached apt/COPY layers above.
ARG BUILD_DATE
ARG VERSION
LABEL build_version="docker-cups version:- ${VERSION} built:- ${BUILD_DATE}"
LABEL maintainer="simsc"
# The LSIO base sets its own org.opencontainers.image.* labels, describing THEIR image (title
# "Baseimage-ubuntu", vendor/authors linuxserver.io, their git revision). Inherited unchanged they
# would misattribute this unofficial image - the thing LSIO's branding rules ask us to avoid - so
# every one the base sets is overridden here. revision/ref.name are blanked rather than guessed;
# CI records the real commit as an index annotation.
LABEL org.opencontainers.image.title="docker-cups" \
      org.opencontainers.image.description="Unofficial LinuxServer.io-style CUPS print server (Ubuntu packages) for sharing a USB printer, with optional AirPrint. Not affiliated with LinuxServer.io or OpenPrinting." \
      org.opencontainers.image.authors="cookiesncache" \
      org.opencontainers.image.vendor="cookiesncache" \
      org.opencontainers.image.url="https://github.com/cookiesncache/docker-cups" \
      org.opencontainers.image.source="https://github.com/cookiesncache/docker-cups" \
      org.opencontainers.image.documentation="https://github.com/cookiesncache/docker-cups#readme" \
      org.opencontainers.image.licenses="GPL-3.0-only" \
      org.opencontainers.image.version="${VERSION}" \
      org.opencontainers.image.created="${BUILD_DATE}" \
      org.opencontainers.image.revision="" \
      org.opencontainers.image.ref.name=""

# IPP, the web interface and IPPS/HTTPS all share this one port (CUPS auto-detects TLS).
EXPOSE 631

# "scheduler is running" = lpstat could connect to cupsd, over the /run/cups/cups.sock domain socket
# (the client default), so the probe needs neither the network nor the access rules. lpstat exits 0
# either way, hence the text match; LC_ALL=C pins the message (the base strips translations anyway).
HEALTHCHECK --interval=30s --timeout=10s --start-period=30s --start-interval=5s --retries=3 \
  CMD LC_ALL=C lpstat -r 2>/dev/null | grep -qx 'scheduler is running' || exit 1

# No ENTRYPOINT/CMD on purpose: the baseimage's /init (s6-overlay) is PID 1 and supervises
# svc-dbus / svc-avahi / svc-cups. Signal handling and zombie reaping are s6's job.
