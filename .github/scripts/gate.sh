#!/usr/bin/env bash
# Decide WHETHER to publish, and describe exactly what would be published.
#
# docker-cups has no upstream image to adopt (contrast docker-openclaw's gate, which also has to
# choose an upstream digest under a cooldown). Everything in the image is one of three things:
#
#   1. the LSIO base, pinned by digest in the Dockerfile's FROM line (Dependabot bumps it);
#   2. the Ubuntu packages installed on top of it (root/etc/cups-image/packages.txt, plus the
#      `apt-get upgrade` of the base's own packages);
#   3. this repository's Dockerfile, root/ and .dockerignore.
#
# So the gate answers one question - did any of those change since the image that is currently
# published? - by comparing a fingerprint of them against the `io.cookiesncache.inputs` annotation
# on the published index. One registry read, no external state, and no way to drift from what
# actually shipped. Publishing only on a real change matters for the same reason as in openclaw:
# every push to :latest is an "update available" on every Unraid install, so a rebuild that changes
# nothing but BUILD_DATE is a phantom update.
#
# (1) and (3) are the git object ids of Dockerfile, root/ and .dockerignore at HEAD - the base digest
# lives in the Dockerfile, so a base bump moves this too. Content ids rather than $GITHUB_SHA, so a
# docs-only commit does not publish anything.
#
# (2) is APT_FINGERPRINT: a hash of the exact `name=version` set that apt WOULD install, computed by
# simulating the Dockerfile's apt step (`apt-get -s upgrade` + `apt-get -s install
# --no-install-recommends <packages.txt>`, with the image's systemd pin in place) inside the pinned
# base. Ubuntu publishing a CUPS, Ghostscript or glibc security update changes one version string,
# which changes the fingerprint, which publishes - within a day, with nothing to remember. A quiet
# archive day changes nothing and publishes nothing. This replaces openclaw's monthly APT_EPOCH: a
# calendar stamp refreshes packages up to a month late and republishes even when nothing changed;
# the resolution itself is exact in both directions.
#
# APT_FINGERPRINT is also passed to the build as a build-arg declared directly above the apt RUN, so
# the apt layer re-executes exactly when the resolution changes and is reused from cache otherwise.
#
# packages.txt is the ONE package list: the Dockerfile installs from it and this script resolves it,
# with the same parsing and the same validation. Parsing the Dockerfile instead would mean a regex
# over a shell heredoc - two places to keep in step that nothing checks. --check-image then proves
# after the build that the image really contains every version the fingerprint claims.
#
# A failure to resolve (archive unreachable, an unsatisfiable package set, a parse that yields
# nothing) FAILS the job. That is deliberate: a resolution that silently came back empty would hash
# to a constant, the fingerprint would never move again, and security updates would quietly stop
# shipping. A red run is the only signal that reaches anyone, and this is exactly the case for it.
#
# This file is deliberately NOT part of the fingerprint: it decides whether to build, it is not *in*
# the image. Iterating on gate logic must not publish to every installed user.
#
# Usage:
#   bash .github/scripts/gate.sh                       decide; writes publish, hash, apt_fingerprint,
#                                                      base_name and base_digest to $GITHUB_OUTPUT
#   bash .github/scripts/gate.sh --self-test           pure helpers only: no Docker, no network
#   bash .github/scripts/gate.sh --tags <ver> <run>    version / version_base / build_tag lines for
#                                                      a cups-daemon package version and run number
#   bash .github/scripts/gate.sh --check-image <image> <resolution-file>
#                                                      fail unless the image's /package_versions.txt
#                                                      contains every resolved name=version
#
# Environment (decide mode):
#   IMAGE               published image, e.g. ghcr.io/cookiesncache/cups (required)
#   EVENT_NAME/IN_FORCE workflow_dispatch + force=true bypasses the fingerprint comparison
#   APT_RESOLUTION_FILE optional path; the resolved name=version list is written there for
#                       --check-image
#   BASE_MIRROR         LOCAL TESTING ONLY. A repository (e.g. docker.io/lsiobase/ubuntu) to pull the
#                       base from instead of the FROM line's registry, for sandboxes that cannot
#                       reach GHCR. Only the repository is swapped: the digest still comes from the
#                       Dockerfile, and a digest is a content address, so the image resolved against
#                       is byte-identical or the pull fails. Never set in CI.
set -euo pipefail

PACKAGES_FILE="root/etc/cups-image/packages.txt"
APT_PIN_FILE="root/etc/apt/preferences.d/docker-cups-no-systemd"
APT_PIN_TARGET="/etc/apt/preferences.d/docker-cups-no-systemd"

# ---------------------------------------------------------------------------
# Pure helpers (all covered by --self-test)
# ---------------------------------------------------------------------------

# read_package_list <file> -> validated package names, one per line.
#
# Must parse EXACTLY as the Dockerfile does: `#` starts a comment, trailing whitespace and blank
# lines are dropped, the rest is word-split. Same validation too - a name with anything outside
# [a-z0-9+.-], or not starting alphanumeric, is refused rather than handed to apt's argv.
read_package_list() {
    local file="$1" text line p
    local -a words
    local n=0
    [ -r "$file" ] || { echo "cannot read ${file}" >&2; return 1; }
    text="$(sed -e 's/#.*//' -e 's/[[:space:]]*$//' -e '/^$/d' "$file")"
    while IFS= read -r line; do
        read -ra words <<< "$line"
        for p in ${words[@]+"${words[@]}"}; do
            case "$p" in
                *[!a-z0-9+.-]*|[!a-z0-9]*)
                    echo "bad package name '${p}' in ${file}" >&2
                    return 1 ;;
            esac
            printf '%s\n' "$p"
            n=$((n + 1))
        done
    done <<< "$text"
    [ "$n" -gt 0 ] || { echo "no packages listed in ${file}" >&2; return 1; }
}

# base_ref_from_dockerfile <file> -> the FROM image reference, which must be digest-pinned.
#
# Only the first FROM is considered (this is a single-stage build). A FROM without @sha256: is an
# error: an unpinned base would make the fingerprint describe a tag, not an image, and the gate would
# miss base movement entirely.
base_ref_from_dockerfile() {
    local file="$1" ref
    ref="$(sed -n -E 's/^[[:space:]]*[Ff][Rr][Oo][Mm][[:space:]]+([^[:space:]]+).*/\1/p' "$file" | sed -n '1p')"
    [ -n "$ref" ] || { echo "no FROM line in ${file}" >&2; return 1; }
    if [[ ! "$ref" =~ ^[a-z0-9][a-z0-9._/:-]*@sha256:[0-9a-f]{64}$ ]]; then
        echo "FROM '${ref}' in ${file} is not pinned by digest" >&2
        return 1
    fi
    printf '%s\n' "$ref"
}

# apt_inst_versions: `apt-get -s` output on stdin -> sorted, unique `name=version` on stdout.
#
# Simulation lines look like this (apt 3.2 on resolute, verified):
#   Inst curl [8.18.0-1ubuntu2.7] (8.18.0-1ubuntu2.8 Ubuntu:26.04/resolute-security [amd64]) []
#   Inst poppler-data (0.4.12-1build1 Ubuntu:26.04/resolute [all])
# i.e. name, the installed version in [] for an upgrade, then the version that WOULD be installed as
# the first word inside (). Only that version matters; Conf/Remv lines and apt's chatter are ignored.
# The upgrade and install simulations are concatenated, so a package in both appears once.
apt_inst_versions() {
    sed -n -E 's/^Inst ([^ ]+) (\[[^]]*\] )?\(([^ ]+) .*/\1=\3/p' | LC_ALL=C sort -u
}

# valid_resolution <text> -> exit 0 when every line is a plausible `name=version` and there is at
# least one. A line that does not look like that means the simulation output changed shape - fail
# rather than fingerprint garbage.
valid_resolution() {
    local text="$1" line n=0
    while IFS= read -r line; do
        [[ "$line" =~ ^[a-z0-9][a-z0-9+.-]*(:[a-z0-9]+)?=[0-9][A-Za-z0-9.+~:-]*$ ]] || return 1
        n=$((n + 1))
    done <<< "$text"
    [ "$n" -gt 0 ]
}

# debian_version_ok <version> -> exit 0 for a Debian version string we are willing to put in a tag.
# The value is read out of the built image, so it is validated before it reaches tags or $GITHUB_OUTPUT.
debian_version_ok() {
    [[ "${1:-}" =~ ^[0-9][A-Za-z0-9.+~:-]{0,99}$ ]]
}

# upstream_version <debian version> -> bare upstream release (2.4.16), or non-zero.
#
#   2.4.16-1ubuntu1.3  -> 2.4.16    (Debian revision dropped: everything after the LAST hyphen)
#   1:2.4.16-1         -> 2.4.16    (epoch dropped)
#   2.4.16+dfsg-1      -> 2.4.16    (repack suffix dropped: it is still upstream's 2.4.16)
#   2.4.16~rc1-1       -> (none)    (`~` sorts BEFORE the release: a pre-release must not claim
#                                    the release's tag)
# Anything that does not end up as dotted numbers gets no bare tag at all; the caller still
# publishes :latest and the immutable build tag.
upstream_version() {
    local v="$1"
    debian_version_ok "$v" || return 1
    [[ "$v" =~ ^[0-9]+: ]] && v="${v#*:}"
    [[ "$v" == *-* ]] && v="${v%-*}"
    [[ "$v" == *"~"* ]] && return 1
    v="${v%%+*}"
    [[ "$v" =~ ^[0-9]+(\.[0-9]+)+$ ]] || return 1
    printf '%s\n' "$v"
}

# tag_safe <debian version> -> the same string in Docker's tag charset ([A-Za-z0-9_.-]).
# Debian versions can carry `:` (epoch), `~` and `+`, which tags cannot; each becomes `_`. The input
# always starts with a digit (debian_version_ok), so the result is a valid tag start.
tag_safe() {
    printf '%s' "$1" | tr -c 'A-Za-z0-9_.-' '_'
}

# missing_from <want-file> <have-file> -> lines of want-file absent from have-file (exact, whole-line).
missing_from() {
    local want="$1" have="$2"
    if [ ! -r "$want" ] || [ ! -r "$have" ]; then
        echo "missing_from: unreadable input" >&2
        return 2
    fi
    grep -vxF -f "$have" "$want" || true
}

# ---------------------------------------------------------------------------
# --self-test
# ---------------------------------------------------------------------------
if [ "${1:-}" = "--self-test" ]; then
    # The real packages.txt and Dockerfile are checked too, relative to the repository root.
    cd "$(dirname "${BASH_SOURCE[0]}")/../.."
    st_fail=0
    st_dir="$(mktemp -d)"
    trap 'rm -rf "$st_dir"' EXIT
    ok()  { printf '  PASS  %s\n' "$1"; }
    nok() { printf '  FAIL  %s\n' "$1"; st_fail=1; }
    eq()  { # description, got, want
        if [ "$2" = "$3" ]; then ok "$1"; else nok "$1: got '$2', want '$3'"; fi
    }

    # ---- read_package_list: the Dockerfile's parsing, comment and whitespace rules ---------------
    printf '%s\n' '# header comment' '' 'cups' 'cups-client   # trailing comment' \
        '  ghostscript  ' 'printer-driver-postscript-hp' 'libstdc++6 dbus-x11' '#gone' > "$st_dir/p1"
    got="$(read_package_list "$st_dir/p1" | tr '\n' ' ')"
    eq "package list: comments, blanks, spacing, two per line" "$got" \
       "cups cups-client ghostscript printer-driver-postscript-hp libstdc++6 dbus-x11 "
    # shellcheck disable=SC2016 # a literal $(id) on purpose: it must be refused, never expanded
    for badname in 'Cups' 'cups;id' '-cups' 'cups$(id)' '.hidden' 'cups/x'; do
        printf '%s\n' cups "$badname" > "$st_dir/p2"
        if read_package_list "$st_dir/p2" >/dev/null 2>&1; then
            nok "package list: '${badname}' accepted"
        else
            ok "package list: '${badname}' refused"
        fi
    done
    printf '%s\n' '# only comments' '' > "$st_dir/p3"
    if read_package_list "$st_dir/p3" >/dev/null 2>&1; then nok "package list: empty accepted"; else ok "package list: empty refused"; fi
    # The real list must parse, and must still carry the packages the image exists for.
    if real="$(read_package_list "$PACKAGES_FILE" 2>&1)"; then
        for must in cups cups-daemon printer-driver-postscript-hp avahi-daemon dbus; do
            if grep -qx "$must" <<< "$real"; then ok "packages.txt lists ${must}"; else nok "packages.txt lacks ${must}"; fi
        done
    else
        nok "packages.txt does not parse: ${real}"
    fi

    # ---- base_ref_from_dockerfile -----------------------------------------------------------------
    d64="$(printf 'a%.0s' $(seq 1 64))"
    printf '# syntax=docker/dockerfile:1\n# FROM commented-out:latest\nFROM ghcr.io/linuxserver/baseimage-ubuntu:resolute@sha256:%s\nRUN true\n' "$d64" > "$st_dir/d1"
    eq "FROM: digest-pinned ref extracted" "$(base_ref_from_dockerfile "$st_dir/d1" 2>&1)" \
       "ghcr.io/linuxserver/baseimage-ubuntu:resolute@sha256:${d64}"
    printf 'FROM ghcr.io/linuxserver/baseimage-ubuntu:resolute\n' > "$st_dir/d2"
    if base_ref_from_dockerfile "$st_dir/d2" >/dev/null 2>&1; then nok "FROM: unpinned accepted"; else ok "FROM: unpinned refused"; fi
    printf 'FROM ghcr.io/x/y@sha256:abc\n' > "$st_dir/d3"
    if base_ref_from_dockerfile "$st_dir/d3" >/dev/null 2>&1; then nok "FROM: short digest accepted"; else ok "FROM: short digest refused"; fi
    if real="$(base_ref_from_dockerfile Dockerfile 2>&1)"; then ok "Dockerfile FROM is digest-pinned (${real##*/})"; else nok "Dockerfile: ${real}"; fi

    # ---- apt_inst_versions: real apt 3.2 simulation lines ------------------------------------------
    cat > "$st_dir/sim" <<'SIM'
Reading package lists...
Building dependency tree...
Calculating upgrade...
The following packages will be upgraded:
  curl libcurl4t64 tzdata
3 upgraded, 0 newly installed, 0 to remove and 0 not upgraded.
Inst tzdata [2026c-0ubuntu0.26.04.1] (2026e-0ubuntu0.26.04.1 Ubuntu:26.04/resolute-updates [all])
Inst curl [8.18.0-1ubuntu2.7] (8.18.0-1ubuntu2.8 Ubuntu:26.04/resolute-security [amd64]) []
Inst libcurl4t64 [8.18.0-1ubuntu2.7] (8.18.0-1ubuntu2.8 Ubuntu:26.04/resolute-security [amd64])
Conf tzdata (2026e-0ubuntu0.26.04.1 Ubuntu:26.04/resolute-updates [all])
Conf curl (8.18.0-1ubuntu2.8 Ubuntu:26.04/resolute-security [amd64])
Inst libexpat1 (2.7.4-1ubuntu0.2 Ubuntu:26.04/resolute-updates, Ubuntu:26.04/resolute-security [amd64])
Inst libapparmor1 (5.0.2-0ubuntu1~26.04.1 Ubuntu:26.04/resolute-updates [amd64])
Inst cups-daemon (2.4.16-1ubuntu1.3 Ubuntu:26.04/resolute-updates [amd64])
Inst libstdc++6 (16-20260322-1ubuntu1 Ubuntu:26.04/resolute [amd64])
Inst curl [8.18.0-1ubuntu2.7] (8.18.0-1ubuntu2.8 Ubuntu:26.04/resolute-security [amd64])
Remv something [1.0]
SIM
    got="$(apt_inst_versions < "$st_dir/sim" | tr '\n' ' ')"
    eq "apt -s: upgrades + installs, sorted, de-duplicated" "$got" \
       "cups-daemon=2.4.16-1ubuntu1.3 curl=8.18.0-1ubuntu2.8 libapparmor1=5.0.2-0ubuntu1~26.04.1 libcurl4t64=8.18.0-1ubuntu2.8 libexpat1=2.7.4-1ubuntu0.2 libstdc++6=16-20260322-1ubuntu1 tzdata=2026e-0ubuntu0.26.04.1 "
    res="$(apt_inst_versions < "$st_dir/sim")"
    if valid_resolution "$res"; then ok "resolution: well-formed"; else nok "resolution: rejected"; fi
    if valid_resolution ""; then nok "resolution: empty accepted"; else ok "resolution: empty refused"; fi
    if valid_resolution "cups=2.4 extra"; then nok "resolution: junk accepted"; else ok "resolution: junk refused"; fi
    eq "apt -s: chatter only yields nothing" "$(printf 'E: Unable to locate package x\n' | apt_inst_versions)" ""

    # ---- upstream_version / tag_safe --------------------------------------------------------------
    uv() { # description, debian version, want ('' = no bare tag)
        local got
        got="$(upstream_version "$2" 2>/dev/null || true)"
        eq "upstream_version: $1 ($2)" "$got" "$3"
    }
    uv "Ubuntu revision"         "2.4.16-1ubuntu1.3"   "2.4.16"
    uv "epoch"                   "1:2.4.16-1"          "2.4.16"
    uv "repack suffix"           "2.4.16+dfsg-1"       "2.4.16"
    uv "native, no revision"     "2.4.16"              "2.4.16"
    uv "backport tilde in rev"   "2.4.16-1ubuntu1~26.04.1" "2.4.16"
    uv "pre-release"             "2.4.16~rc1-1"        ""
    uv "hyphen inside upstream"  "2.4.16-git1-1"       ""
    uv "not a version"           "cups"                ""
    uv "empty"                   ""                    ""
    uv "injection"               '2.4.16-1;id'         ""
    eq "tag_safe: plain"         "$(tag_safe '2.4.16-1ubuntu1.3')"      "2.4.16-1ubuntu1.3"
    eq "tag_safe: epoch/~/+"     "$(tag_safe '1:2.4.16+dfsg-1~26.04')"  "1_2.4.16_dfsg-1_26.04"
    if debian_version_ok "2.4.16 -1"; then nok "debian_version_ok: space accepted"; else ok "debian_version_ok: space refused"; fi
    if debian_version_ok "$(printf '2%.0s' $(seq 1 120))"; then nok "debian_version_ok: over length accepted"; else ok "debian_version_ok: over length refused"; fi

    # ---- missing_from: the --check-image comparison ----------------------------------------------
    printf '%s\n' 'cups-daemon=2.4.16-1ubuntu1.3' 'curl=8.18.0-1ubuntu2.8' > "$st_dir/want"
    printf '%s\n' 'aaa=1' 'cups-daemon=2.4.16-1ubuntu1.3' 'curl=8.18.0-1ubuntu2.8' 'zzz=2' > "$st_dir/have"
    eq "missing_from: subset -> nothing missing" "$(missing_from "$st_dir/want" "$st_dir/have")" ""
    printf '%s\n' 'cups-daemon=2.4.16-1ubuntu1.4' 'curl=8.18.0-1ubuntu2.8' > "$st_dir/have2"
    eq "missing_from: newer in image -> reported" "$(missing_from "$st_dir/want" "$st_dir/have2")" "cups-daemon=2.4.16-1ubuntu1.3"
    printf '%s\n' 'cups-daemon=2.4.16-1ubuntu1.3x' 'curl=8.18.0-1ubuntu2.8' > "$st_dir/have3"
    eq "missing_from: whole-line match only" "$(missing_from "$st_dir/want" "$st_dir/have3")" "cups-daemon=2.4.16-1ubuntu1.3"

    if [ "$st_fail" != 0 ]; then
        echo "::error::gate.sh self-test failed"
        exit 1
    fi
    echo "gate.sh self-test passed"
    exit 0
fi

# ---------------------------------------------------------------------------
# --tags <cups-daemon version> <run number>
#
# Tags are LinuxServer-style (compare linuxserver/code-server:4.133.0-ls358):
#   :latest                          floating
#   :<upstream>          e.g. 2.4.16 floating - the newest build of that CUPS release
#   :<pkg version>-ls<run>           immutable, never re-pushed; what users pin. The Ubuntu package
#                                    version, not just upstream's, because Ubuntu ships security
#                                    fixes as revisions (2.4.16-1ubuntu1.3 -> .4) under one upstream
#                                    version, and a pin should say which one it is.
# run_number is monotonic per workflow; gaps are expected because runs that publish nothing still
# consume a number.
# ---------------------------------------------------------------------------
if [ "${1:-}" = "--tags" ]; then
    ver="${2:-}"
    run="${3:-}"
    if ! debian_version_ok "$ver"; then
        echo "::error::refusing to tag: '${ver}' is not a Debian version string" >&2
        exit 1
    fi
    if [[ ! "$run" =~ ^[0-9]+$ ]]; then
        echo "::error::refusing to tag: run number '${run}' is not numeric" >&2
        exit 1
    fi
    base="$(upstream_version "$ver" || true)"
    [ -n "$base" ] || echo "::warning::no bare upstream version in '${ver}' - publishing without the :<upstream> tag" >&2
    printf 'version=%s\nversion_base=%s\nbuild_tag=%s-ls%s\n' "$ver" "$base" "$(tag_safe "$ver")" "$run"
    exit 0
fi

# ---------------------------------------------------------------------------
# --check-image <image> <resolution file>
#
# The fingerprint is a claim about the image: "it contains exactly these package versions". Prove
# it before anything is published. A mismatch means one of two things, and neither may ship under
# this fingerprint's annotation:
#   - the gate's simulation does not model the Dockerfile's apt step any more (a parse or flag
#     drift) - a silent-staleness bug that this check turns into a red run;
#   - Ubuntu published between the gate and the build (minutes; rare). Re-running the workflow
#     resolves it, and is cheaper than an annotation that lies about the content.
# ---------------------------------------------------------------------------
if [ "${1:-}" = "--check-image" ]; then
    img="${2:?usage: gate.sh --check-image <image> <resolution-file>}"
    want="${3:?usage: gate.sh --check-image <image> <resolution-file>}"
    [ -s "$want" ] || { echo "::error::resolution file '${want}' is missing or empty" >&2; exit 1; }
    have="$(mktemp)"
    trap 'rm -f "$have"' EXIT
    if ! docker run --rm --entrypoint cat "$img" /package_versions.txt > "$have" || [ ! -s "$have" ]; then
        echo "::error::could not read /package_versions.txt from ${img}" >&2
        exit 1
    fi
    missing="$(missing_from "$want" "$have")"
    if [ -n "$missing" ]; then
        echo "::error::${img} does not contain the package versions its fingerprint was computed from:"
        while IFS= read -r line; do
            printf '  resolved %-48s image has %s\n' "$line" "$(grep -m1 "^${line%%=*}=" "$have" || echo '(not installed)')"
        done <<< "$missing"
        echo "If Ubuntu published during this run, re-run the workflow; otherwise the gate's simulation no longer matches the Dockerfile's apt step."
        exit 1
    fi
    echo "::notice::${img} contains all $(wc -l < "$want") resolved package versions"
    exit 0
fi

# ---------------------------------------------------------------------------
# Decide
# ---------------------------------------------------------------------------
: "${IMAGE:?IMAGE must be set}"
GITHUB_OUTPUT="${GITHUB_OUTPUT:-/dev/stdout}"
# Everything below is relative to the repository root (the paths, and HEAD:<path> for git).
cd "$(dirname "${BASH_SOURCE[0]}")/../.."

if ! BASE_REF="$(base_ref_from_dockerfile Dockerfile 2>&1)"; then
    echo "::error::${BASE_REF}"
    exit 1
fi
BASE_DIGEST="${BASE_REF##*@}"
BASE_NAME="${BASE_REF%@*}"

RESOLVE_REF="$BASE_REF"
if [ -n "${BASE_MIRROR:-}" ]; then
    if [[ ! "$BASE_MIRROR" =~ ^[a-z0-9][a-z0-9._/:-]*$ ]] || [[ "$BASE_MIRROR" == *@* ]]; then
        echo "::error::BASE_MIRROR '${BASE_MIRROR}' is not a repository reference"
        exit 1
    fi
    RESOLVE_REF="${BASE_MIRROR}:${BASE_NAME##*:}@${BASE_DIGEST}"
    echo "::warning::BASE_MIRROR set: resolving packages in ${RESOLVE_REF} (same digest as ${BASE_NAME})"
fi

if ! PKG_TEXT="$(read_package_list "$PACKAGES_FILE" 2>&1)"; then
    echo "::error::${PKG_TEXT}"
    exit 1
fi
mapfile -t PKGS <<< "$PKG_TEXT"
[ -r "$APT_PIN_FILE" ] || { echo "::error::${APT_PIN_FILE} is missing - the simulation would not match the build"; exit 1; }

# The Dockerfile's apt step, simulated: same base, same pin, same flags, same order. `apt-get update`
# progress goes to stderr so stdout carries only the simulation. Error-Mode=any makes a partially
# failed update (one unreachable pocket) an error instead of a resolution against stale indexes. The
# package names travel as positional arguments, never through a shell string.
echo "Resolving ${#PKGS[@]} packages from ${PACKAGES_FILE} inside ${RESOLVE_REF} ..."
if ! SIM="$(docker run --rm --platform linux/amd64 --entrypoint /bin/bash \
                -v "${PWD}/${APT_PIN_FILE}:${APT_PIN_TARGET}:ro" \
                "$RESOLVE_REF" -c '
                    set -euo pipefail
                    export DEBIAN_FRONTEND=noninteractive
                    apt-get -qq -o APT::Update::Error-Mode=any update >&2
                    apt-get -s -y upgrade
                    apt-get -s -y install --no-install-recommends "$@"
                ' resolve "${PKGS[@]}")"; then
    echo "::error::could not resolve the package set inside ${RESOLVE_REF} - the gate cannot tell whether Ubuntu published anything"
    exit 1
fi

RESOLUTION="$(printf '%s\n' "$SIM" | apt_inst_versions)"
if ! valid_resolution "$RESOLUTION"; then
    echo "::error::the apt simulation produced no usable name=version lines - refusing to fingerprint it"
    printf '%s\n' "$SIM" | tail -40
    exit 1
fi
CUPS_RESOLVED="$(sed -n 's/^cups-daemon=//p' <<< "$RESOLUTION")"
if [ -z "$CUPS_RESOLVED" ]; then
    echo "::error::cups-daemon is not in the resolution - the simulation does not describe this image"
    exit 1
fi
if [ -n "${APT_RESOLUTION_FILE:-}" ]; then
    printf '%s\n' "$RESOLUTION" > "$APT_RESOLUTION_FILE"
fi

APT_FINGERPRINT="$(printf '%s\n' "$RESOLUTION" | sha256sum | cut -c1-16)"
if ! REPO_REVS="$(git rev-parse HEAD:Dockerfile HEAD:root HEAD:.dockerignore 2>&1)"; then
    echo "::error::cannot read the build inputs at HEAD: ${REPO_REVS}"
    exit 1
fi
REPO_INPUTS="$(printf '%s\n' "$REPO_REVS" | sha256sum | cut -c1-16)"
HASH="$(printf '%s\n%s\n' "$REPO_INPUTS" "$APT_FINGERPRINT" | sha256sum | cut -c1-16)"

# One registry read: the annotations on the published index. Nothing published yet (or not
# readable) reads as "no fingerprint", which publishes.
PUB_RAW="$(docker buildx imagetools inspect "${IMAGE}:latest" --raw 2>/dev/null || printf '{}')"
jq_ann() { printf '%s' "$PUB_RAW" | jq -r ".annotations[\"$1\"] // \"\"" 2>/dev/null || printf ''; }
PUBLISHED="$(jq_ann 'io.cookiesncache.inputs')"
PUB_APT="$(jq_ann 'io.cookiesncache.cups.apt.fingerprint')"
PUB_VER="$(jq_ann 'org.opencontainers.image.version')"

FORCE_PUBLISH=false
if [ "${EVENT_NAME:-}" = "workflow_dispatch" ] && [ "${IN_FORCE:-false}" = "true" ]; then
    FORCE_PUBLISH=true
fi

if [ "$FORCE_PUBLISH" != "true" ] && [ -n "$PUBLISHED" ] && [ "$PUBLISHED" = "$HASH" ]; then
    PUBLISH=false
else
    PUBLISH=true
fi

# Say WHICH input moved, so a publish is never a mystery in the log.
if [ -z "$PUBLISHED" ]; then
    WHY="nothing published yet (or the published index is unreadable)"
elif [ "$PUBLISHED" = "$HASH" ]; then
    WHY="no input changed${FORCE_PUBLISH:+ (force=${FORCE_PUBLISH})}"
elif [ -n "$PUB_APT" ] && [ "$PUB_APT" != "$APT_FINGERPRINT" ]; then
    WHY="Ubuntu package resolution changed (apt ${PUB_APT} -> ${APT_FINGERPRINT})"
else
    WHY="repository build inputs changed (Dockerfile, root/ or .dockerignore - including the base digest)"
fi

{
    echo "publish=$PUBLISH"
    echo "hash=$HASH"
    echo "apt_fingerprint=$APT_FINGERPRINT"
    echo "base_name=$BASE_NAME"
    echo "base_digest=$BASE_DIGEST"
} >> "$GITHUB_OUTPUT"

echo "::notice::base ${BASE_REF}; $(wc -l <<< "$RESOLUTION") packages resolve (cups-daemon ${CUPS_RESOLVED}; published ${PUB_VER:-none}); repo ${REPO_INPUTS}, apt ${APT_FINGERPRINT}"
if [ "$PUBLISH" = "true" ]; then
    echo "::notice::publishing: fingerprint ${HASH} (published was '${PUBLISHED:-none}', force_publish=${FORCE_PUBLISH}) - ${WHY}"
else
    echo "::notice::no input changed (fingerprint ${HASH}) - nothing to publish."
fi
