---
name: Bug report
about: Report a problem with the docker-cups image (packaging), not CUPS itself
labels: bug
---

<!--
For bugs in CUPS itself, please use the upstream trackers:
  OpenPrinting: https://github.com/OpenPrinting/cups/issues
  Ubuntu's package: https://bugs.launchpad.net/ubuntu/+source/cups
This tracker is for the image/packaging (Dockerfile, s6 services, template, env handling).

Never paste CUPS_ADMIN_PASSWORD. The startup log does not contain it, but check what you paste.
-->

**Image version**
- `build_version` label: <!-- docker inspect -f '{{ index .Config.Labels "build_version" }}' cups -->
- CUPS package: <!-- docker exec cups grep '^cups-daemon=' /package_versions.txt -->

**Host / deployment**
- Unraid version (or other host):
- How you run it: CA template / docker-compose / docker run
- Network type: bridge / br0 / eth0 / other — fixed IP?
- `CUPS_AIRPRINT`: true / false

**Printer**
- Make and model, and how it is connected (USB / network):
- Driver (PPD) the queue uses:
- Output of `docker exec cups lpinfo -v` (for USB problems):

**What happened**
<!-- Clear description of the problem and what you expected instead. -->

**Logs**
<!-- Relevant output from `docker logs cups`, ideally from container start including the
     "docker-cups security posture" block. For job problems, set CUPS_LOG_LEVEL=debug, restart,
     reproduce, and attach that log. Redact anything private. -->

```
paste logs here
```
