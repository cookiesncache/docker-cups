<!-- Thanks for contributing! Keep changes focused. -->

## Summary

<!-- What does this change, and why? -->

## Checklist

- [ ] CI is green (or builds and passes `.github/scripts/smoke.sh` locally)
- [ ] `shellcheck -x` is clean for any shell script touched
- [ ] Packages added/removed only in `root/etc/cups-image/packages.txt` (the one list the Dockerfile and CI read)
- [ ] Template (`templates/cups.xml`) / `docker-compose.yml` updated if variables or behavior changed
- [ ] README / NOTES / CHANGELOG updated if user-facing behavior changed
