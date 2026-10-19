# Changelog

Notable changes to this image. The image is versioned by the Ubuntu CUPS package it bundles
(`2.4.16-1ubuntu1.3-ls<N>`); this file records changes to the packaging itself.

## Unreleased

### Added — initial release

An unofficial, LinuxServer.io-style CUPS image for sharing a USB printer from Unraid, replacing the
abandoned 2021 Unraid CUPS template (`josecoelho/unraid-templates` → `ydkn/cups`).

- **CUPS 2.4.16 from Ubuntu 26.04** (`2.4.16-1ubuntu1.3`), cups-filters 2.0.1, Ghostscript 10.06, on
  the LinuxServer `resolute` base pinned by digest. Default drivers: HP PostScript (covers the HP
  LaserJet Pro M203-M206), Gutenprint, brlaser, SpliX, plus IPP Everywhere.
- **Configuration through environment variables**, validated on every start: `CUPS_ADMIN_USER`,
  `CUPS_ADMIN_PASSWORD` (with `FILE__` support), `CUPS_ALLOWED_NETWORKS`, `CUPS_ADMIN_NETWORKS`,
  `CUPS_SERVER_ALIASES`, `CUPS_PAPER_SIZE` (default `Letter`), `CUPS_LOG_LEVEL`,
  `CUPS_WEB_INTERFACE`, `CUPS_AIRPRINT`, `CUPS_AIRPRINT_HOSTNAME`, `CUPS_MANAGED_CONFIG`. Invalid
  values stop the container with every problem listed in the log.
- **Optional AirPrint** (`CUPS_AIRPRINT=true`): a private D-Bus and Avahi inside the container,
  supervised by s6 in the order CUPS needs, with automatic recovery if D-Bus restarts. Requires a
  custom network (br0 / eth0) with a fixed IP.
- **Optional queue auto-create** (`PRINTER_NAME`, `PRINTER_MODEL`, `PRINTER_URI`,
  `PRINTER_DESCRIPTION`, `PRINTER_LOCATION`, `PRINTER_OPTIONS`), with USB autodetection when exactly
  one printer is attached. Existing queues are never overwritten.
- **Import from the old template:** point `/config` at the old appdata folder and its
  `printers.conf`, `classes.conf` and PPDs are copied into `/config/cups` once; the originals are left
  untouched. Queues whose device URI needs a backend this image does not ship (`hp:/`, `dnssd://`,
  `lpd://`) are flagged in the log, and re-enabled once `PRINTER_*` gives them a usable URI.
- `/package_versions.txt` in the image lists every installed package and version.

### Security

- **No default credentials.** Remote administration is off unless both `CUPS_ADMIN_USER` and
  `CUPS_ADMIN_PASSWORD` are set; the admin pages then work over https only, from
  `CUPS_ADMIN_NETWORKS` only. Every password-protected IPP operation requires TLS too (Ubuntu's
  operation policy plus `Encryption Required`), so CUPS never asks for a password over plain http.
  The Unraid template's WebUI opens https.
- Printing and browsing are limited to `localhost` + `CUPS_ALLOWED_NETWORKS` (default: private
  address ranges); `all`, `*`, `/0` and IPv6 ranges that would also match every IPv4 client are
  refused. No `ServerAlias *`.
- The container **refuses to start** if a host D-Bus (`/var/run/dbus` or `/run/dbus`) is mounted
  into it, as the old template did — or the host's `/run`, or anything already serving a system bus —
  and changes nothing there.
- Not installed: `cups-browsed`, colord, ipp-usb, systemd. `file:` device URIs disabled. Backends
  trimmed to `http https ipp ipps socket usb`; only `usb` runs as root. The build-time snakeoil TLS
  key is removed, and the D-Bus activation helper is not setuid.
- One self-signed TLS certificate per installation, kept under `/config/cups/ssl` and named after the
  server name (`CUPS_AIRPRINT_HOSTNAME`, `--hostname`, or the `unraid-cups` fallback). It is served on
  every container address and survives container recreates, with or without `--hostname`.
- The admin password is never logged, never passed on a command line, not inherited by the daemons,
  and the container's copies are not readable by the print filters; the log warns when a
  `FILE__CUPS_ADMIN_PASSWORD` file itself is. Credentials inside `PRINTER_URI` are masked in the log.
- `/config/cups`, `ppd/` and `ssl/` must be real directories (planted symlinks are refused), TLS keys
  are re-locked to 0600 on every start, and cupsd runs with umask 022 whatever `UMASK` says.
- All GitHub Actions are pinned to commit SHAs; the base image digest and the action pins are kept
  current by Dependabot. The Dockerfile frontend and the BuildKit image are pinned by digest too.
- CI publishes only when a build input changed, proves in both directions that the image holds
  exactly the package versions its fingerprint names, and fails rather than publishes when the
  published fingerprint cannot be read.

### Known issues

- As of 2026-10-17, Ubuntu's CUPS package does not yet include the security fixes of upstream CUPS
  2.4.20 (released 2026-10-05). Keep the server LAN-only; the image rebuilds automatically once Ubuntu
  publishes the update.
- HP's `hpps` filter writes `@PJL SET ECONOMODE=ON` into job headers even with EconoMode off; the
  job's own PJL header that follows very likely resets it. Documented, not patched.
- A client that sends the admin password *unasked* over plain http to a web-interface printer page
  has it honoured (CUPS' CGIs re-issue the request locally). Log in over `https://` only.
- In bridge mode, the `426 Upgrade Required` redirect for `http://…/admin` points at the container's
  internal Docker address; open `https://<server>:<port>/admin` directly.
- Connections relayed by Docker's userland proxy (from the host itself, or IPv6 to a published port
  on a dual-stack host) arrive from the bridge gateway, which the default allow list admits. See the
  README's Security section.
