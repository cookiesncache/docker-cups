# docker-cups

[![build](https://github.com/cookiesncache/docker-cups/actions/workflows/build.yml/badge.svg)](https://github.com/cookiesncache/docker-cups/actions/workflows/build.yml)

A [LinuxServer.io](https://www.linuxserver.io/)-style Docker image for the
[CUPS](https://github.com/OpenPrinting/cups) print server, built to share a USB printer from Unraid
with the computers and phones on your LAN — optionally with AirPrint.

> ⚠️ **Unofficial.** This is an independent, community-maintained image. It is **not** affiliated with,
> maintained by, or endorsed by OpenPrinting (the CUPS project) **or** LinuxServer.io — it simply
> follows LinuxServer's conventions (`PUID`/`PGID`, s6-overlay, `/config`) and mirrors their GPL-3.0
> license. CUPS itself comes unmodified from Ubuntu 26.04's packages.

## Why this image

The Unraid CUPS template many people still run (`josecoelho/unraid-templates` → `ydkn/cups`) was
last touched in 2021 and ships a configuration nobody should run today:

| Old template | This image |
|---|---|
| Admin login `admin`/`admin` | **No default password.** Remote administration is off until you set your own credentials |
| Remote administration from anywhere | Admin pages only over **https**, only from networks you allow |
| `ServerAlias *` (accepts any `Host:` header) | Explicit aliases only — keeps CUPS' DNS-rebinding protection |
| Host `/var/run/dbus` mounted **read-write** | A private D-Bus inside the container, only when AirPrint is on. The container **refuses to start** if a host D-Bus is mounted |
| One hard-coded USB device node (`/dev/bus/usb/003/009`) | The USB bus mapped read-only + a device rule, so the printer keeps working after it is power-cycled and renumbered |
| Unmaintained | CUPS from Ubuntu 26.04, rebuilt when Ubuntu ships updates |

And beyond fixing those:

- **Fail-closed configuration** — an access-control value the image cannot parse (`all`, a typo'd
  network, a newline smuggled into a variable) stops the container with a clear error instead of
  running with something you did not mean
- **Optional AirPrint** for iPhone, iPad and Mac, with the D-Bus → Avahi → CUPS chain supervised by
  s6 and self-healing if D-Bus restarts
- **Optional queue auto-create** from `PRINTER_*` variables, with an HP LaserJet Pro M203-M206 example
- **Lean**: no `cups-browsed` (the 2024 remote-code-execution chain's entry point), no colord, no
  systemd; only the USB backend runs as root
- Queues, PPDs and the TLS certificate persist under **`/config`**
- **Docker Mods, custom scripts/services, and `FILE__` secrets** — inherited from the LinuxServer base
- **amd64** (see [Limitations](#limitations))

## Install

### Unraid (Community Applications)

Search Community Applications for **cups** and pick the one from **cookiesncache**. Then:

1. Set **`CUPS_ADMIN_PASSWORD`** if you want to manage printers from your browser (the template
   pre-fills `CUPS_ADMIN_USER=printadmin`). Leave it empty to keep remote administration off; the
   log then warns that both are needed, which is expected.
2. Keep `/dev/bus/usb` mapped and keep the template's **Extra Parameters**
   (`--device-cgroup-rule='c 189:* rmw' --hostname=unraid-cups`) — both matter, see
   [USB printers](#usb-printers).
3. Keep `CUPS_SERVER_ALIASES=tower` (or your server's name) so `http://tower:631/` works.
4. For AirPrint, read [AirPrint](#airprint) before you start — it needs a different network type.

Coming from the old CUPS template? Read [Migrating from the old CUPS template](#migrating-from-the-old-cups-template)
first.

### docker-compose

```yaml
services:
  cups:
    image: ghcr.io/cookiesncache/cups:latest
    container_name: cups
    hostname: unraid-cups                     # stable TLS certificate / AirPrint name
    environment:
      - PUID=1000
      - PGID=1000
      - TZ=Etc/UTC
      - CUPS_ADMIN_USER=printadmin
      - CUPS_ADMIN_PASSWORD=change-me-to-something-long
      - CUPS_SERVER_ALIASES=myserver          # the name you type in the browser
    volumes:
      - ./config:/config
      - /dev/bus/usb:/dev/bus/usb:ro
    device_cgroup_rules:
      - 'c 189:* rmw'
    ports:
      - 631:631
    restart: unless-stopped
```

A commented `docker-compose.yml` is in this repo. The web interface is at `https://<host>:631/` —
your browser warns about the self-signed certificate once; accept it. (Plain `http://` works for
printing and browsing, but not for the admin pages, see [Security](#security).)

## Configuration

Every variable is read on each container start: change it, restart, done. **Empty means unset**
(Unraid passes blank template fields through as empty strings), so an empty field always gets the
default below. Booleans accept `true`/`false`, `yes`/`no`, `on`/`off`, `1`/`0` in any case; anything
else is an error.

**Invalid values stop the container.** Every `CUPS_*` and `PRINTER_*` value is validated before CUPS
starts; if anything is wrong, all problems are listed together in `docker logs` and the container
exits. The admin account is the one exception: a reserved or malformed `CUPS_ADMIN_USER`, or an
unusable `CUPS_ADMIN_PASSWORD`, is logged as an error and only disables remote administration, so it
can never take printing down. (A control character such as a newline stops the container in any
variable except the password.)

### Environment variables

| Variable | Default | Description |
|---|---|---|
| `PUID` / `PGID` | `911` | User/group that owns the `/config` folder itself. Unraid: `99`/`100`. See [Limitations](#limitations) for why `/config/cups` stays `root:lp`. |
| `UMASK` | `022` | Umask for created files. |
| `TZ` | — | Timezone, e.g. `America/New_York`. |
| `CUPS_ADMIN_USER` | — | Login for the admin pages (`/admin`) and IPP administration. Created on every start as a no-login system account in group `lpadmin`. Must be a plain Linux user name (lower-case letters, digits, `_`, `-`; max 31) and must **not** be an account that already exists in the image (`root`, `lp`, `lpadmin`, `abc`, `nobody`, `daemon`, `messagebus`, `avahi`, …) — those are refused with an error. |
| `CUPS_ADMIN_PASSWORD` | — | Its password. Applied on every start, so changing it and restarting takes effect. Never logged. Supports `FILE__CUPS_ADMIN_PASSWORD` (a trailing newline in the file is ignored; keep that file root-owned `0600` on the host — the log warns if the print filters could read it). A warning is logged if it is shorter than 12 characters. **Both** user and password must be set, or remote administration stays off. |
| `CUPS_ALLOWED_NETWORKS` | `@LOCAL 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 [fc00::]/7` | Who may print and browse. Space- and/or comma-separated: CIDRs (`192.168.1.0/24`), single addresses, `[IPv6]` or `[IPv6]/len`, `@LOCAL`, `@IF(eth0)`, host names (`laptop.lan`) and domains (`*.lan` or `.lan`). `localhost` is always allowed. `all`, `none`, `*`, `any` and `/0` are refused, as are partial addresses (`192.168`) and IPv6 ranges that overlap `::/96` (`[::]/64`, `[::]/97`, say — CUPS compares IPv4 clients as `::a.b.c.d`, so such a range admits all or part of the IPv4 address space; write IPv4 networks as `a.b.c.d/len`). Using a host or domain name turns on reverse-DNS checks (`HostNameLookups Double`). |
| `CUPS_ADMIN_NETWORKS` | same as `CUPS_ALLOWED_NETWORKS` | Who may reach `/admin`, `/admin/conf` and `/admin/log` (login and https are still required). Same format. **Ignored** — admin is `localhost` only — unless an admin user and password are configured. |
| `CUPS_SERVER_ALIASES` | — | Extra names accepted in the browser's `Host:` header, e.g. `tower`. IP addresses, `localhost`, `*.local` and the server's own name already work. `*` is refused. |
| `CUPS_PAPER_SIZE` | `Letter` | Server default paper size, and the `PageSize` default of queues created by `PRINTER_*`. One of `Letter`, `Legal`, `Executive`, `Tabloid`, `Statement`, `A3`, `A4`, `A5`, `A6` (any case). |
| `CUPS_LOG_LEVEL` | `warn` | cupsd log level: `none`, `emerg`, `alert`, `crit`, `error`, `warn`, `notice`, `info`, `debug`, `debug2`. |
| `CUPS_WEB_INTERFACE` | `true` | Turns the web interface on or off. Printing is not affected. |
| `CUPS_AIRPRINT` | `false` | `true` runs a private D-Bus + Avahi and advertises shared queues over mDNS/DNS-SD. Needs a custom network — see [AirPrint](#airprint). |
| `CUPS_AIRPRINT_HOSTNAME` | container hostname | The server's name: the CN of its TLS certificate and, with AirPrint, its mDNS name (`<name>.local`). One DNS label. If unset and the hostname is Docker's random container ID, `unraid-cups` is used instead (and the log says so). The certificate is made for this name once and kept in `/config/cups/ssl`; a different name means a different certificate, which clients that remembered the old one will question. |
| `CUPS_MANAGED_CONFIG` | `true` | `true`: `cupsd.conf` and `cups-files.conf` are regenerated from these variables on every start. `false`: they are written once and then left alone for you to edit — the image **no longer enforces** the access, admin or TLS settings, and says so in the log on every start. That includes the `cupsd.conf` side of `CUPS_AIRPRINT` (`Browsing`, `BrowseLocalProtocols`, `ServerName`): turning AirPrint on later starts D-Bus and Avahi, but nothing is advertised until your file says so (the log warns). Experts only. |
| `PRINTER_NAME` | — | Optional queue auto-create (see [Adding a printer](#adding-a-printer)). All `PRINTER_*` are ignored unless `PRINTER_NAME` **and** `PRINTER_MODEL` are set. Letters, digits, `_`, `.`, `-`; max 127. |
| `PRINTER_MODEL` | — | The driver, exactly as `lpinfo -m` lists it, e.g. `postscript-hp:0/ppd/hplip/HP/hp-laserjet_pro_m203_m206-ps.ppd`, or `everywhere` for IPP Everywhere network printers. |
| `PRINTER_URI` | — | Where the printer is: `usb://…`, `socket://…`, `ipp://…`, `ipps://…`, `http://…` or `https://…`. Empty: autodetect a USB printer — used only if **exactly one** is found. A network printer's credentials may be part of it (`ipps://user:password@printer/…`): the log shows them as `***`, but like every variable they are visible to anyone who can `docker inspect` the container. |
| `PRINTER_DESCRIPTION` / `PRINTER_LOCATION` | — | Description and location shown to clients. Max 127 characters. Applied when the queue is created. |
| `PRINTER_OPTIONS` | — | Extra queue defaults, space-separated `key=value` pairs, e.g. `Duplex=DuplexNoTumble`. Applied when the queue is created. |

### Volumes & ports

| Path / Port | Purpose |
|---|---|
| `/config` | Persistent data. `/config/cups/` is CUPS' configuration directory: `printers.conf`, `classes.conf`, `subscriptions.conf`, `ppd/`, `ssl/` (the self-signed certificate), and the generated `cupsd.conf` / `cups-files.conf`. |
| `/dev/bus/usb` (read-only) | USB printers. Needs `--device-cgroup-rule='c 189:* rmw'`. |
| `631/tcp` | IPP printing, IPPS and the web interface — all on one port. **LAN only.** |

The print spool is not persisted: jobs still waiting when the container is *recreated* (an image
update, a template change) are lost. A plain restart keeps them.

## USB printers

Map the whole USB device tree **read-only** and allow the container to open USB device nodes:

```bash
-v /dev/bus/usb:/dev/bus/usb:ro --device-cgroup-rule='c 189:* rmw'
```

The Unraid template does exactly this (the path mapping plus **Extra Parameters**). Why not map the
printer's device node directly, like the old template did? Because its number changes: switch the
printer off and on, or replug it, and `/dev/bus/usb/003/009` becomes `/dev/bus/usb/003/010`.
A bind-mounted directory follows the host's view, and CUPS' USB backend finds the printer again by
make, model and serial number on every job. Read-only is enough: a device node on a read-only mount
can still be opened for reading and writing, which is all printing needs.

No `--privileged` and no extra capabilities are needed.

**Hardened variant (optional).** The rule above lets the container's root open *any* USB device on
the host (major 189), not only the printer. To narrow it, map only the printer's bus and remove the
container's ability to create device nodes:

```bash
-v /dev/bus/usb/003:/dev/bus/usb/003:ro --device-cgroup-rule='c 189:* rmw' --cap-drop=MKNOD
```

Find the bus number with `lsusb` on the host (`Bus 003 Device 009: ID 03f0:632a HP, Inc …`). The
`--cap-drop=MKNOD` is what makes this meaningful: the cgroup rule cannot be limited to one bus, so
without it root in the container could `mknod` the other buses' nodes. The trade-offs: other devices
on the same bus are still reachable, and if you move the printer to a port on another bus you must
update the mapping.

## Adding a printer

Find the printer first (it must be switched on):

```bash
docker exec cups lpinfo -v
# direct usb://HP/LaserJet%20Pro%20M203-M206?serial=VNB1234567
```

Then use any of the three ways below. Whichever you use, the queue must be **shared** for other
computers to print to it (this image shares queues by default).

### In the web interface

Requires `CUPS_ADMIN_USER` + `CUPS_ADMIN_PASSWORD`.

1. Open `https://<server>:631/admin` — https, because the admin pages refuse plain http. Type the
   https address yourself (the Unraid **WebUI** button already does): the `426 Upgrade Required`
   redirect CUPS sends from `http://` points at the container's own address, which in bridge mode
   is an internal Docker IP your browser cannot reach. Your browser warns about the self-signed
   certificate once; accept it.
2. **Add Printer**, log in with your admin credentials, pick the USB printer under *Local Printers*.
3. Give it a name, description and location, and leave **Share This Printer** ticked.
4. Choose the make and model. For the HP LaserJet Pro M203-M206: **HP** → **HP LaserJet Pro
   M203-M206 Postscript (recommended)**.
5. Set the default options (paper size!).

### With `PRINTER_*` variables

Creates the queue on startup if it does not exist yet. Example for an HP LaserJet Pro M203-M206 on
USB:

```
PRINTER_NAME=M203
PRINTER_MODEL=postscript-hp:0/ppd/hplip/HP/hp-laserjet_pro_m203_m206-ps.ppd
PRINTER_URI=
PRINTER_DESCRIPTION=HP LaserJet Pro M203
PRINTER_LOCATION=Office
PRINTER_OPTIONS=Duplex=DuplexNoTumble
```

`PRINTER_URI` is left empty here, which means "autodetect the one USB printer"; set it to the
`usb://…` line from `lpinfo -v` if you have more than one.

The queue is created enabled, shared, with error policy `retry-job` and `PageSize` =
`CUPS_PAPER_SIZE`, and becomes the default destination if there is none. From then on it is
**yours**: on later starts the only thing the container changes is the device URI, when
`PRINTER_URI` is set (or a single USB printer is detected) and differs. Options you change in the web
UI or with `lpadmin` are never overwritten.

Auto-create never blocks startup. If the printer is off or several USB printers are found, the log
says so and CUPS starts without the queue; restart once the printer is on, or set `PRINTER_URI`.
Driver names are long and exact — copy them from `docker exec cups lpinfo -m`. Always naming the
driver is deliberate: automatic matching can miss the M203, depending on whether it reports its maker
as `HP` or `Hewlett-Packard`.

### From the command line

`docker exec` runs as root over CUPS' local socket, which works without any admin credentials:

```bash
docker exec cups lpadmin -p M203 -E \
  -v 'usb://HP/LaserJet%20Pro%20M203-M206?serial=VNB1234567' \
  -m postscript-hp:0/ppd/hplip/HP/hp-laserjet_pro_m203_m206-ps.ppd \
  -o printer-is-shared=true -o PageSize=Letter
docker exec cups lpadmin -d M203          # make it the default
```

`-E` must come **after** `-p` (before it, it means "force encryption" rather than "enable").

### On the clients

Queues are reachable as `ipp://<server>:631/printers/<queue>` (on Windows, "Select a shared printer
by name" accepts `http://<server>:631/printers/<queue>`). With [AirPrint](#airprint) on, Apple
devices find them on their own.

## AirPrint

AirPrint discovery uses multicast DNS, which **cannot cross Docker's bridge network**. The container
has to sit on your LAN with its own IP address:

1. **Network Type:** `Custom: br0` (Unraid's default custom network; ipvlan on new installs since
   6.11.5) — or `Custom: eth0` / `bond0` if you have disabled bridging (macvlan).
2. **Fixed IP address:** an unused address on your LAN, outside your router's DHCP range (or
   reserved there).
3. **Keep `--hostname=unraid-cups`** in Extra Parameters, or choose your own name. It is the name
   Apple devices show (e.g. `M203 @ unraid-cups`) and the name in the certificate they remember —
   changing it later makes them treat the printer as a new one.
4. Set **`CUPS_AIRPRINT=true`** and start the container.
5. The queue must be **shared** and use a **driver** (a PPD such as the M203's, or `everywhere`) —
   raw queues are not advertised as AirPrint printers.

On br0 the port mapping is ignored (the container listens on 631 on its own IP) and the default
`CUPS_ALLOWED_NETWORKS` already covers your LAN via `@LOCAL`.

Things that break discovery outside the container's control:

- **Different VLAN or subnet.** mDNS stays within one network segment unless your router runs an
  mDNS reflector/repeater. Phones on a separate IoT or guest VLAN will not see the printer.
- **Wi-Fi client isolation** ("AP isolation", most guest networks) blocks both discovery and printing.
- **Managed (MDM) iPhones and iPads** whose profile requires trusted certificates for AirPrint refuse
  the self-signed certificate this image uses.
- **The Unraid host cannot reach containers on br0** unless *Settings → Docker → Host access to custom
  networks* is enabled. That only matters if the server itself, or containers in bridge mode, need
  to print to it.
- **Host networking is not supported** for AirPrint: on a host that already runs an mDNS responder
  the container's Avahi would have to share UDP port 5353 with it, and it is configured to refuse
  that (and keep failing) rather than half-work.

Harmless log lines you may see with AirPrint on: dbus-daemon `Failed to set fd limit to 65536`,
Avahi `No NSS support for mDNS detected`, and cupsd `CreateProfile`/`CreateDevice failed …
org.freedesktop.ColorManager` (the colour manager is deliberately not installed).

## Extra drivers

The image ships drivers for HP PostScript printers (`printer-driver-postscript-hp`, which covers the
M203-M206), Gutenprint, Brother lasers (brlaser) and Samsung/Xerox SPL printers (SpliX), plus IPP
Everywhere for driverless network printers. More are available from Ubuntu with LinuxServer's
[universal-package-install](https://github.com/linuxserver/docker-mods/tree/universal-package-install)
mod:

```
DOCKER_MODS=linuxserver/mods:universal-package-install
INSTALL_PACKAGES=printer-driver-hpcups|foomatic-db-compressed-ppds
```

| Package | What it adds | Notes |
|---|---|---|
| `printer-driver-hpcups` | HP's hpcups raster driver (inkjets, PCL lasers) | +57 MiB including Perl. Does not cover the M203 — its PostScript driver is already built in. |
| `foomatic-db-compressed-ppds` | A large collection of PPDs for PostScript and PCL printers | |
| `printer-driver-escpr` | Epson inkjets | From Ubuntu `universe`: community-maintained, without Canonical security support. |
| `printer-driver-foo2zjs` | ZjStream and other host-based lasers | Its firmware loader is a udev hook and never runs in a container; printers that need firmware uploaded at power-on will not get it from here. |

The mod installs the packages on **every container start** (so it needs internet access then), and
they are not covered by this image's tests. Packages that depend on systemd (`colord`, for example)
are refused by apt in this image, with the reason in the log — systemd cannot run under s6, and the
image pins it out.

## Security

**Keep it on your LAN. Never forward port 631 from your router or expose it to the internet.** CUPS
is a large network service, and this image tracks Ubuntu's packages: as of 2026-10-17, Ubuntu's CUPS
`2.4.16-1ubuntu1.3` does not yet carry the security fixes in upstream CUPS 2.4.20 (released
2026-10-05). The image rebuilds automatically when Ubuntu publishes an update — see
[Updating](#updating) — but until then the LAN-only posture below is the mitigation.

What the image does by default:

- **No default credentials.** Without `CUPS_ADMIN_USER` + `CUPS_ADMIN_PASSWORD`, administration is
  possible only from inside the container (`docker exec cups lpadmin …`).
- **Passwords over TLS only.** With credentials set, the admin pages are reachable from
  `CUPS_ADMIN_NETWORKS` only, and over http they answer `426 Upgrade Required` (a redirect to
  https). Every password-protected IPP operation — adding, changing, pausing or deleting a printer,
  from any address — likewise requires TLS, so CUPS never *asks* for the admin password over plain
  http. What it cannot stop is a client that sends the password *unasked* over http to a page that
  is not an admin page (a web-interface printer page, say, as `curl -u` would): that request is
  honoured, and the password has crossed the LAN in cleartext. Always use `https://` / `ipps://`
  when you log in.
- **One self-signed certificate**, created on the first start for the server's name (see
  `CUPS_AIRPRINT_HOSTNAME`), stored in `/config/cups/ssl` and valid for ten years. Browsers warn about
  it; that is expected. It is served on every address of the container and stays the same across
  container recreates — with or without `--hostname` — as long as the name stays the same.
- **Access by network.** Printing and browsing are allowed from `localhost` and
  `CUPS_ALLOWED_NETWORKS` only (default: private address ranges). One caveat in bridge mode:
  connections that Docker's *userland proxy* relays arrive from the Docker bridge gateway
  (`172.17.0.1` or similar), which the default list admits (it is both `@LOCAL` and inside
  `172.16.0.0/12`) whoever the real client is. Docker relays that way for connections from the host
  itself and — on a dual-stack host — for IPv6 connections to a published port of this IPv4-only
  container. If your host has an IPv6 address that is reachable from outside your LAN, publish the
  port on IPv4 only (`-p 0.0.0.0:631:631`), firewall it, or narrow `CUPS_ALLOWED_NETWORKS` to your
  LAN's own range (which also shuts out other containers on the host).
- **Host-name check.** Requests must name the server by IP, `localhost`, `*.local`, its own name or
  a `CUPS_SERVER_ALIASES` entry. A wildcard is never written, which keeps CUPS' DNS-rebinding
  protection.
- **Less code running.** No `cups-browsed`, colord, ipp-usb or systemd. `file:` device URIs are
  disabled. The only backend that runs as root is `usb`; the network backends run as `lp`.
- **No host D-Bus.** AirPrint uses a private D-Bus and Avahi inside the container, started only when
  `CUPS_AIRPRINT=true`. A host D-Bus mounted into the container — `/run/dbus`, `/var/run/dbus`, or
  the host's whole `/run` — stops it from starting, before anything there is touched.
- **The admin password** is never logged or passed on a command line, is not inherited by the
  long-running daemons, and the container's own copies of it cannot be read by the print filters
  (which run as `lp`). A `FILE__CUPS_ADMIN_PASSWORD` file is yours and keeps its host permissions:
  make it root-owned `0600` (or `0400`), or the filters can read it — the log warns when they can.
- `ServerTokens None`: no `Server:` header. CUPS' built-in error pages still name the version in
  their title.

One subtlety: `CUPS_ADMIN_NETWORKS` restricts the `/admin` pages. Administrative IPP operations sent
to a queue's own address (pausing or deleting a printer from another computer's print dialog, say)
are accepted from `CUPS_ALLOWED_NETWORKS`, but still require the admin login over TLS — Ubuntu's
stock CUPS operation policy, kept verbatim except that every password-protected operation also
requires encryption.

## Migrating from the old CUPS template

1. Note the old container's appdata path (usually `/mnt/user/appdata/cups`), then **stop and remove
   the old container**. Its appdata folder stays.
2. Install this template. Point **`/config` at the old appdata folder** (or copy that folder's
   contents to the new path first if you want to keep the original pristine).
3. **Do not carry over** the old template's `/var/run/dbus` mapping (oddly labelled "USB mapping"
   there) — this container refuses to start with it — or its **Printer** device mapping
   (`/dev/bus/usb/003/009`). This template maps `/dev/bus/usb` read-only instead.
4. Set `CUPS_ADMIN_PASSWORD`. The old `ADMIN_PASSWORD` variable means nothing here, and
   `admin`/`admin` no longer exists.
5. Start the container and check the log for `MIGRATION:` lines.

On the first start the image finds the old layout (`printers.conf` and `ppd/` at the top of
`/config`), copies **`printers.conf`, `classes.conf` and `ppd/*.ppd`** into `/config/cups/`, and
leaves the originals untouched. The old `cupsd.conf`, `cups-files.conf` and `ssl/` are **not**
imported — they carried the insecure settings — and can be deleted once you are happy. The import
runs once.

Your old queues keep their names and PPDs. A queue whose device URI needs a backend this image
does not ship — HPLIP's `hp:/…`, the `dnssd://…` addresses the web interface uses for discovered
printers, `lpd://…` — is stopped by CUPS as soon as it loads (`Backend … does not exist`), and the
log says so with a `WARN: MIGRATION:` line. Give it a `usb://`, `socket://` or `ipp://` URI: either
set `PRINTER_NAME` to that queue's name with `PRINTER_MODEL` and `PRINTER_URI` (the container then
updates the URI and re-enables the queue by itself), or change the device in the web interface
(*Modify Printer*) and, if it still shows as stopped, run `docker exec cups cupsenable <queue>`.

If a job then fails with a missing-filter error, that queue's driver came from a package this image
does not ship: pick a driver that is available
(*Modify Printer* in the web UI) or install the package with the
[universal-package-install mod](#extra-drivers). Clients that used `http://tower:631/printers/<queue>`
keep working with `CUPS_SERVER_ALIASES=tower`.

## Troubleshooting

**The container stops right after starting.** Read the last lines of `docker logs cups`. Either a
variable is invalid (`invalid configuration - refusing to start:` followed by every problem found),
or a host D-Bus is mounted (`a host D-Bus directory/socket is mounted into this container`) — remove
the `/var/run/dbus` mapping — or a host directory is mapped over `/run` or `/var/run` (`a host
directory is mounted over the container's /run`) — remove that mapping. A `ppd` or `ssl` symlink in
`/config/cups` is refused too: remove it, CUPS recreates the directory.

**`400 Bad Request` in the browser.** The name in the address bar is not one CUPS accepts. Add it to
`CUPS_SERVER_ALIASES` (e.g. `tower`), or use the IP address or `<name>.local`.

**`403 Forbidden`.** Your device's address is not in `CUPS_ALLOWED_NETWORKS`. In bridge mode the
container sees the client's real address, so VPN clients (Tailscale uses `100.64.0.0/10`) or a LAN
outside the private ranges must be added. On `/admin`, `403` also means administration is not
configured, or you are outside `CUPS_ADMIN_NETWORKS`. The access log in `docker logs` shows the
address each request came from.

**`426 Upgrade Required`, or a certificate warning.** Expected for `/admin` over http: use
`https://`, accept the self-signed certificate once. In bridge mode the page's automatic redirect
goes to the container's internal Docker address (`https://172.17.x.y:631/…`) and times out — type
`https://<unraid-ip>:<port>/admin` yourself.

**Settings changed under Administration → Server Settings are gone after a restart.** The image
regenerates `cupsd.conf` on every start; use the `CUPS_*` variables instead. (Queues and their
options are not affected — they live in `printers.conf`.)

**The printer is not found** (`docker exec cups lpinfo -v` shows no `direct usb://` line):

- check the `/dev/bus/usb` mapping **and** `--device-cgroup-rule='c 189:* rmw'` in Extra Parameters;
- check that the host sees it: `lsusb` on Unraid;
- make sure nothing else holds it — above all, the **old CUPS container must not be running**. Only
  one program can claim the printer's USB interface at a time.
- CUPS talks to the printer through libusb and detaches the kernel's `usblp` driver from it by
  itself, so a `/dev/usb/lp0` on the host is normal. Do not map `/dev/usb/lp0` into the container.

**Jobs sit at "Waiting for printer to become available."** The printer is off, or asleep with its USB
connection down. Many printers power off on their own — on HP LaserJet Pro models the *Shut Down
After* / auto-off setting. Jobs continue when it comes back; change that setting on the printer if
you print unattended.

**Prints look faint (HP M203 and other `postscript-hp` models).** Check the toner and the printer's
own EconoMode / print density settings first. Then know about this quirk: HP's `hpps` filter writes
`@PJL SET ECONOMODE=ON` into the job header whenever the EconoMode option is present at all — and on
Ubuntu it always is, even when set to *Off*. The PostScript job that follows starts with its own PJL
header after a reset sequence, which very likely cancels it, so it should not matter — but if you
suspect it, compare against a test queue using
`drv:///sample.drv/generic.ppd` (*Generic PostScript Printer*), which sends no HP PJL at all. The
image does not patch HP's driver.

**No toner or supply levels.** Not available over USB with this driver; use the printer's front
panel.

**Jobs show the user `remroot`.** They were sent by `root` on another machine; CUPS renames remote
`root` users that way. Not an error.

## LinuxServer features

Built on the LinuxServer base image, so the standard LinuxServer tooling works out of the box:

- **Docker Mods** — add packages/tweaks at startup without rebuilding, e.g. the
  [extra drivers](#extra-drivers) above (pipe-separate multiple mods).
- **Custom scripts & services** — executables mounted into `/custom-cont-init.d` run at startup;
  `/custom-services.d` holds long-running services.
- **Secrets from files (`FILE__`)** — keep the admin password out of plaintext env by pointing a
  `FILE__`-prefixed variable at a file whose contents become the value (works with Docker secrets).
  The file is mounted with its host permissions, so make it root-owned `0600` there:

  ```yaml
  - FILE__CUPS_ADMIN_PASSWORD=/run/secrets/cups_admin_password
  ```
- **User / group identifiers** — `PUID`/`PGID` set who owns `/config` (find yours with `id youruser`;
  Unraid uses `99`/`100`); `UMASK` controls created-file permissions.

See [LinuxServer's documentation](https://docs.linuxserver.io/) for Docker Mods and container customization.

## Updating

CI checks **daily** and republishes `ghcr.io/cookiesncache/cups:latest` **only when something that
actually goes into the image has changed** — this repo's Dockerfile and `root/` tree, or the set of
Ubuntu package versions the image would install. When Ubuntu ships a CUPS, Ghostscript or base-library
update, the next daily run rebuilds with it; a day where nothing moved produces no push, so your
install does not see an update prompt for an image that is identical apart from a build timestamp.
On Unraid, enable **CA Auto Update Applications** to pull new images automatically.

Every published image is boot-tested first: printing end to end, the admin and TLS rules, AirPrint
discovery and the fail-closed checks have to pass before the push happens.

**Tags**

| Tag | Points at | Mutable? |
|---|---|---|
| `:latest` | the newest build | **floats** |
| `:2.4.16` | the newest build of that upstream CUPS version | **floats** |
| `:2.4.16-1ubuntu1.3-ls12` | one specific build (Ubuntu package version + build number) | never re-pushed — **pin this** |
| `@sha256:…` | exact bytes | immutable |

The `-ls<N>` suffix follows [LinuxServer's convention](https://docs.linuxserver.io/) for "same
upstream version, several image builds" — which is the normal case here, because Ubuntu ships
security fixes as new package revisions of the same CUPS version.

**What is in this image?**

```bash
docker exec cups grep -E '^(cups-daemon|cups-filters|ghostscript)=' /package_versions.txt
docker inspect -f '{{ index .Config.Labels "build_version" }}' cups
```

`/package_versions.txt` lists every installed package and version.

## Limitations

- **amd64 only.** The Dockerfile is architecture-neutral, but only amd64 is built and tested (Unraid's
  architecture).
- **cupsd runs as root,** by necessity: the USB backend opens the printer's device node, the admin
  login is checked through PAM, and CUPS requires its configuration to be owned `root:lp`. Print
  filters (which process the documents) run as the unprivileged `lp` user.
- **`PUID`/`PGID` only govern the `/config` folder itself.** `/config/cups` and its contents stay
  `root:lp` — CUPS refuses to work otherwise — and the container repairs the ownership CUPS checks
  on every start if a host tool (such as Unraid's *New Permissions*) changes it.
- **Security fixes arrive with Ubuntu,** not directly from upstream CUPS (see [Security](#security)).
- **AirPrint is IPv4 only**, and needs a custom network (see [AirPrint](#airprint)).
- **No IPP-over-USB.** `ipp-usb` is not installed; USB printers are driven through the classic `usb`
  backend and a driver.
- **CI has no real USB printer,** so the automated tests cannot exercise the USB path itself (CUPS'
  own `usb` backend, as Ubuntu packages it). Printing is tested end to end through network queues
  instead.

## Building

```bash
docker build -t ghcr.io/cookiesncache/cups:latest .
```

The base image is pinned by digest in the Dockerfile, and the Ubuntu packages are whatever the
archive serves at build time. To force fresh packages when the apt layer is cached, pass any new
value: `--build-arg APT_FINGERPRINT=$(date +%s)`. CI passes a hash of the resolved package versions
there instead, so a rebuild happens exactly when Ubuntu publishes something.

Design decisions, the package set, the hardening steps and the CUPS/AirPrint/USB facts behind them
are documented in [NOTES.md](NOTES.md).

## Support

- GitHub issues: <https://github.com/cookiesncache/docker-cups/issues>

Useful diagnostics:

```bash
docker logs -f cups                                                  # live logs, incl. CUPS' error and access log
docker exec -it cups bash                                            # shell into the container
docker exec cups lpstat -t                                           # scheduler, queues and jobs
docker exec cups lpinfo -v                                           # printers CUPS can see
docker exec cups cat /config/cups/cupsd.conf                         # the generated configuration
docker inspect -f '{{ index .Config.Labels "build_version" }}' cups  # image build version
```

For bugs in CUPS itself, check the upstream trackers ([OpenPrinting/cups](https://github.com/OpenPrinting/cups/issues))
and Ubuntu's ([Launchpad](https://bugs.launchpad.net/ubuntu/+source/cups)) first; this repository is
for the image and its packaging.

## License

The packaging in this repository — Dockerfile, s6 service definitions, scripts, and the Unraid
template — is licensed under [GPL-3.0](LICENSE), mirroring LinuxServer.io's licensing.

The image **redistributes unmodified Ubuntu packages** under their own licenses — among them CUPS
(Apache-2.0), Ghostscript (AGPL-3.0), cups-filters, Gutenprint, HPLIP's PostScript drivers, Avahi and
D-Bus. See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) for the list and where to get their
sources; each package's own copyright file is in the image under `/usr/share/doc/<package>/copyright`.
