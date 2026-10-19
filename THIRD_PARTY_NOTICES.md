# Third-party notices

This image redistributes software from **Ubuntu 26.04 ("resolute")**, installed unmodified from the
Ubuntu archive with `apt`, on top of the **LinuxServer.io** base image. The packaging in this
repository (Dockerfile, s6-overlay service definitions, scripts, and the Unraid template) is
licensed under GPL-3.0 (see [LICENSE](LICENSE)); the bundled software remains under its own
licenses, summarised below.

This summary is for orientation only. **The authoritative license and copyright text for every
package ships inside the image at `/usr/share/doc/<package>/copyright`**, and the exact versions are
listed in `/package_versions.txt`:

```bash
docker run --rm --entrypoint cat ghcr.io/cookiesncache/cups:latest /package_versions.txt
docker run --rm --entrypoint cat ghcr.io/cookiesncache/cups:latest /usr/share/doc/cups-daemon/copyright
```

## Main components

| Component | Ubuntu package(s) | License (main parts) | Project |
|---|---|---|---|
| CUPS | `cups`, `cups-daemon`, `cups-client`, `cups-ipp-utils`, `libcups2t64`, … | Apache-2.0 with GPL-2.0/LGPL-2.0 exception | <https://github.com/OpenPrinting/cups> |
| cups-filters, libcupsfilters, libppd | `cups-filters`, `cups-filters-core-drivers`, `libcupsfilters2t64`, `libppd2` | Apache-2.0 with GPL-2.0/LGPL-2.0 exception; parts GPL-2.0-or-later | <https://github.com/OpenPrinting> |
| Ghostscript | `ghostscript`, `libgs10`, `libgs10-common` | **AGPL-3.0-or-later** (parts under other free licenses) | <https://www.ghostscript.com/> |
| URW++ base 35 fonts | `fonts-urw-base35` | AGPL-3.0 with font exception | <https://github.com/ArtifexSoftware/urw-base35-fonts> |
| HPLIP PostScript drivers | `printer-driver-postscript-hp` | GPL-2.0-or-later, BSD-3-Clause, MIT (Expat) | <https://developers.hp.com/hp-linux-imaging-and-printing> |
| Gutenprint | `printer-driver-gutenprint`, `libgutenprint9`, `libgutenprint-common` | GPL-2.0-or-later (parts LGPL-2.0-or-later, GPL-3.0-or-later) | <https://sourceforge.net/projects/gimp-print/> |
| brlaser | `printer-driver-brlaser` | GPL-2.0-or-later | <https://github.com/Owl-Maintain/brlaser> |
| SpliX | `printer-driver-splix` | GPL-2.0 | <https://openprinting.github.io/splix/> |
| Poppler | `libpoppler156`, `poppler-utils`, `poppler-data` | GPL-2.0 or GPL-3.0; poppler-data: BSD-3-Clause (Adobe CMaps), GPL-2.0, AGPL-3.0-or-later parts | <https://poppler.freedesktop.org/> |
| qpdf | `libqpdf30` | Apache-2.0 | <https://github.com/qpdf/qpdf> |
| Avahi | `avahi-daemon`, `libavahi-*` | LGPL-2.1-or-later | <https://avahi.org/> |
| D-Bus | `dbus`, `dbus-daemon`, `dbus-x11`, `libdbus-1-3` | AFL-2.1 or GPL-2.0-or-later | <https://www.freedesktop.org/wiki/Software/dbus/> |
| Python 3.14 | `python3.14`, `libpython3.14-*` | PSF-2.0 | <https://www.python.org/> |
| LinuxServer.io base image | (base layers) | GPL-3.0 | <https://github.com/linuxserver/docker-baseimage-ubuntu> |
| s6-overlay | (in the base) | ISC | <https://github.com/just-containers/s6-overlay> |
| Ubuntu base system | the remaining packages (about 265 installed in total) | various free licenses | <https://ubuntu.com/> |

"CUPS" is a trademark of its owner. This image is not affiliated with or endorsed by OpenPrinting,
Canonical, LinuxServer.io, or any of the projects above.

## Source code

None of the Ubuntu packages are modified. Their complete corresponding source is published by Ubuntu
for the exact version in the image:

- With `apt` (on any Ubuntu system with `deb-src` enabled, or in a `ubuntu:26.04` container):

  ```bash
  apt-get source cups=2.4.16-1ubuntu1.3          # use the version from /package_versions.txt
  ```

- On Launchpad, which keeps every published version permanently:
  `https://launchpad.net/ubuntu/+source/<source-package>/<version>`.

Note that `apt-get source` and Launchpad take the **source** package name, which can differ from the
binary package listed in `/package_versions.txt` (for example `libgs10` is built from `ghostscript`,
`libcupsfilters2t64` from `libcupsfilters`); `dpkg -s <package>` in the image shows the `Source:`
field. If you cannot obtain the source for a version shipped in a published image, open an issue in
this repository.

The packaging itself — the only code in this image not taken from Ubuntu or the LinuxServer base — is
this repository.
