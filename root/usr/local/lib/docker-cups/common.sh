# shellcheck shell=bash
# shellcheck disable=SC2034 # the CUPS_* globals are this library's outputs, read by its callers
#
# Shared helpers for docker-cups' s6 scripts and /usr/local/bin helpers. SOURCED, never executed.
#
# Ground rules for everything in here:
#   - Validators print NOTHING. They return 0/1 and, where useful, leave the normalised value in
#     CUPS_OUT and a human-readable reason in CUPS_WHY. They are called directly (not in $(...)),
#     so those globals reach the caller; the logging belongs to the caller.
#   - Values come from the container environment, i.e. from whoever controls the Unraid template.
#     They are only ever compared with [[ =~ ]]/case and passed as single, quoted argv elements.
#     Nothing here (or in any caller) evals, sources or word-splits an environment value.
#   - Empty means unset: Unraid passes blank template fields through as empty strings.

# GECOS (comment) field of the admin account this image creates. It is how init-cups-config tells
# "an account we made on an earlier boot" apart from an account that came with the image (lp,
# messagebus, avahi, ...), which must never be repurposed as a CUPS admin.
CUPS_ADMIN_GECOS="docker-cups admin account"

# Built-in fallback for the server / mDNS host name when the container's hostname is Docker's
# random container ID (which changes on every recreate and would rotate the TLS certificate).
CUPS_FALLBACK_HOSTNAME="unraid-cups"

CUPS_OUT=""
CUPS_WHY=""

cups_log()  { printf '**** %s ****\n' "$*"; }
cups_warn() { printf '**** WARN: %s ****\n' "$*" >&2; }
cups_err()  { printf '**** ERROR: %s ****\n' "$*" >&2; }

# Render a value for a log line with every control character escaped ($'a\nb'), so an injected
# newline shows up as \n instead of forging a second log line. Never call this on a secret.
cups_show() { printf '%q' "$1"; }

# True if the value contains any control character (newline, CR, tab, ESC, NUL-adjacent bytes...).
cups_has_ctrl() { [[ "$1" == *[[:cntrl:]]* ]]; }

# ---- booleans ----------------------------------------------------------------------------------
# true/false/yes/no/on/off/1/0, case-insensitive. Anything else (including surrounding spaces) is
# an error: a typo must not silently become either value. Empty -> the given default.
cups_parse_bool() {
    local v="${1:-}" def="${2:-}"
    [[ -n "${v}" ]] || v="${def}"
    case "${v,,}" in
        true|yes|on|1)  CUPS_OUT=true ;;
        false|no|off|0) CUPS_OUT=false ;;
        *) CUPS_WHY="expected true/false (also yes/no, on/off, 1/0)"; return 1 ;;
    esac
}

# ---- addresses and names -----------------------------------------------------------------------
# Dotted-quad IPv4, decimal octets 0-255, no leading zeros (CUPS would not read them as octal, but
# 010.0.0.1 is ambiguous enough to refuse).
cups_valid_ipv4() {
    local o='(25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])'
    [[ "$1" =~ ^${o}\.${o}\.${o}\.${o}$ ]]
}

# Colon-separated hex groups (each 1-4 hex digits). Sets CUPS_OUT to the group count. Empty input
# is zero groups.
_cups_hexgroups() {
    local s="$1" g n=0
    local -a gs
    CUPS_OUT=0
    [[ -z "${s}" ]] && return 0
    [[ "${s}" == :* || "${s}" == *: ]] && return 1
    IFS=: read -r -a gs <<< "${s}"
    for g in "${gs[@]}"; do
        [[ "${g}" =~ ^[0-9A-Fa-f]{1,4}$ ]] || return 1
        n=$((n + 1))
    done
    CUPS_OUT="${n}"
}

# Textual IPv6 address (RFC 4291 forms: full, "::"-compressed, optional trailing dotted IPv4).
cups_valid_ipv6() {
    local a="$1" left right total
    [[ "${a}" =~ ^[0-9A-Fa-f:.]{2,45}$ ]] || return 1
    if [[ "${a}" == *.* ]]; then
        # Embedded IPv4 (e.g. ::ffff:192.0.2.1) counts as two groups.
        cups_valid_ipv4 "${a##*:}" || return 1
        a="${a%:*}:0:0"
        # "::1.2.3.4" became "::0:0", fine; "1.2.3.4" alone has no colon and is not IPv6.
        [[ "${a}" == *:*:0:0 || "${a}" == ::0:0 ]] || return 1
    fi
    if [[ "${a}" == *::* ]]; then
        left="${a%%::*}"; right="${a#*::}"
        [[ "${right}" == *::* ]] && return 1                  # at most one "::"
        _cups_hexgroups "${left}" || return 1; total="${CUPS_OUT}"
        _cups_hexgroups "${right}" || return 1; total=$((total + CUPS_OUT))
        (( total <= 7 ))
    else
        _cups_hexgroups "${a}" || return 1
        (( CUPS_OUT == 8 ))
    fi
}

# _cups_ipv6_zero_prefix ADDR LEN -> 0 when the first LEN bits of ADDR (already validated by
# cups_valid_ipv6) are all zero. Used to spot IPv6 networks that also cover cupsd's internal form of
# every IPv4 address (see cups_check_allow_token).
_cups_ipv6_zero_prefix() {
    local a="$1" len="$2" v4 o1 o2 o3 o4 g val need bits=0 i
    local -a gl gr groups
    if [[ "${a}" == *.* ]]; then
        # Trailing dotted IPv4 -> the two hex groups it stands for.
        v4="${a##*:}"
        IFS=. read -r o1 o2 o3 o4 <<< "${v4}"
        a="${a%:*}:$(printf '%x:%x' $(( (10#${o1} << 8) | 10#${o2} )) $(( (10#${o3} << 8) | 10#${o4} )))"
    fi
    if [[ "${a}" == *::* ]]; then
        gl=(); gr=()
        [[ -n "${a%%::*}" ]] && IFS=: read -r -a gl <<< "${a%%::*}"
        [[ -n "${a#*::}" ]] && IFS=: read -r -a gr <<< "${a#*::}"
        groups=("${gl[@]}")
        for (( i = ${#gl[@]} + ${#gr[@]}; i < 8; i++ )); do groups+=(0); done
        groups+=("${gr[@]}")
    else
        IFS=: read -r -a groups <<< "${a}"
    fi
    for g in "${groups[@]}"; do
        (( bits >= len )) && break
        val=$(( 16#${g} ))
        need=$(( len - bits ))
        if (( need >= 16 )); then
            (( val == 0 )) || return 1
        else
            (( (val >> (16 - need)) == 0 )) || return 1
        fi
        bits=$(( bits + 16 ))
    done
    return 0
}

# One DNS label: letters, digits, inner hyphens, 1-63 chars.
cups_valid_label() {
    [[ "$1" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$ ]]
}

# A dotted host name, 1-253 chars, every label valid.
cups_valid_dns_name() {
    local n="$1" l
    local -a labels
    (( ${#n} >= 1 && ${#n} <= 253 )) || return 1
    [[ "${n}" == .* || "${n}" == *. || "${n}" == *..* ]] && return 1
    IFS=. read -r -a labels <<< "${n}"
    for l in "${labels[@]}"; do cups_valid_label "${l}" || return 1; done
}

# Docker's default hostname is the first 12 hex chars of the container ID.
cups_looks_like_container_id() { [[ "$1" =~ ^[0-9a-f]{12}$ ]]; }

# One CUPS `Allow` token, as accepted in CUPS_ALLOWED_NETWORKS / CUPS_ADMIN_NETWORKS.
# On success CUPS_OUT is the token as it will be written to cupsd.conf and CUPS_KIND is one of
# local|ip|name. On failure CUPS_WHY says why.
#
# Accepted: @LOCAL, @IF(name), IPv4 a.b.c.d[/1-32], IPv6 [addr][/1-128], localhost, and host or
# domain names (host.example.com, *.example.com, .example.com).
# Refused: all / none / * / any /0 prefix (each means "everyone" or "no-one", which is never what a
# LAN print server wants), CUPS' partial-address shorthands ("10", "192.168"), dotted netmasks,
# names starting with a digit (cupsd would try to parse those as addresses), and IPv6 networks that
# overlap ::/96: cupsd stores every IPv4 client as the IPv4-compatible address ::a.b.c.d, so such a
# token - IPv6-looking in cupsd.conf and in the log - admits IPv4 clients: all of them for [::]/1 ...
# [::]/96, a slice of the IPv4 internet for [::]/97 ... [::]/127 ([::]/97 is 0.0.0.0/1). A single
# address ([::1], /128) can match at most one IPv4 client and is left alone.
CUPS_KIND=""
cups_check_allow_token() {
    local t="$1" addr len
    CUPS_OUT=""; CUPS_KIND=""; CUPS_WHY=""
    case "${t,,}" in
        all|none|'*'|any|everyone)
            CUPS_WHY="'${t}' is not allowed - list specific networks instead (CIDRs, @LOCAL, ...)"
            return 1 ;;
        @local)
            CUPS_OUT="@LOCAL"; CUPS_KIND=local; return 0 ;;
        localhost)
            CUPS_OUT="localhost"; CUPS_KIND=local; return 0 ;;
    esac
    if [[ "${t}" =~ ^@[Ii][Ff]\(([A-Za-z0-9_.-]{1,15})\)$ ]]; then
        CUPS_OUT="@IF(${BASH_REMATCH[1]})"; CUPS_KIND=local; return 0
    fi
    if [[ "${t}" == \[* ]]; then
        # IPv6: [addr] or [addr]/len
        if [[ "${t}" =~ ^\[([^]]+)\](/([0-9]{1,3}))?$ ]]; then
            addr="${BASH_REMATCH[1]}"; len="${BASH_REMATCH[3]}"
            if ! cups_valid_ipv6 "${addr}"; then
                CUPS_WHY="'${t}' is not a valid IPv6 address"; return 1
            fi
            if [[ -n "${len}" ]] && { [[ "${len}" =~ ^0[0-9] ]] || (( 10#${len} < 1 || 10#${len} > 128 )); }; then
                CUPS_WHY="'${t}': IPv6 prefix length must be 1-128"; return 1
            fi
            # A network (not a single address) whose first min(len, 96) bits are zero overlaps
            # ::/96, where cupsd keeps IPv4 clients.
            if [[ -n "${len}" ]] && (( 10#${len} < 128 )) \
               && _cups_ipv6_zero_prefix "${addr}" "$(( 10#${len} < 96 ? 10#${len} : 96 ))"; then
                if (( 10#${len} <= 96 )); then
                    CUPS_WHY="'${t}' also matches every IPv4 client (cupsd keeps IPv4 addresses as ::a.b.c.d inside this range) - list IPv4 networks explicitly instead"
                else
                    CUPS_WHY="'${t}' also matches IPv4 clients (cupsd keeps IPv4 addresses as ::a.b.c.d, which this range overlaps) - write IPv4 networks as a.b.c.d/len instead"
                fi
                return 1
            fi
            CUPS_OUT="[${addr,,}]${len:+/$((10#${len}))}"; CUPS_KIND=ip; return 0
        fi
        CUPS_WHY="'${t}' is not of the form [ipv6-address] or [ipv6-address]/length"; return 1
    fi
    if [[ "${t}" == [0-9]* ]]; then
        if [[ "${t}" =~ ^([0-9.]+)(/([0-9]{1,2}))?$ ]]; then
            addr="${BASH_REMATCH[1]}"; len="${BASH_REMATCH[3]}"
            if ! cups_valid_ipv4 "${addr}"; then
                CUPS_WHY="'${t}' is not a valid IPv4 address (use full a.b.c.d/len CIDR notation)"; return 1
            fi
            if [[ -n "${len}" ]] && { [[ "${len}" =~ ^0[0-9] ]] || (( 10#${len} < 1 || 10#${len} > 32 )); }; then
                CUPS_WHY="'${t}': IPv4 prefix length must be 1-32"; return 1
            fi
            CUPS_OUT="${addr}${len:+/$((10#${len}))}"; CUPS_KIND=ip; return 0
        fi
        CUPS_WHY="'${t}' is not valid CIDR notation (a.b.c.d or a.b.c.d/len)"; return 1
    fi
    # Host or domain name; "*.example.com" and ".example.com" both mean "anything in example.com".
    local name="${t}"
    case "${name}" in
        '*.'*) name="${name#\*}" ;;
    esac
    if [[ "${name}" == .* ]]; then
        cups_valid_dns_name "${name#.}" || { CUPS_WHY="'${t}' is not a valid domain"; return 1; }
    else
        cups_valid_dns_name "${name}" || { CUPS_WHY="'${t}' is not a valid address, network or host name"; return 1; }
    fi
    CUPS_OUT="${name,,}"; CUPS_KIND=name
}

# ---- queue (PRINTER_*) values ------------------------------------------------------------------
# Stricter than CUPS itself (which allows most printable characters): letters, digits, _ . -
# so the name is also safe in URLs, file names (ppd/<name>.ppd) and log lines.
cups_valid_queue_name() {
    [[ "$1" =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]{0,126}$ ]]
}

# lpadmin -m value: a driver/PPD name as listed by `lpinfo -m`, or "everywhere".
cups_valid_model() {
    (( ${#1} <= 1024 )) && [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._:/+@%=,~-]*$ ]]
}

# lpadmin -v value, restricted to the backends this image ships.
cups_valid_device_uri() {
    local re='^(usb|socket|ipp|ipps|http|https)://[^[:space:][:cntrl:]"'"'"'\\<>`{}|^]+$'
    (( ${#1} <= 1024 )) && [[ "$1" =~ ${re} ]]
}

# A device URI as it may appear in a log line: any userinfo (user:password@) becomes "***@".
# PRINTER_URI can legitimately carry a network printer's credentials (ipps://user:pass@host/...),
# and docker logs are what people paste into issues. Everything up to the LAST "@" is treated as
# userinfo, so even a malformed URI with an unencoded "/" or "@" in the password cannot leak it.
cups_redact_uri() {
    local u="$1" rest
    if [[ "${u}" == *://*@* ]]; then
        rest="${u#*://}"
        printf '%s://***@%s' "${u%%://*}" "${rest##*@}"
    else
        printf '%s' "${u}"
    fi
}

# printer-info / printer-location are IPP text(127).
cups_valid_text127() {
    ! cups_has_ctrl "$1" && (( ${#1} <= 127 ))
}

# One PRINTER_OPTIONS token: key=value, passed to lpadmin as a single `-o key=value` argument.
cups_valid_option() {
    local re='^[A-Za-z][A-Za-z0-9._-]{0,63}=[^[:space:][:cntrl:]"'"'"'\\`]{1,255}$'
    [[ "$1" =~ ${re} ]]
}

# ---- simple enumerations -----------------------------------------------------------------------
# CUPS_PAPER_SIZE: cupsd's DefaultPaperSize and the PageSize default of auto-created queues. A small
# allow-list of names that are the same in cupsd, PPD files and the IPP Everywhere PPD generator.
# Matching is case-insensitive; CUPS_OUT is the canonical spelling.
cups_check_paper_size() {
    case "${1,,}" in
        letter)    CUPS_OUT=Letter ;;
        legal)     CUPS_OUT=Legal ;;
        executive) CUPS_OUT=Executive ;;
        tabloid)   CUPS_OUT=Tabloid ;;
        statement) CUPS_OUT=Statement ;;
        a3)        CUPS_OUT=A3 ;;
        a4)        CUPS_OUT=A4 ;;
        a5)        CUPS_OUT=A5 ;;
        a6)        CUPS_OUT=A6 ;;
        *) CUPS_WHY="expected one of Letter, Legal, Executive, Tabloid, Statement, A3, A4, A5, A6"
           return 1 ;;
    esac
}

cups_check_log_level() {
    case "${1,,}" in
        none|emerg|alert|crit|error|warn|notice|info|debug|debug2) CUPS_OUT="${1,,}" ;;
        *) CUPS_WHY="expected one of none emerg alert crit error warn notice info debug debug2"
           return 1 ;;
    esac
}

# CUPS_ADMIN_USER: a conventional Linux login name. Existence/reservation is checked separately.
cups_valid_user_name() {
    [[ "$1" =~ ^[a-z_][a-z0-9_-]{0,30}$ ]]
}

# ---- host D-Bus guard ---------------------------------------------------------------------------
# The abandoned 2021 template bind-mounted the HOST's /var/run/dbus read-write. Running our own
# dbus-daemon on top of that would at best fight the host's bus and at worst let in-container
# processes talk to the host's system bus. All three checks below only READ; callers must run them
# BEFORE anything touches /run/dbus or /run/avahi-daemon.

# Any mount AT or BELOW /run/dbus or /var/run/dbus (a single bind-mounted system_bus_socket
# counts), from the kernel's own mount table. Prints the mount points (one per line) and returns 0
# if one exists; prints nothing otherwise.
cups_host_dbus_mounts() {
    local found=1 mp
    # Field 5 of mountinfo is the mount point, with space/tab/newline/backslash octal-escaped.
    while read -r _ _ _ _ mp _; do
        case "${mp}" in
            /run/dbus|/run/dbus/*|/var/run/dbus|/var/run/dbus/*)
                printf '%s\n' "${mp}"; found=0 ;;
        esac
    done < /proc/self/mountinfo
    return "${found}"
}

# A mount exactly AT /run or /var/run (Docker resolves the /var/run symlink, so both show up as
# /run) that is not a tmpfs: some directory from outside the container, which the D-Bus/Avahi
# pid-file cleanup would otherwise write into. A container normally has no mount there at all, and
# a read-only setup uses `--tmpfs /run`, which passes. Prints "mountpoint (fstype)" lines.
cups_foreign_run_mounts() {
    local found=1 i fstype
    local -a f
    while read -r -a f; do
        [[ "${f[4]:-}" == /run || "${f[4]:-}" == /var/run ]] || continue
        # The filesystem type is the first field after the lone "-" that ends the optional fields.
        fstype=""
        for (( i = 6; i < ${#f[@]}; i++ )); do
            if [[ "${f[i]}" == - ]]; then fstype="${f[i + 1]:-}"; break; fi
        done
        [[ "${fstype}" == tmpfs ]] && continue
        printf '%s (%s)\n' "${f[4]}" "${fstype:-unknown type}"
        found=0
    done < /proc/self/mountinfo
    return "${found}"
}

# The host's /run bind-mounted at /run (or /var/run) is itself a tmpfs, so the check above cannot
# tell it from `--tmpfs /run`. What gives it away is a LIVE bus: a socket at the system-bus or Avahi
# path that ACCEPTS a connection while our own daemon for it is not running belongs to someone else.
# init-cups-config runs before both of ours, so it checks both paths. svc-dbus passes "system-bus":
# s6 restarts it only after its previous dbus-daemon has exited, but our avahi-daemon may still be
# shutting down at that moment (it exits when the bus goes away, and s6 keeps retrying it while the
# bus is down), so only the system-bus socket is evidence there. s6-ipcclient connects and runs
# `true`, i.e. hangs up at once without saying anything. Prints the live socket paths.
cups_live_foreign_sockets() {   # cups_live_foreign_sockets [system-bus]
    local found=1 sock
    local -a socks=(/run/dbus/system_bus_socket)
    [[ "${1:-}" == system-bus ]] || socks+=(/run/avahi-daemon/socket)
    # /var/run is normally a symlink to /run: then these are the same files, listed once.
    if [[ "$(readlink -f /var/run)" != /run ]]; then
        socks+=(/var/run/dbus/system_bus_socket)
        [[ "${1:-}" == system-bus ]] || socks+=(/var/run/avahi-daemon/socket)
    fi
    for sock in "${socks[@]}"; do
        [[ -S "${sock}" ]] || continue
        if timeout 5 s6-ipcclient "${sock}" true > /dev/null 2>&1; then
            printf '%s\n' "${sock}"
            found=0
        fi
    done
    return "${found}"
}
