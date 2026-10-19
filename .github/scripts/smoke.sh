#!/usr/bin/env bash
# Boot the built image in every configuration that matters and assert it actually works.
#
# Used by build.yml (between build and push, so a broken image never reaches :latest) and by
# ci.yml (on pull requests). Invoked as `bash .github/scripts/smoke.sh <image-ref>` so it does not
# depend on the executable bit surviving a Windows checkout.
#
# Containers - all started up front, so their boots overlap rather than serialise:
#   main      admin credentials + PRINTER_* (the HP M203 PPD -> socket://127.0.0.1:9100). Image
#             posture, /admin over http and https, printing from a peer, and the M203 filter chain
#             end to end into a raw TCP listener.
#   noadmin   defaults, no admin credentials: the peer may browse, but /admin is refused.
#   narrow    CUPS_ALLOWED_NETWORKS that excludes the test network: the peer may neither browse
#             nor print. Proves the variable is enforced, not merely accepted.
#   airprint  CUPS_AIRPRINT=true + PRINTER_*: dbus-daemon and avahi-daemon up, the queue
#             discoverable with URF in its TXT record, all of it again after `docker restart`
#             (stale pid files; queue auto-create idempotent; Letter kept), and the IPP Everywhere
#             path into ippeveprinter (which needs the D-Bus system bus this container provides).
#   guard-*   a host directory bind-mounted at /run/dbus or /var/run/dbus (what the old template
#             did), or a non-tmpfs volume over /run itself: must refuse to start, and must not
#             touch the mounted files.
#   bad-*     invalid access-control input: must refuse to start.
#   peer      a client on the same docker network, made from the image under test - curl, lp and
#             python3 are already in it. Nothing else is pulled, so no floating helper image can
#             turn an unrelated PR red.
#
# Optional environment:
#   SMOKE_PREFIX     container/network name prefix (default "smoke"; the PID is appended).
#   SMOKE_IPV6_SHIM  path to an LD_PRELOAD shim, for kernels built WITHOUT IPv6 (some sandboxes).
#                    ippeveprinter treats a failed IPv6 listener as fatal, so on such a kernel the IPP
#                    Everywhere test cannot run without one. GitHub's runners have IPv6, and CI never
#                    sets this; without it, a kernel lacking IPv6 is a test failure, not a skip.
set -euo pipefail

# Git Bash on Windows rewrites arguments that look like POSIX paths (/usr/share/..., /run/dbus)
# before docker sees them. Harmless everywhere else.
export MSYS_NO_PATHCONV=1

IMAGE="${1:?usage: smoke.sh <image-ref>}"
BASE="${SMOKE_PREFIX:-smoke}-$$"
NET="${BASE}-net"
MAIN="${BASE}-main"
NOADMIN="${BASE}-noadmin"
NARROW="${BASE}-narrow"
AIRPRINT="${BASE}-airprint"
GUARD_RUN="${BASE}-guard-run"
GUARD_VARRUN="${BASE}-guard-varrun"
GUARD_HOSTRUN="${BASE}-guard-hostrun"
RUNVOL="${BASE}-runvol"   # a named (disk-backed, not tmpfs) volume standing in for a host /run
BAD_ALL="${BASE}-bad-all"
BAD_NL="${BASE}-bad-newline"
PEER="${BASE}-peer"
CONTAINERS=("$MAIN" "$NOADMIN" "$NARROW" "$AIRPRINT" "$GUARD_RUN" "$GUARD_VARRUN" "$GUARD_HOSTRUN" "$BAD_ALL" "$BAD_NL" "$PEER")

QUEUE=M203
M203_MODEL='postscript-hp:0/ppd/hplip/HP/hp-laserjet_pro_m203_m206-ps.ppd'
TESTDOC=/usr/share/cups/data/default-testpage.pdf
ADMIN_USER=smokeadmin
ADMIN_PASS="$(od -An -tx1 -N16 /dev/urandom | tr -d ' \n')"
AP_HOST="${BASE}-ap"   # --hostname of the AirPrint container; a single DNS label

# Stand-in for the host's /var/run/dbus, which the abandoned 2021 template mapped into the container.
HOSTDBUS="$(mktemp -d)"

cleanup() {
    docker rm -f "${CONTAINERS[@]}" >/dev/null 2>&1 || true
    docker network rm "$NET" >/dev/null 2>&1 || true
    docker volume rm "$RUNVOL" >/dev/null 2>&1 || true
    rm -rf "$HOSTDBUS" 2>/dev/null || true
}
trap cleanup EXIT

fail=0
bad()  { echo "::error::$*"; fail=1; }
pass() { echo "  PASS  $*"; }

# Match without a pipe.
#
# `producer | grep -q PATTERN` is a trap under `set -o pipefail`: grep -q exits the moment it
# matches, closing the pipe, so the producer dies of SIGPIPE (141). pipefail then reports 141 for the
# whole pipeline and a SUCCESSFUL match reads as a failure. Worse, it is size dependent - output that
# fits the 64KB pipe buffer is written before grep exits and the check passes - so it fails
# intermittently as output grows (docker-openclaw learnt this the hard way).
#
# A here-string feeds grep from a temporary file rather than a pipe, so there is no producer to
# signal. Capture command output into a variable first, then match against it. Patterns are EREs.
has() { # <ERE> <text>
    grep -qE -- "$1" <<< "$2"
}
expect() { # <description> <ERE> <text>
    if has "$2" "$3"; then pass "$1"; else bad "$1 (no match for /$2/)"; fi
}
expect_not() { # <description> <ERE> <text>
    if has "$2" "$3"; then bad "$1 (unexpected match for /$2/)"; else pass "$1"; fi
}
expect_eq() { # <description> <got> <want>
    if [ "$2" = "$3" ]; then pass "$1"; else bad "$1: got '$2', want '$3'"; fi
}

# Every exec pins LC_ALL=C so lpstat/lpoptions wording is stable for the matches below.
cx() { # <container> <command...>
    local c="$1"; shift
    docker exec -e LC_ALL=C "$c" "$@"
}

tail_logs() { # <container> [lines]
    local logs
    logs="$(docker logs "$1" 2>&1 || true)"
    printf '%s\n' "$logs" | tail -n "${2:-40}" | sed 's/^/    | /'
}

wait_healthy() { # <container> [timeout seconds]
    local c="$1" t="${2:-150}" start=$SECONDS st
    while (( SECONDS - start < t )); do
        st="$(docker inspect -f '{{.State.Status}}/{{if .State.Health}}{{.State.Health.Status}}{{end}}' "$c" 2>/dev/null || echo gone/)"
        case "$st" in
            running/healthy) echo "  [$c] healthy after $(( SECONDS - start ))s"; return 0 ;;
            running/*) ;;
            *) break ;;
        esac
        sleep 1
    done
    bad "[$c] never became healthy (${st})"
    tail_logs "$c" 60
    return 1
}

wait_stopped() { # <container> [timeout seconds]
    local c="$1" t="${2:-90}" start=$SECONDS
    while (( SECONDS - start < t )); do
        [ "$(docker inspect -f '{{.State.Running}}' "$c" 2>/dev/null || echo gone)" = true ] || return 0
        sleep 1
    done
    return 1
}

wait_log() { # <container> <ERE> [timeout seconds]
    local c="$1" pat="$2" t="${3:-90}" start=$SECONDS logs
    while (( SECONDS - start < t )); do
        logs="$(docker logs "$c" 2>&1 || true)"
        has "$pat" "$logs" && return 0
        sleep 1
    done
    return 1
}

ip_of() { # <container> -> its address on $NET
    docker inspect -f "{{(index .NetworkSettings.Networks \"${NET}\").IPAddress}}" "$1" 2>/dev/null || true
}

# HTTP status as the peer sees it; "000" means no HTTP response at all.
peer_code() { # <curl args...>
    docker exec "$PEER" curl -sk -o /dev/null --max-time 20 -w '%{http_code}' "$@" 2>/dev/null || true
}

# init-cups-queue's LAST step is making a freshly created queue the default destination, so seeing
# that means auto-create has finished (the healthcheck only says cupsd answers - the queue lands a
# few seconds later).
wait_queue() { # <container> <queue>
    local c="$1" q="$2" start=$SECONDS out=""
    while (( SECONDS - start < 90 )); do
        out="$(cx "$c" lpstat -d 2>/dev/null || true)"
        [ "$out" = "system default destination: ${q}" ] && return 0
        sleep 1
    done
    bad "[$c] queue ${q} was not auto-created within 90s (lpstat -d: '${out}')"
    tail_logs "$c"
    return 1
}

listening() { # <container> <hex port> -> exit 0 when something LISTENs on it (IPv4)
    local tcp
    tcp="$(cx "$1" cat /proc/net/tcp 2>/dev/null || true)"
    has ":$2 00000000:0000 0A " "$tcp"
}
wait_listening() { # <container> <hex port> [timeout seconds]
    local start=$SECONDS
    while (( SECONDS - start < ${3:-15} )); do
        listening "$1" "$2" && return 0
        sleep 0.5
    done
    return 1
}

# The PPD default the queue's PageSize option currently has (lpoptions marks it with `*`).
default_pagesize() { # <container> <queue>
    local out
    out="$(cx "$1" lpoptions -p "$2" -l 2>/dev/null || true)"
    sed -n -E '/^PageSize\//{s/.*[*]([^ ]+).*/\1/p;q;}' <<< "$out"
}

queue_count() { # <container>
    local out
    out="$(cx "$1" lpstat -v 2>/dev/null || true)"
    grep -c '^device for ' <<< "$out" || true
}

# Job state straight from cupsd over IPP. lpstat's "completed" list also contains ABORTED and
# CANCELED jobs, so it cannot tell a delivered job from a failed one; job-state can.
job_attrs() { # <container> <job number>
    # -t (test mode) is what makes -v print the response; -v alone prints nothing.
    cx "$1" ipptool -tv "ipp://localhost/jobs/$2" get-job-attributes.test 2>/dev/null || true
}
wait_job() { # <container> <job number> -> 0 when completed; prints the attributes otherwise
    local c="$1" n="$2" start=$SECONDS attrs="" st=""
    while (( SECONDS - start < 120 )); do
        attrs="$(job_attrs "$c" "$n")"
        st="$(sed -n -E '/job-state \(enum\) = /{s/.*= ([a-z-]+).*/\1/p;q;}' <<< "$attrs")"
        case "$st" in
            completed) return 0 ;;
            aborted|canceled) break ;;
        esac
        sleep 2
    done
    echo "    job ${n} on ${c} ended as '${st:-unknown}':"
    grep -E 'job-state|job-printer-state-message' <<< "$attrs" | sed 's/^ */    | /' || true
    tail_logs "$c" 30
    return 1
}

submitted_job() { # <lp output> -> the job number, or empty
    sed -n -E 's/^request id is [^ ]+-([0-9]+) .*/\1/p' <<< "$1"
}

# Raw AppSocket/JetDirect sink on 127.0.0.1:9100: every connection is one job, saved to its own file.
LISTENER='
import socket, sys
out = sys.argv[1]
s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", 9100))
s.listen(5)
n = 0
while True:
    c, _ = s.accept()
    n += 1
    with open("%s-%d.bin" % (out, n), "wb") as f:
        while True:
            b = c.recv(65536)
            if not b:
                break
            f.write(b)
    c.close()
'

# One IPP operation from the peer, Basic credentials sent UP FRONT (not in answer to a challenge) -
# what a script or a misconfigured client does. Prints "<HTTP status> <IPP status>".
IPP_OP='
import base64, http.client, ssl, struct, sys
scheme, host, op, path, auth = sys.argv[1], sys.argv[2], int(sys.argv[3], 16), sys.argv[4], sys.argv[5]
def attr(tag, name, value):
    n, v = name.encode(), value.encode()
    return bytes([tag]) + struct.pack(">H", len(n)) + n + struct.pack(">H", len(v)) + v
body = (struct.pack(">BBHI", 2, 0, op, 1) + b"\x01"
        + attr(0x47, "attributes-charset", "utf-8")
        + attr(0x48, "attributes-natural-language", "en")
        + attr(0x45, "printer-uri", "ipp://localhost" + path) + b"\x03")
if scheme == "https":
    c = http.client.HTTPSConnection(host, 631, context=ssl._create_unverified_context(), timeout=20)
else:
    c = http.client.HTTPConnection(host, 631, timeout=20)
c.request("POST", path, body, {"Content-Type": "application/ipp",
                               "Authorization": "Basic " + base64.b64encode(auth.encode()).decode()})
r = c.getresponse()
data = r.read()
print(r.status, "0x%04x" % struct.unpack(">H", data[2:4])[0] if r.status == 200 and len(data) >= 4 else "-")
'

# Subject and SHA-256 fingerprint of the certificate served on <host>:631, as the peer sees it
# (direct TLS, so no Host: header is involved).
peer_cert() { # <host>
    docker exec "$PEER" sh -c "echo | timeout 10 openssl s_client -connect '$1:631' 2>/dev/null | openssl x509 -noout -subject -fingerprint -sha256" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Start everything
# ---------------------------------------------------------------------------
echo "== starting containers (${BASE}) from ${IMAGE} =="
docker network create "$NET" >/dev/null

queue_env=(-e "PRINTER_NAME=${QUEUE}" -e "PRINTER_MODEL=${M203_MODEL}" -e "PRINTER_URI=socket://127.0.0.1:9100")
start() { # <name> <docker run args...>
    local name="$1"; shift
    docker run -d --name "$name" "$@" "$IMAGE" >/dev/null
}

start "$MAIN" --network "$NET" -e PUID=99 -e PGID=100 -e TZ=Etc/UTC \
    -e "CUPS_ADMIN_USER=${ADMIN_USER}" -e "CUPS_ADMIN_PASSWORD=${ADMIN_PASS}" "${queue_env[@]}"
start "$NOADMIN" --network "$NET"
# 192.0.2.0/24 is TEST-NET-1 (RFC 5737): never a docker network, so the peer is outside it.
start "$NARROW" --network "$NET" -e CUPS_ALLOWED_NETWORKS=192.0.2.0/24 "${queue_env[@]}"
start "$AIRPRINT" --network "$NET" --hostname "$AP_HOST" -e CUPS_AIRPRINT=true "${queue_env[@]}"

printf 'host-socket-sentinel\n' > "${HOSTDBUS}/system_bus_socket"
printf '4242\n' > "${HOSTDBUS}/pid"
start "$GUARD_RUN" -v "${HOSTDBUS}:/run/dbus"
start "$GUARD_VARRUN" -v "${HOSTDBUS}:/var/run/dbus" -e CUPS_AIRPRINT=true
# A host directory over the whole /run hides the host's bus BELOW the mount point. A named volume
# (disk-backed, not tmpfs) stands in for it, so the runner never gets root-owned files from s6.
docker volume create "$RUNVOL" >/dev/null
start "$GUARD_HOSTRUN" -v "${RUNVOL}:/var/run" -e CUPS_AIRPRINT=true
start "$BAD_ALL" -e CUPS_ALLOWED_NETWORKS=all
start "$BAD_NL" -e "CUPS_SERVER_ALIASES=tower"$'\n'"ServerAlias *"

docker run -d --name "$PEER" --network "$NET" --no-healthcheck --entrypoint sleep "$IMAGE" infinity >/dev/null

# ---------------------------------------------------------------------------
# main: posture, /admin, peer printing, the M203 chain
# ---------------------------------------------------------------------------
section_main() {
    local ip posture out job cap logs
    echo "== main container (admin credentials, ${QUEUE} queue) =="
    wait_healthy "$MAIN" || return 0
    # Started now so it is listening long before the queue exists and the peer prints.
    docker exec -d "$MAIN" python3 -c "$LISTENER" /tmp/smoke-capture

    # Image posture. Each probe prints a tagged line only when something is WRONG (or to report a
    # value), so the assertions below are plain "no such line" checks.
    # shellcheck disable=SC2016 # the script runs, and expands, inside the container
    posture="$(cx "$MAIN" bash -c '
        for p in systemd systemd-sysv cups-browsed colord ipp-usb libnss-mdns hplip printer-driver-all; do
            s="$(dpkg-query -W -f="\${Status}" "$p" 2>/dev/null || true)"
            if [ "$s" = "install ok installed" ]; then echo "PKG $p"; fi
        done
        for f in /usr/bin/systemctl /usr/lib/systemd/systemd /lib/systemd/systemd \
                 /usr/sbin/cups-browsed /usr/libexec/colord /usr/lib/colord/colord; do
            if [ -e "$f" ]; then echo "BIN $f"; fi
        done
        for b in systemctl cups-browsed colord; do
            if command -v "$b" >/dev/null 2>&1; then echo "BIN $b"; fi
        done
        echo "BACKENDS $(ls -1 /usr/lib/cups/backend | LC_ALL=C sort | tr "\n" " ")"
        find / -xdev -name "*snakeoil*" 2>/dev/null | sed "s/^/SNAKEOIL /"
        find /etc/ssl/certs -xtype l 2>/dev/null | sed "s/^/DANGLING /"
        h=/usr/lib/dbus-1.0/dbus-daemon-launch-helper
        if [ -u "$h" ] || [ -g "$h" ]; then echo "SETID $h"; fi
        echo "HELPER $(stat -c "%a %U:%G" "$h")"
        for d in dbus-daemon avahi-daemon cups-browsed; do
            if pgrep -x "$d" >/dev/null; then echo "RUNNING $d"; fi
        done
        echo "CUPSD $(ps -o user= -C cupsd | sed -n 1p)"
        echo "CONF $(stat -c "%a %U:%G" /config/cups/cupsd.conf /config/cups/cups-files.conf | tr "\n" " ")"
        grep "^cups-daemon=" /package_versions.txt | sed "s/^/VERSION /"
        echo END
    ' 2>&1 || true)"
    expect     "probe ran"                                      '^END$'                 "$posture"
    expect_not "no systemd/cups-browsed/colord/ipp-usb/... packages" '^PKG '            "$posture"
    expect_not "no systemd/cups-browsed/colord binaries"        '^BIN '                 "$posture"
    expect     "backends are exactly http https ipp ipps socket usb" '^BACKENDS http https ipp ipps socket usb $' "$posture"
    expect_not "no snakeoil key/cert anywhere"                  '^SNAKEOIL '            "$posture"
    expect_not "no dangling certificate links"                  '^DANGLING '            "$posture"
    expect_not "D-Bus launch helper is not setuid/setgid"       '^SETID '               "$posture"
    expect     "D-Bus launch helper is 755 root:root"           '^HELPER 755 root:root$' "$posture"
    expect_not "dbus/avahi idle and no cups-browsed with AirPrint off" '^RUNNING '      "$posture"
    expect     "cupsd runs as root"                             '^CUPSD root$'          "$posture"
    expect     "cupsd.conf and cups-files.conf are 640 root:lp" '^CONF 640 root:lp 640 root:lp $' "$posture"
    expect     "/package_versions.txt records cups-daemon"      '^VERSION cups-daemon=2\.' "$posture"
    sed -n 's/^VERSION /  image ships /p' <<< "$posture"

    ip="$(ip_of "$MAIN")"
    expect_eq "/admin over plain http -> 426 Upgrade Required"  "$(peer_code "http://${ip}:631/admin")" 426
    expect_eq "/admin over https, no credentials -> 401"        "$(peer_code "https://${ip}:631/admin")" 401
    expect_eq "/admin over https, wrong password -> 401"        "$(peer_code -u "${ADMIN_USER}:wrong-${ADMIN_PASS}" "https://${ip}:631/admin")" 401
    expect_eq "/admin over https, admin credentials -> 200"     "$(peer_code -u "${ADMIN_USER}:${ADMIN_PASS}" "https://${ip}:631/admin")" 200
    expect_eq "Host header that is not an alias -> 400"         "$(peer_code -H 'Host: rebind.example' "http://${ip}:631/")" 400

    # One certificate, named after the stable server name: this container's hostname is Docker's
    # random ID, so that is the "unraid-cups" fallback - on the container's address AND on localhost
    # (cupsd would otherwise mint one named after the reverse lookup of each address).
    out="$(peer_cert "$ip")"
    expect "certificate on the container IP is CN=unraid-cups (not the container ID)" 'CN ?= ?unraid-cups(,|$)' "$out"
    expect_eq "the same certificate on the container IP and on localhost" \
        "$(sed -n 's/^sha256 Fingerprint=//Ip' <<< "$out")" \
        "$(cx "$MAIN" sh -c 'echo | timeout 10 openssl s_client -connect 127.0.0.1:631 2>/dev/null | openssl x509 -noout -fingerprint -sha256' 2>/dev/null | sed -n 's/^sha256 Fingerprint=//Ip')"

    wait_queue "$MAIN" "$QUEUE" || return 0
    wait_listening "$MAIN" 238C || bad "the raw TCP listener on 127.0.0.1:9100 never came up"

    # A password-protected IPP operation with GOOD credentials sent up front: refused over plain http
    # (426, so the password is never accepted in cleartext), accepted over TLS. CUPS-Accept-Jobs on
    # a queue that already accepts jobs changes nothing.
    expect_eq "IPP admin op over plain http, good credentials sent up front -> 426" \
        "$(docker exec "$PEER" python3 -c "$IPP_OP" http "$ip" 4008 "/printers/${QUEUE}" "${ADMIN_USER}:${ADMIN_PASS}" 2>&1 || true)" "426 -"
    expect_eq "IPP admin op over TLS, good credentials -> successful-ok" \
        "$(docker exec "$PEER" python3 -c "$IPP_OP" https "$ip" 4008 "/printers/${QUEUE}" "${ADMIN_USER}:${ADMIN_PASS}" 2>&1 || true)" "200 0x0000"

    # Printing from another container on the same network, allowed by the default
    # CUPS_ALLOWED_NETWORKS (the docker network is inside 172.16.0.0/12 / 10.0.0.0/8 / 192.168.0.0/16).
    # The job runs the real M203 chain: pdftopdf -> pdftops (Ghostscript) -> hpps -> socket backend.
    out="$(docker exec "$PEER" lp -h "${ip}:631" -d "$QUEUE" "$TESTDOC" 2>&1 || true)"
    job="$(submitted_job "$out")"
    if [ -z "$job" ]; then
        bad "peer could not print to ${QUEUE}: ${out}"
    else
        pass "peer print accepted (job ${job})"
        if wait_job "$MAIN" "$job"; then
            pass "M203 job ${job} completed"
        else
            bad "M203 job ${job} did not complete"
        fi
        # Printable bytes only: PJL starts with ESC (UEL) and the stream may contain NULs.
        cap="$(cx "$MAIN" sh -c 'cat /tmp/smoke-capture-*.bin 2>/dev/null | head -c 65536 | tr -c "[:print:]\n" "."' || true)"
        expect "M203 stream starts PJL in PostScript mode" '@PJL ENTER LANGUAGE=POSTSCRIPT' "$cap"
        expect "M203 stream carries PostScript"           '%!PS-Adobe'                     "$cap"
    fi

    logs="$(docker logs "$MAIN" 2>&1 || true)"
    expect_not "admin password never appears in the log" "$ADMIN_PASS" "$logs"
}

# ---------------------------------------------------------------------------
# noadmin: no admin credentials -> /admin is localhost-only
# ---------------------------------------------------------------------------
section_noadmin() {
    local ip
    echo "== noadmin container (defaults) =="
    wait_healthy "$NOADMIN" || return 0
    ip="$(ip_of "$NOADMIN")"
    expect_eq "peer may browse / (default allowed networks)" "$(peer_code "http://${ip}:631/")" 200
    expect_eq "peer is refused /admin without admin credentials configured" "$(peer_code "http://${ip}:631/admin")" 403
    expect_eq "peer is refused /admin over https too" "$(peer_code "https://${ip}:631/admin")" 403
}

# ---------------------------------------------------------------------------
# narrow: CUPS_ALLOWED_NETWORKS excludes the peer
# ---------------------------------------------------------------------------
section_narrow() {
    local ip out
    echo "== narrow container (CUPS_ALLOWED_NETWORKS=192.0.2.0/24) =="
    wait_healthy "$NARROW" || return 0
    wait_queue "$NARROW" "$QUEUE" || return 0
    ip="$(ip_of "$NARROW")"
    expect_eq "peer outside CUPS_ALLOWED_NETWORKS is refused /" "$(peer_code "http://${ip}:631/")" 403
    out="$(docker exec "$PEER" lp -h "${ip}:631" -d "$QUEUE" "$TESTDOC" 2>&1 || true)"
    if [ -n "$(submitted_job "$out")" ]; then
        bad "peer outside CUPS_ALLOWED_NETWORKS could print: ${out}"
    else
        pass "peer outside CUPS_ALLOWED_NETWORKS cannot print (${out})"
    fi
    out="$(cx "$NARROW" lp -d "$QUEUE" -H hold "$TESTDOC" 2>&1 || true)"
    if [ -n "$(submitted_job "$out")" ]; then pass "local printing still works"; else bad "local print refused: ${out}"; fi
}

# ---------------------------------------------------------------------------
# airprint: dbus + avahi, discovery, restart, queue idempotency, IPP Everywhere
# ---------------------------------------------------------------------------
discover() { # -> exit 0 when the queue is browsable as _ipp._tcp,_universal with URF in TXT
    local attempt out=""
    for attempt in 1 2 3 4; do
        out="$(cx "$AIRPRINT" timeout 30 ippfind -T 5 _ipp._tcp,_universal -x echo '{service_name} URF={txt_urf}' ';' 2>/dev/null || true)"
        if has "^${QUEUE} @ .* URF=V[0-9]" "$out"; then
            sed -n "s/^${QUEUE} @ /    found (attempt ${attempt}): ${QUEUE} @ /p" <<< "$out"
            return 0
        fi
        sleep 2
    done
    echo "    ippfind saw: ${out:-(nothing)}"
    return 1
}

airprint_daemons() { # <when>
    local procs ready
    # shellcheck disable=SC2016 # expands inside the container
    procs="$(cx "$AIRPRINT" sh -c 'for d in dbus-daemon avahi-daemon cupsd; do printf "%s=%s\n" "$d" "$(pgrep -x "$d" | sed -n 1p)"; done' || true)"
    expect "dbus-daemon running ($1)"  '^dbus-daemon=[0-9]+$'  "$procs"
    expect "avahi-daemon running ($1)" '^avahi-daemon=[0-9]+$' "$procs"
    ready="$(cx "$AIRPRINT" s6-svstat -o ready /run/service/svc-dbus 2>/dev/null || true)"
    expect_eq "svc-dbus signalled readiness ($1)" "$ready" true
}

section_airprint() {
    local pc out job preload=""
    echo "== airprint container (CUPS_AIRPRINT=true, --hostname ${AP_HOST}) =="
    wait_healthy "$AIRPRINT" || return 0
    wait_queue "$AIRPRINT" "$QUEUE" || return 0
    airprint_daemons "first boot"

    pc="$(cx "$AIRPRINT" cat /config/cups/printers.conf 2>/dev/null || true)"
    expect    "auto-created queue is shared"           '^Shared Yes$'             "$pc"
    expect    "auto-created queue retries jobs"        '^ErrorPolicy retry-job$'  "$pc"
    expect_eq "auto-created queue defaults to Letter"  "$(default_pagesize "$AIRPRINT" "$QUEUE")" Letter
    if discover; then pass "queue discoverable via ippfind _ipp._tcp,_universal with URF"; else bad "queue not discoverable via ippfind _ipp._tcp,_universal"; fi
    expect "certificate CN is the --hostname (${AP_HOST})" "CN ?= ?${AP_HOST}(,|\$)" "$(peer_cert "$(ip_of "$AIRPRINT")")"

    # s6-overlay v3 does not wipe /run on `docker restart`, so the dbus and avahi pid files from the
    # first boot are still there. The restart must cope with them, and must not recreate the queue.
    docker restart "$AIRPRINT" >/dev/null
    if ! wait_log "$AIRPRINT" "queue: '${QUEUE}' already exists - leaving its settings alone" 120; then
        bad "after docker restart, init-cups-queue did not report the existing queue"
        tail_logs "$AIRPRINT" 60
        return 0
    fi
    pass "PRINTER_* auto-create is idempotent across docker restart"
    wait_healthy "$AIRPRINT" || return 0
    airprint_daemons "after docker restart"
    expect_eq "still exactly one queue after restart"  "$(queue_count "$AIRPRINT")" 1
    expect_eq "Letter default kept across restart"     "$(default_pagesize "$AIRPRINT" "$QUEUE")" Letter
    if discover; then pass "still discoverable after docker restart"; else bad "not discoverable after docker restart"; fi

    # IPP Everywhere: an `everywhere` queue generated from ippeveprinter's own attributes, one job,
    # and the document must land in ippeveprinter's spool (-k keeps it).
    if ! cx "$AIRPRINT" python3 -c 'import socket; socket.socket(socket.AF_INET6).close()' 2>/dev/null; then
        if [ -n "${SMOKE_IPV6_SHIM:-}" ] && [ -f "$SMOKE_IPV6_SHIM" ]; then
            docker cp "$SMOKE_IPV6_SHIM" "${AIRPRINT}:/tmp/smoke-ipv6-shim.so"
            preload=/tmp/smoke-ipv6-shim.so
            echo "  note: this kernel has no IPv6 - running ippeveprinter under SMOKE_IPV6_SHIM"
        else
            bad "this kernel has no IPv6, and ippeveprinter cannot start without an IPv6 listener (see SMOKE_IPV6_SHIM)"
            return 0
        fi
    fi
    docker exec -d -e "SMOKE_PRELOAD=${preload}" "$AIRPRINT" bash -c '
        mkdir -p /tmp/smoke-eve
        if [ -n "$SMOKE_PRELOAD" ]; then export LD_PRELOAD="$SMOKE_PRELOAD"; fi
        exec ippeveprinter -p 8631 -n localhost -k -d /tmp/smoke-eve -r off \
            -f application/pdf,image/pwg-raster,image/urf SmokeEverywhere >/tmp/smoke-eve.log 2>&1'
    if ! wait_listening "$AIRPRINT" 21B7; then
        bad "ippeveprinter did not start"
        cx "$AIRPRINT" cat /tmp/smoke-eve.log 2>&1 | sed 's/^/    | /' || true
        return 0
    fi
    out="$(cx "$AIRPRINT" timeout 120 lpadmin -p Everywhere -E -v ipp://localhost:8631/ipp/print -m everywhere 2>&1 || true)"
    if [ -n "$out" ] || [ "$(cx "$AIRPRINT" lpstat -v Everywhere 2>/dev/null || true)" = "" ]; then
        bad "lpadmin -m everywhere failed: ${out}"
        return 0
    fi
    out="$(cx "$AIRPRINT" lp -d Everywhere "$TESTDOC" 2>&1 || true)"
    job="$(submitted_job "$out")"
    if [ -z "$job" ]; then
        bad "could not print to the everywhere queue: ${out}"
        return 0
    fi
    if wait_job "$AIRPRINT" "$job"; then pass "IPP Everywhere job ${job} completed"; else bad "IPP Everywhere job ${job} did not complete"; fi
    out="$(cx "$AIRPRINT" find /tmp/smoke-eve -type f -size +0c 2>/dev/null || true)"
    expect "the document reached ippeveprinter's spool" '.' "$out"
}

# ---------------------------------------------------------------------------
# Containers that must refuse to start
# ---------------------------------------------------------------------------
refuses() { # <container> <description> <ERE the log must contain>
    local c="$1" what="$2" pat="$3" code logs
    if ! wait_stopped "$c"; then
        bad "${what}: still running - it should have refused to start"
        tail_logs "$c" 30
        return 0
    fi
    code="$(docker inspect -f '{{.State.ExitCode}}' "$c" 2>/dev/null || echo '?')"
    logs="$(docker logs "$c" 2>&1 || true)"
    if [ "$code" = 0 ]; then bad "${what}: exited 0 - expected a non-zero exit"; fi
    if has "$pat" "$logs"; then
        pass "${what}: refused to start (exit ${code})"
    else
        bad "${what}: the log does not say why (no /${pat}/)"
        tail_logs "$c" 30
    fi
    # LSIO prints this once every init step - ours included - has run. Seeing it would mean the
    # failure happened after init, i.e. cupsd may already have been up.
    expect_not "${what}: init never completed" '\[ls\.io-init\] done\.' "$logs"
}

section_refusals() {
    local listing logs
    echo "== containers that must refuse to start =="
    refuses "$GUARD_RUN"    "host dir mounted at /run/dbus"            'host D-Bus directory/socket is mounted'
    refuses "$GUARD_VARRUN" "host dir mounted at /var/run/dbus (AirPrint on)" 'host D-Bus directory/socket is mounted'
    expect_eq "the mounted host files were not touched" \
        "$(cat "${HOSTDBUS}/system_bus_socket" "${HOSTDBUS}/pid" 2>&1 || true)" "$(printf 'host-socket-sentinel\n4242')"
    listing="$(cd "$HOSTDBUS" && ls -A)"
    expect_eq "nothing was added to the mounted host directory" "$(tr '\n' ' ' <<< "$listing")" "pid system_bus_socket "
    refuses "$GUARD_HOSTRUN" "non-tmpfs volume mounted over /var/run (AirPrint on)" 'host directory is mounted over'
    refuses "$BAD_ALL"      "CUPS_ALLOWED_NETWORKS=all"                "refusing to start"
    refuses "$BAD_NL"       "newline injected into CUPS_SERVER_ALIASES" "refusing to start"
    logs="$(docker logs "$BAD_ALL" 2>&1 || true)"
    expect "CUPS_ALLOWED_NETWORKS=all: the error names the variable" 'CUPS_ALLOWED_NETWORKS' "$logs"
    logs="$(docker logs "$BAD_NL" 2>&1 || true)"
    expect "newline injection: the error names the problem" 'control character' "$logs"
}

section_main
section_noadmin
section_narrow
section_airprint
section_refusals

if [ "$fail" != 0 ]; then
    echo "::error::smoke test failed"
    exit 1
fi

echo "::notice::smoke test passed (posture, /admin over http+https, peer printing allowed and refused per CUPS_ALLOWED_NETWORKS, M203 PJL/PostScript chain, IPP Everywhere, AirPrint discovery across restart, queue idempotency, one stable TLS certificate, TLS-only admin IPP, D-Bus and /run guards, fail-closed input)"
