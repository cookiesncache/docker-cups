# Maintainer notes

Design decisions and reference facts for this image. Package, CUPS and AirPrint facts were verified
against Ubuntu 26.04 "resolute" packages on 2026-10-17/18 (`cups 2.4.16-1ubuntu1.3`); re-verify before
relying on them after a base bump or an Ubuntu package update.

## What this replaces

The CUPS template many Unraid users still run is `josecoelho/unraid-templates` `cups/cups.xml`, which
points at `ydkn/cups` and was last changed in 2021. It shipped `admin`/`admin`, remote
administration from anywhere, `ServerAlias *`, a **read-write bind of the host's `/var/run/dbus`**
(mislabelled "USB mapping" in the template), and a single hard-coded device node
(`/dev/bus/usb/003/009`) that breaks the first time the printer is power-cycled. Its appdata was
mapped straight onto `/etc/cups`.

The maintainer's own printer, which shaped the defaults: HP LaserJet Pro M203-M206, USB
`03f0:632a`, interface class 7/1/2 (bidirectional printer class; **no** IPP-over-USB). Letter paper.

## Base image

`ghcr.io/linuxserver/baseimage-ubuntu:resolute`, **pinned by index digest** (= `resolute-82fe3735-ls29`,
Ubuntu 26.04.1; Dependabot bumps it). It provides s6-overlay v3, the `abc` user, `/config`,
`lsiown`, `with-contenv`, Docker Mods and `FILE__` secrets. `/usr/sbin/policy-rc.d` denies service
starts, so package postinsts cannot start daemons during the build. It ships
`systemd-standalone-sysusers`, which matters for the systemd pin below.

**Why resolute (26.04 LTS) and not noble (24.04 LTS), which docker-openclaw uses.** Measured from the
archive on 2026-10-18:

| | noble (`-updates`) | resolute |
|---|---|---|
| CUPS | 2.4.7-1.2ubuntu7.14 | **2.4.16**-1ubuntu1.3 |
| cups-filters / libppd | 2.0.0 | 2.0.1 / 2.1.1 |
| Ghostscript | 10.02.1 | **10.06.0** |
| hplip (`printer-driver-postscript-hp`) | 3.23.12 | 3.24.4 |
| avahi / dbus | 0.8-13ubuntu6.2 / 1.14.10 | 0.8-18ubuntu1.1 / 1.16.2 |
| apt | 2.8.3 | 3.2.0 (solver3) |

Both are LTS releases with security support. resolute is nine CUPS point releases closer to
upstream, which matters because upstream fixes reach Ubuntu as backports and a backport onto 2.4.16
is a far smaller diff than one onto 2.4.7. It also has the newer Ghostscript, the component that
parses untrusted documents. The cost is a younger base with a shorter LSIO release history.

Everything LSIO-specific is used the standard way: custom branding, `LSIO_FIRST_PARTY=false`,
`PUID`/`PGID` for `/config` only, `/defaults` as the first-boot seed, s6-rc services named `init-*`
and `svc-*`.

## Package set

All from Ubuntu `main`, installed with `--no-install-recommends`. The list lives in
`root/etc/cups-image/packages.txt` — the **one** list both the Dockerfile and CI's fingerprint read;
never duplicate it.

Measured on the built image (`dpkg-query` installed sizes, image vs. base): **120 new packages,
145.0 MiB**.

| Group | Packages named | Approx. size | Why |
|---|---|---|---|
| CUPS + cups-filters | `cups cups-client cups-daemon cups-filters` | 14.4 MiB (16 pkgs) | `cups` is **not** a metapackage: it carries the `usb` backend, the web-UI CGIs, `cups-driverd`/`cups-deviced` (`lpinfo -m`/`-v`) and `cupsfilter`. The others are named so a dependency reshuffle cannot silently drop the scheduler or `lpadmin`. |
| Ghostscript + URW fonts | `ghostscript` | 44.1 MiB | PDF → PostScript/raster in every print path. |
| Poppler (+ data) | (dependency) | 17.6 MiB | cups-filters' `pdftops`/`pdftoraster` helpers. |
| Python 3.14 | (dependency) | 23.7 MiB | Pulled in **only** by `printer-driver-postscript-hp`'s PPD driver program (`/usr/lib/cups/driver/postscript-hp`, a pyppd archive). The print path does not use Python — `hpps` is ELF. |
| Gutenprint | `printer-driver-gutenprint` | 9.8 MiB | Broad inkjet/laser coverage. |
| HP PostScript | `printer-driver-postscript-hp` | 1.8 MiB | The M203-M206 PPD + `hpps` filter. |
| Brother / Samsung-Xerox | `printer-driver-brlaser printer-driver-splix` | 0.3 MiB | Cheap, common lasers. |
| AirPrint | `avahi-daemon dbus` | +6 pkgs, 0.9 MiB | Always installed, enabled at runtime by `CUPS_AIRPRINT`. Not worth a variant image. |
| D-Bus session provider | `dbus-x11` | (small) | Named so apt's choice is deterministic; the alternative, `dbus-user-session`, drags in systemd. |

`cups-ipp-utils` (ippeveprinter, ipptool, ippfind) is a hard dependency of `cups-filters-core-drivers`,
so it is in the image anyway; the smoke test uses it. `libsnapd-glib-2-1` is a hard dependency of
Ubuntu's `cups-daemon` (its checks on snap-packaged clients) and is inert without snapd.
`cups-daemon` Recommends `avahi-daemon, colord, cups-browsed, ipp-usb`: only the first is wanted, and
it is named explicitly.

**Excluded, and asserted absent at build** (the build fails if any appears):

- `cups-browsed` — remote-printer auto-discovery, the entry point of the 2024 cups-browsed /
  libcupsfilters RCE chain. Only a Recommends of `cups-daemon`; a USB print server has no use for it.
- `colord`, `ipp-usb` — pull in or expect systemd; ipp-usb would also grab the printer's USB
  interface. (colord's absence is why cupsd logs `CreateProfile`/`CreateDevice failed` in AirPrint
  mode — harmless.)
- `libnss-mdns` — not needed to *publish*; would put `.local` resolution into every `getaddrinfo()`.
  (Avahi logs `No NSS support for mDNS detected` — harmless.)
- `hplip`, `printer-driver-hpcups`, `printer-driver-all` — large driver suites the default set does
  not need (hpcups alone is +57 MiB). hpcups stays installable at runtime, below.
- `systemd systemd-sysv dbus-user-session libpam-systemd` — cannot run under s6.

**Opt-in via `DOCKER_MODS=linuxserver/mods:universal-package-install` + `INSTALL_PACKAGES=a|b`**,
documented in the README: `printer-driver-hpcups` (+57 MiB of Perl; no M203 support),
`printer-driver-foo2zjs` (its firmware loader is a udev hook, inert in a container),
`printer-driver-escpr` (universe — the base enables `universe`, so it installs), and
`foomatic-db-compressed-ppds`. None of these are tested by CI, and the mod path itself has not been
tested yet (mods are pulled from GHCR, which the development environment could not reach); worth one
manual test.

### The systemd pin

With resolute's apt 3.2 on the LSIO base, `--no-install-recommends cups` does **not** pull systemd
(it picks `dbus-x11`). That is a solver outcome, not a guarantee, so
`root/etc/apt/preferences.d/docker-cups-no-systemd` pins `systemd systemd-sysv dbus-user-session
libpam-systemd` to priority `-1`. It is copied in **before** the apt layer and **kept in the final
image**: a user's `INSTALL_PACKAGES=colord` then fails loudly ("Depends: systemd but it is not going
to be installed") instead of quietly removing the base's `systemd-standalone-sysusers`.

## Build-time hardening

All in the single apt `RUN`, each step asserted so a package change fails the build instead of
silently undoing it:

1. **debconf preseed before install** (`root/etc/cups-image/debconf-selections`):
   `cups cupsys/backend multiselect usb, socket`. cups' postinst links the selected backends from
   `backend-available/` into `backend/`; Ubuntu's default is `lpd, socket, usb, snmp, dnssd`. The
   `dnssd` backend is only for printing **to** discovered printers — cupsd publishes its own queues
   through avahi-client without it.
2. **`apt-get -y upgrade`.** LSIO bases do not upgrade at build, so the base's own libraries (glibc,
   OpenSSL, GnuTLS, …) would otherwise only move with a digest bump. CI fingerprints the upgrade set
   too, so it triggers rebuilds.
3. **Backend trimming to an exact list:** `http https ipp ipps socket usb`. cups-filters installs
   `serial` (root-run, 0744), `parallel`, `beh` and `cups-brf` straight into `backend/`; also removed
   are `driverless`/`driverless-fax` (DNS-SD discovery of IPP printers — `ipp://` + `-m everywhere`
   still works) and `gutenprint53+usb` (0755, so it runs as `lp`, which cannot open root-owned USB
   nodes in a container — it could only fail). A backend runs as **root** iff it is not
   group/world-writable and not world-executable; after trimming that is `usb` alone (0744). The
   network backends are 0755 and run as `lp`.
4. **Snakeoil removal.** ssl-cert's postinst generates a key + self-signed cert at *build* time, so
   every container would share one published private key. Unused by CUPS (it creates its own under
   `ssl/`). The key, the cert and the `/etc/ssl/certs/<hash>.0` link `c_rehash` made are deleted.
5. **D-Bus launch helper.** dbus' postinst registers `dbus-daemon-launch-helper` as
   `root:messagebus 4754` (setuid root). It serves system-bus *activation*, which nothing here uses.
   Neutralised with `dpkg-statoverride root root 0755` (not `chmod`, so a later dpkg run keeps it).
6. **ServerRoot on `/config`:** `mv /etc/cups /defaults/cups && ln -s /config/cups /etc/cups`.
   Verified that cupsd, `lpadmin` and `cups-driverd` work through the symlink, so CUPS' compiled-in
   paths need no change. `cupsd.conf` and `cups-files.conf` are removed from the seed — they are
   always generated — and Ubuntu's stock file stays at `/usr/share/cups/cupsd.conf.default`.
7. **Policy extraction:** the `<Policy default|authenticated|kerberos>` blocks are copied verbatim
   from *this* package version's `cupsd.conf.default` into `/defaults/cupsd-policies.conf`; exactly
   three blocks are asserted. Ubuntu's CVE-patched operation policy is kept exactly, never retyped.
8. **`/package_versions.txt`:** sorted `name=version` for **all** packages (LSIO-style). CI reads the
   CUPS version from the `cups-daemon=` line.

Outside the apt layer: `ENV LSIO_FIRST_PARTY=false` (branding), `ENV S6_BEHAVIOUR_IF_STAGE2_FAILS=2`
(fail closed, below), and static `org.opencontainers.image.*` labels that override **every** label
the LSIO base sets — inherited unchanged they would say "Baseimage-ubuntu", vendor linuxserver.io,
and LSIO's git revision, misattributing this unofficial image. `revision`/`ref.name` are blanked;
CI records the real commit as an index annotation. `BUILD_DATE`/`VERSION` are declared last so they
never invalidate the cached layers.

`HEALTHCHECK`: `LC_ALL=C lpstat -r | grep -qx 'scheduler is running'` over the domain socket. `lpstat
-r` exits 0 whether or not the scheduler runs, hence the text match. `--start-interval=5s` gets
"healthy" quickly on Docker Engine 25+; older engines ignore it.

## Runtime layout

- `/config/cups/` is CUPS' ServerRoot. First boot seeds every top-level entry the volume lacks from
  `/defaults/cups`; existing entries are never overwritten (which is also how a new image adds a new
  default file).
- **Ownership:** cupsd needs `root:lp` and `printers.conf` 0600 — it runs as root and runs filters
  as `lp`. So `/config/cups` is **never** `lsiown -R`'d; only `/config` itself follows `PUID`/`PGID`
  (the base does that, non-recursively). Each boot applies a targeted, non-recursive repair
  (`chown -h`, regular files only, no symlink following): `/config/cups` 0755, `ppd/` 0755, `ssl/`
  0700, `printers.conf`/`classes.conf` 0600, `ppd/*.ppd` 0640. This undoes Unraid's *New
  Permissions* tool or files dropped in from the host, without handing anything to `PUID`/`PGID`.
- **Spool and cache** (`/var/spool/cups`, `/var/cache/cups`) stay in the container layer.
- **Migration** from the old template: if `/config/printers.conf` or `/config/ppd/` exists at the
  **top** of `/config` and `/config/cups/printers.conf` does not, copy `printers.conf`,
  `classes.conf` and `ppd/*.ppd` in (never the old `cupsd.conf`, `cups-files.conf` or `ssl/`), log
  each file with a `MIGRATION:` prefix, leave the originals untouched, and write
  `/config/cups/.imported-from-old-template` so it happens once.

## s6 layout

Under `root/etc/s6-overlay/s6-rc.d/`, all in the `user` bundle:

| Service | Type | Depends on |
|---|---|---|
| `init-cups-config` | oneshot | `init-config` (and `init-config-end` depends on it) |
| `svc-dbus` | longrun | `init-services` |
| `svc-avahi` | longrun | `init-services`, `svc-dbus` |
| `svc-cups` | longrun | `init-services`, `svc-dbus`, `svc-avahi` |
| `init-cups-queue` | oneshot | `svc-cups` |

- **`init-cups-config`** (oneshot): host D-Bus guard → validate every variable → seed/migrate/repair
  `/config/cups` → admin account → generate `cupsd.conf`/`cups-files.conf` → AirPrint
  `avahi-daemon.conf` → stale pid cleanup → security-posture summary. Everything below it depends on
  it through `init-config-end`, so cupsd never starts on bad input.
- **`svc-dbus`** (longrun): with AirPrint on, a **private** system bus:
  `dbus-daemon --system --nofork --nopidfile --nosyslog --print-address=3` with `notification-fd` = 3.
  dbus-daemon writes the address plus a newline to fd 3 only once the socket accepts connections —
  that newline is s6's readiness signal, so svc-avahi and svc-cups start only against a working bus.
  `timeout-up` 30000 turns a bus that never comes up into a failed start instead of a hang. With
  AirPrint off it writes the readiness newline itself and `exec sleep infinity`, so the dependency
  graph stays static (the same idiom as the base's own svc-cron). `dbus-uuidgen --ensure` because the
  image has no `/etc/machine-id`.
- **`svc-avahi`** (longrun): `avahi-daemon --no-proc-title`, foreground, default privilege drop and
  chroot (no capabilities beyond Docker's defaults). Idles like svc-dbus when AirPrint is off.
- **`svc-cups`** (longrun): `exec cupsd -f` as root — never `-l`, where the stock `IdleExitTimeout`
  would make it exit when idle. No readiness signal is possible for an exec'd cupsd.
- **`init-cups-queue`** (oneshot): polls `lpstat -r` for up to 30 s, then the optional `PRINTER_*`
  auto-create. It **always exits 0**: an unplugged printer must never block the print server.
- **`init-adduser/branding`**: the "docker-cups · UNOFFICIAL" banner, kept by `LSIO_FIRST_PARTY=false`.
- Helpers: `/usr/local/bin/cups-env-bool` (stdout is its return value — it prints nothing else
  there; the same rule as openclaw's `openclaw-resolve-bind`), `/usr/local/bin/cups-dbus-guard`, and
  the sourced library `/usr/local/lib/docker-cups/common.sh` (validators print nothing; they return
  0/1 and leave `CUPS_OUT`/`CUPS_WHY`). Every daemon's `run` unsets `CUPS_ADMIN_PASSWORD`.

**Fail closed.** s6-overlay's default `S6_BEHAVIOUR_IF_STAGE2_FAILS=0` keeps the container running
after a failed oneshot — "running, with nothing listening", which an Unraid user cannot see. The
Dockerfile sets `2`: the container stops (exit 1) and the error list is the last thing in the log.
If a user overrides it to 0, cupsd still never starts, because of the dependency chain.

**Why the svc-dbus `finish` script waits.** If dbus-daemon dies, cupsd's avahi client sees the
disconnect, immediately tries to reconnect — to a bus that is not back yet — fails, and gives up for
good: DNS-SD stays dead until cupsd is reloaded. (avahi-daemon restarting on its own is handled by
cupsd.) A SIGHUP sent from `finish` itself lands while the bus is still down and fails the same way,
and s6 does not restart the service until `finish` returns. So `finish` checks that svc-dbus is
still *wanted* up (a shutdown is not a crash) and that cupsd is up, then starts a double-forked
waiter: `s6-svwait -U -t 60000 svc-dbus && s6-svc -h svc-cups`. Verified with
`pkill -KILL dbus-daemon`: DNS-SD comes back, cupsd keeps its PID, no zombies.

**Stale pid files.** s6-overlay does not wipe `/run` on `docker restart`, so `/run/dbus/pid`,
`/run/dbus/system_bus_socket` and `/run/avahi-daemon/pid` survive (in testing avahi even came back
with the very PID its stale file named). They are removed before start — but only after the host
D-Bus guard has passed.

**Host D-Bus guard.** Reads `/proc/self/mountinfo` for anything mounted at or below `/run/dbus` or
`/var/run/dbus` (a single bind-mounted `system_bus_socket` counts) and refuses to start, deleting
nothing. Running our own dbus-daemon on top of the host's would unlink the host's socket, and a
working host bus would hand every process here — print filters included — the host's system bus.
Runs first in `init-cups-config` and again in `svc-dbus`.

## Generated configuration

With `CUPS_MANAGED_CONFIG=true` (default), `cupsd.conf` and `cups-files.conf` are rendered on
**every** boot, written atomically (`mktemp` + `mv`), `root:lp` 0640. With `false` each is rendered
once from the current environment if missing (the hardened, env-reflecting baseline — not Ubuntu's
localhost-only stock file) and then left alone, with a loud warning every boot that the access, admin
and TLS settings are no longer enforced.

`cupsd.conf` contains: `LogLevel`, `PageLogFormat` (empty, as Ubuntu ships it — so `PageLog stderr`
emits no page-accounting lines), `MaxLogSize 0`, `ErrorPolicy retry-job`, `DirtyCleanInterval 0`,
`Listen /run/cups/cups.sock`, `Port 631`, `ServerName`, `ServerAlias` per alias, `ServerTokens None`,
optional `HostNameLookups Double`, `DefaultPaperSize`, `WebInterface`, `Browsing` +
`BrowseLocalProtocols` (`dnssd` or `none`), `DefaultShared Yes`, `DefaultAuthType Basic`,
`DefaultEncryption Required`, `<Location />` (allow localhost + `CUPS_ALLOWED_NETWORKS`),
`<Location /admin|/admin/conf|/admin/log>` (`AuthType Default`, `Require user @SYSTEM`, `Encryption
Required`, localhost + `CUPS_ADMIN_NETWORKS` only when an admin is configured), then Ubuntu's three
policy blocks verbatim.

`cups-files.conf`: `SystemGroup lpadmin root`, `AccessLog`/`ErrorLog`/`PageLog stderr`,
`FileDevice No`, `ServerKeychain ssl`; `Sandboxing` and `CreateSelfSignedCerts` keep their compiled-in
defaults (strict / yes).

Decisions that differ from the obvious choice, with the reason each was tested:

- **`DefaultEncryption Required`, not `IfRequested`.** With `IfRequested`, a 401 on a non-`/admin`
  resource (IPP Pause-Printer or CUPS-Get-Document on `/printers/NAME`, say) is answered over plain
  http and the client sends Basic credentials in cleartext. `Required` turns every non-local
  unencrypted 401 into a `426` redirect to https. `/admin` behaviour (http 426, https 401/200) is
  unchanged.
- **`SystemGroup lpadmin root`.** cupsd's `@SYSTEM` check has no root bypass: with `lpadmin` alone,
  `docker exec <c> lpadmin …` (root over the domain socket) returned `lpadmin: Forbidden`. Ubuntu's
  stock file lists root too. Remote root login stays impossible: root's password is locked and
  `CUPS_ADMIN_USER=root` is refused.
- **`DirtyCleanInterval 0`.** A queue created by `PRINTER_*` and then `docker rm -f` within cupsd's
  default 30 s write delay was lost (`printers.conf` never written). With 0, changes reach `/config`
  immediately; verified to survive a SIGKILL recreate.
- **`HostNameLookups Double` when a name is used in an Allow list.** cupsd matches name rules only
  after a reverse lookup; with the default `Off` such tokens would silently never match. `Double`
  also checks the forward lookup.
- **An explicit `ServerName`, always.** It is the TLS keychain CN, so the certificate stays the same
  across recreates even without `--hostname` (verified: same SHA-256 fingerprint). Docker's default
  hostname is the container ID, which changes on every recreate — iOS would then report changed
  credentials — so a 12-hex-character hostname (or one that is not a valid DNS label) falls back to
  `unraid-cups`. In AirPrint mode it is `<name>.local`. An explicit `ServerName` disables cupsd's
  automatic hostname alias, so the bare name and the container hostname are re-added as
  `ServerAlias` (otherwise `http://unraid-cups:631/` would get a 400).
- **`ServerTokens None`** removes the `Server:` header. CUPS' built-in HTML error pages still carry
  `CUPS v2.4.16` in their `<title>` (compiled in, not configurable).

### Validation

Empty == unset everywhere. Every value is checked for control characters **first** (a newline in a
value that reaches `cupsd.conf` would be a second, attacker-chosen directive); all errors are
collected and printed together, values `%q`-escaped so an injected newline cannot forge a log line.

- Booleans: `true/false/yes/no/on/off/1/0`, case-insensitive; anything else (even surrounding
  spaces) is an error.
- Allow tokens: `@LOCAL`, `@IF(name)`, IPv4 `a.b.c.d[/1-32]` (no leading zeros, no partial
  shorthands, no dotted netmasks), IPv6 `[addr][/1-128]` (RFC 4291 forms), `localhost`, host names,
  `*.domain` / `.domain`. Refused: `all`, `none`, `*`, `any`, `everyone`, `/0`, names starting with a
  digit (cupsd would parse them as addresses). Tokens are normalised and de-duplicated; `localhost`
  is always first.
- `CUPS_SERVER_ALIASES`: dotted DNS names; `*` refused (it disables the Host-header check, which is
  cupsd's DNS-rebinding defence).
- Enumerations: paper size (Letter, Legal, Executive, Tabloid, Statement, A3–A6 — names that are the
  same in cupsd, PPDs and the IPP Everywhere generator), log level.
- `PRINTER_*` (only when NAME and MODEL are both set): queue name `[A-Za-z0-9_][A-Za-z0-9_.-]{0,126}`
  (stricter than CUPS, so it is safe in URLs, file names and logs); model: a strict charset, no
  whitespace or quotes; URI: `usb|socket|ipp|ipps|http|https` only, no whitespace, quotes or control
  characters; description/location: IPP `text(127)`; options: `key=value`, key
  `[A-Za-z][A-Za-z0-9._-]{0,63}`, value 1–255 chars without whitespace, quotes, backslash or backtick,
  each passed as one `-o` argv element. Nothing is ever `eval`'d, sourced or word-split from the
  environment.

### The admin account

Created with `useradd --system --no-create-home --shell /usr/sbin/nologin --gid lpadmin` and the GECOS
marker `docker-cups admin account`; cupsd authenticates it through PAM. The password goes in via
`chpasswd` on stdin (never argv) on every boot, so rotation + restart works. The marker is how "an
account we created on an earlier boot" is recognised across `docker restart` (the container layer
keeps `/etc/passwd`): marker accounts that are no longer wanted (admin disabled or renamed) are
deleted. Any existing account **without** the marker — not only uid < 1000; `messagebus` and `avahi`
included — is refused, because giving a password and `lpadmin` membership to an account something
else relies on is a quiet privilege change. Admin problems are soft by design (logged as errors,
admin disabled, container keeps running): they must never take printing down.

`/run/s6/container_environment/CUPS_ADMIN_PASSWORD` (and the `FILE__` variant) is narrowed to 0600
— s6-overlay writes the environment world-readable, and print filters run as `lp` on untrusted
documents.

## AirPrint internals

- cupsd publishes DNS-SD through **avahi-client → D-Bus system bus → avahi-daemon**, so the order is
  dbus → avahi → cupsd, which is exactly the s6-rc chain.
- iOS requirements are met natively by CUPS 2.4 for a **shared, PPD-driven (non-raw)** queue:
  `_ipp._tcp`/`_ipps._tcp` with the `_universal` subtype (`BrowseDNSSDSubTypes` defaults to
  `_cups,_print,_universal`) and a `URF` TXT key synthesised from the PPD. For the M203:
  `URF=V1.4,CP1,W8,PQ4,RS600,DM1,FN3`, Duplex=T, monochrome. It needs a non-localhost listener,
  `Browsing Yes` and `BrowseLocalProtocols dnssd`.
- cupsd caches avahi's host name (the SRV target of every record) at the first callback and never
  refreshes it. If avahi renamed itself after a collision ("cups" → "cups-2"), the records would
  point at another machine — so the default name must be **distinctive** (`unraid-cups`, not `cups`).
- `avahi-daemon.conf` (generated): `host-name`, `use-ipv4=yes`, `use-ipv6=no` (IPv6 link-local mDNS
  through macvlan/ipvlan is a classic source of duplicate unreachable records), `publish-hinfo=no`,
  `publish-workstation=no`, `disallow-other-stacks=yes` (refuse to share UDP 5353 rather than
  half-work, e.g. under host networking on a host with its own responder), `enable-wide-area=no`,
  `enable-reflector=no`; `allow-interfaces` unset — inside the container's namespace every interface
  is one the user attached.
- **Unraid networking.** Bridge mode cannot carry mDNS. AirPrint mode is a custom network: `br0`
  (ipvlan L2 by default on new installs since 6.11.5) or `eth0`/`bond0` (macvlan when bridging is
  disabled), with a fixed IP and `--hostname`. In bridge mode iptables DNAT preserves the LAN
  client's real source address, so `Allow @LOCAL` does **not** match LAN clients there — hence the
  explicit private-range CIDRs in the default. On br0, LAN clients are on the container's own subnet
  and `@LOCAL` matches them.
- Verified: process order dbus < avahi < cupsd; `ippfind _ipp._tcp,_universal` finds `M203 @
  unraid-cups` with the URF above (also `_ipps`, `_print`), inside the container and from a peer
  over multicast; survives `docker restart`; recovers after `pkill -KILL dbus-daemon`.

## USB

- Bind `/dev/bus/usb:/dev/bus/usb:ro` + `--device-cgroup-rule='c 189:* rmw'` — the same recipe
  OpenPrinting documents for its ipp-usb rock. A read-only bind still allows opening the char
  devices read-write. The `usb` backend re-discovers the printer by make/model/serial on each job, so
  device-number changes after power cycles are fine.
- Hardened alternative (documented only): bind just the printer's bus directory and add
  `--cap-drop=MKNOD`. The cgroup rule cannot restrict minors to one bus, and Docker's default
  capability set includes `MKNOD`, so without the drop root in the container could create nodes for
  the other buses.
- Autodetect (`PRINTER_URI` empty): `/usr/lib/cups/backend/usb` with no arguments lists devices as
  `direct usb://… "make model" …`; the result is used only if exactly one `usb://` device appears.
- No supply levels over libusb with the M203's PPD (`*cupsIPPSupplies: False`).
- Untested here: real USB hardware (none in the sandbox, so only the zero-device path ran) and the
  libusb backend's `usblp` detach inside a container.

## The HP M203-M206 driver path

- Driver: `postscript-hp:0/ppd/hplip/HP/hp-laserjet_pro_m203_m206-ps.ppd` — "HP LaserJet Pro
  M203-M206 Postscript (recommended)". `lpinfo -m` also lists a `postscript-hp:1/…` twin; `:0` is the
  one used throughout.
- Chain: PDF → `pdftopdf` → `pdftops` (Ghostscript `ps2write`) → `hpps` → `usb`. URF input from iOS:
  `pwgtopdf` → same.
- Pass `-m` explicitly: automatic matching fails if the device reports `MFG:Hewlett-Packard`.
- `lpadmin -E` must come **after** `-p`; before it, it means "force encryption".
- **EconoMode quirk:** `hpps` writes `@PJL SET ECONOMODE=ON` whenever `HPPJLEconoMode` appears in the
  job options, and Ubuntu's auto-presets always add `HPPJLEconoMode=False`. Re-verified 2026-10-18 on
  a captured stream: the header carries `@PJL SET ECONOMODE=ON`, then `@PJL ENTER
  LANGUAGE=POSTSCRIPT`, then the PPD's own JCL (a UEL and `@PJL JOB NAME = … DISPLAY = …`, emitted by
  the `pdftops` filter) ahead of the PostScript. That UEL very likely cancels the setting. Documented, deliberately **not** patched in the image (patching HP's PPDs
  would fork them from Ubuntu's updates).
- `lpadmin` on any PPD queue prints "Printer drivers are deprecated …" (the CUPS 3.x roadmap note);
  `init-cups-queue` filters that line out of the log.

## Publish gate and tagging (CI)

The CI mirrors docker-openclaw's machinery (`build.yml`, `ci.yml`, `gate.sh`, `smoke.sh`, Dependabot
+ auto-merge, actions pinned by SHA) with the inputs adapted to an image built from Ubuntu packages
instead of an upstream image:

- **Inputs fingerprint** = sha256 of `git rev-parse HEAD:Dockerfile HEAD:root HEAD:.dockerignore`
  **plus** the sorted `pkg=version` list that `apt-get -s -y upgrade` + `apt-get -s install
  --no-install-recommends <packages.txt>` resolves to **inside the pinned base** (with the systemd
  pin in place, since it changes resolution). Content, not `$GITHUB_SHA`, for openclaw's reason: a
  docs commit must not republish an image that differs only in `BUILD_DATE`.
- The package-list hash is passed as the **`APT_FINGERPRINT`** build-arg, declared directly above
  the apt `RUN` so it joins that layer's cache key: the layer re-runs exactly when an Ubuntu package
  version changes, and a warm gha cache can never ship stale packages under a fresh label. It must be
  passed identically to the smoke build and the push build. This replaces openclaw's monthly
  `APT_EPOCH`: here the packages *are* the product, so "rebuild when Ubuntu publishes" is both
  tighter and quieter than "rebuild monthly".
- `packages.txt` is the single source of truth for both, chosen over parsing the Dockerfile (a regex
  over a shell heredoc would be a second copy that nothing checks). After the build,
  `gate.sh --check-image` proves the image's `/package_versions.txt` contains every version the
  fingerprint claims, so a drift between the simulation and the real apt step is a red run, not a
  silently stale fingerprint. A resolution that fails or comes back empty also fails the run: an
  empty list would hash to a constant and security updates would quietly stop shipping.
- Stored as the OCI **index annotation** `io.cookiesncache.inputs` on the published index and
  compared on each **daily** run; publish only on change (push to `main` on build-input paths and
  `workflow_dispatch` with `force` also run it). Same rationale as openclaw: no phantom updates for
  Unraid users, no external state.
- Order: gate → local build (`--load`) → smoke → build + push → verify the pushed digest is the
  smoke-tested one → verify the manifest is readable.
- **Tags:** `:latest`; `:<upstream CUPS version>` (e.g. `:2.4.16`), floating; and the immutable
  `:<Ubuntu package version>-ls<run_number>` (e.g. `:2.4.16-1ubuntu1.3-ls12`, sanitised to the tag
  charset), never re-pushed — what the README tells people to pin. The `-ls` counter exists because
  Ubuntu ships security fixes as new revisions of one CUPS version and base/library updates produce
  new images at an unchanged version. Annotations: revision, created, version, base digest, inputs
  fingerprint.
- `ci.yml` (`pr-smoke`, every pull request): shellcheck all shell scripts (with `-x`: the scripts
  source `/usr/local/lib/docker-cups/common.sh` via `source-path=SCRIPTDIR` directives), check that
  `templates/cups.xml` is well-formed XML, build (never pushed), smoke. No floating inputs that could
  turn unrelated PRs red (the lesson of openclaw PR #29).
- `upstream-watch.yml` (weekly + dispatch): reads OpenPrinting/cups' latest release tag and opens an
  issue `Upstream CUPS <tag> released` (once) with a checklist — check Ubuntu's package/USN status;
  the rebuild itself happens automatically when Ubuntu ships.
- Dependabot: `github-actions` + `docker` (the base digest), weekly, cooldown as in openclaw.

### Smoke-test notes (learned the hard way)

- `ippeveprinter` needs a reachable D-Bus system bus (`avahi_client_new` in `dnssd_init` is
  unconditional, even with `-r off`): run the IPP Everywhere end-to-end test inside a
  `CUPS_AIRPRINT=true` container, or start a private dbus-daemon first. It also treats a failed IPv6
  listener as fatal — fine on GitHub runners, but a kernel without IPv6 needs a shim.
- CUPS job IDs are global across queues: assert on `<queue>-` and completion, not `<queue>-1`.
- The TLS certificate is created lazily on the first https handshake (~0.25 s): do one handshake
  before comparing fingerprints, and do not connect immediately after `docker network connect`.
- Use the `has()` here-string matcher, never `grep -q` in a pipe under `pipefail`.

## LinuxServer conventions

`PUID`/`PGID`/`UMASK`/`TZ` are delegated to the base image; there is no `CMD`/`ENTRYPOINT` (the
base's `/init` is PID 1 and reaps zombies). Custom-image branding is required for non-official images
on the LSIO base, per LinuxServer's
[container-branding docs](https://docs.linuxserver.io/general/container-branding/): this image ships
`root/etc/s6-overlay/s6-rc.d/init-adduser/branding` (unofficial; not affiliated with LinuxServer.io
or OpenPrinting) and sets `ENV LSIO_FIRST_PARTY=false` so the base init does not overwrite it.

Docker Mods work as usual. The systemd pin stays active for them (see above), and the mod's apt runs
at container start, after the image's own hardening — packages installed that way are outside the
build-time assertions (a mod-installed backend would not be trimmed, for instance).

## Open upstream issues to track

- **CUPS 2.4.20 (2026-10-05) security fixes not yet in Ubuntu.** As of 2026-10-17 resolute ships
  `2.4.16-1ubuntu1.3` (latest Ubuntu entry 2026-06-11), without the 2.4.20 batch of scheduler fixes
  (rated up to 5.7). Watch the [Ubuntu cups source package](https://launchpad.net/ubuntu/+source/cups)
  and USNs; the daily fingerprint picks the update up automatically.
- **PPD deprecation.** CUPS prints "Printer drivers are deprecated" on every PPD queue; the CUPS 3.x
  line drops PPD drivers in favour of Printer Applications. This image is PPD-based (the M203 has no
  IPP-over-USB, so a Printer Application would be the eventual path). Nothing to do while Ubuntu
  ships CUPS 2.4.
- **`hpps` EconoMode PJL** (HPLIP / `printer-driver-postscript-hp`): see above.
- **cups-browsed** stays excluded regardless of upstream fixes; revisit only if a use case appears.
