#!/usr/bin/env bash
# Static checks run by ci.yml before anything is built:
#
#   1. ShellCheck over every shell script the image or CI runs - root/ (s6 run/finish scripts, the
#      helpers in /usr/local/bin, the shared library) and .github/scripts/ - plus the Dockerfile's
#      heredoc RUN blocks, which run as root at build time and are shell like any other.
#   2. Well-formedness of the Unraid template (and the CA profile, when present). A template that does
#      not parse is not shown by Community Applications at all, and nothing else would notice.
#
# Invoked as `bash .github/scripts/lint.sh` from anywhere in the checkout. Uses $SHELLCHECK
# (default `shellcheck` on PATH). ci.yml installs a pinned, checksum-verified ShellCheck release and
# points this at it: the version preinstalled on the runner image moves whenever GitHub updates the
# image, and a new release's new checks would otherwise turn an unrelated PR red overnight.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.."

SHELLCHECK="${SHELLCHECK:-shellcheck}"
fail=0

echo "== ShellCheck ($("$SHELLCHECK" --version | sed -n 's/^version: //p')) =="

# Found by their FIRST LINE, not by name: s6 `run`/`finish` files have no extension, and the shared
# library has no shebang at all, only a `# shellcheck shell=bash` directive. `with-contenv bash`
# shebangs are not recognised by ShellCheck either, which is why those scripts carry the same
# directive. execline files (s6 `up`, `#!/command/execlineb`) are not shell and are skipped.
scripts=()
while IFS= read -r -d '' f; do
    first="$(head -n1 -- "$f")"
    if [[ "$first" =~ ^\#!.*[/[:space:]](ba|da)?sh([[:space:]].*)?$ ]] \
       || [[ "$first" =~ ^\#[[:space:]]*shellcheck[[:space:]]+shell= ]]; then
        scripts+=("$f")
    fi
done < <(find root .github/scripts -type f -print0 | LC_ALL=C sort -z)

# An empty list would "pass" by checking nothing - the failure mode a lint step must not have.
if [ "${#scripts[@]}" -eq 0 ]; then
    echo "::error::no shell scripts found under root/ or .github/scripts - the discovery above is broken"
    exit 1
fi
printf '  %s\n' "${scripts[@]}"

# -x follows `source` directives (the s6 scripts source /usr/local/lib/docker-cups/common.sh and say
# where it lives in the repo with `# shellcheck source=`).
if ! "$SHELLCHECK" -x "${scripts[@]}"; then
    echo "::error::ShellCheck found problems in the scripts above"
    fail=1
fi

# The Dockerfile's heredoc RUN blocks (`RUN <<'EOF'` ... `EOF`). Each block is written out padded
# with blank lines, so the line numbers ShellCheck reports ARE Dockerfile line numbers. BuildKit runs
# a heredoc with the default SHELL, /bin/sh (dash on Ubuntu), hence --shell=sh.
blocks_dir="$(mktemp -d)"
trap 'rm -rf "$blocks_dir"' EXIT
lineno=0
inblock=0
nblocks=0
delim=""
out=""
heredoc_start="^RUN[[:space:]]+<<-?['\"]?([A-Za-z_][A-Za-z0-9_]*)['\"]?[[:space:]]*\$"
while IFS= read -r line || [ -n "$line" ]; do
    lineno=$((lineno + 1))
    if [ "$inblock" = 0 ]; then
        if [[ "$line" =~ $heredoc_start ]]; then
            delim="${BASH_REMATCH[1]}"
            inblock=1
            nblocks=$((nblocks + 1))
            out="$(printf '%s/block-%02d.sh' "$blocks_dir" "$nblocks")"
            # $lineno blank lines, so the block's first line lands on its Dockerfile line number.
            printf '\n%.0s' $(seq 1 "$lineno") > "$out"
        fi
    elif [ "$line" = "$delim" ]; then
        inblock=0
    else
        printf '%s\n' "$line" >> "$out"
    fi
done < Dockerfile
mapfile -t blocks < <(find "$blocks_dir" -name 'block-*.sh' | LC_ALL=C sort)
if [ "${#blocks[@]}" -eq 0 ]; then
    echo "::error::no heredoc RUN block found in the Dockerfile - the extraction above is broken"
    fail=1
fi
for b in ${blocks[@]+"${blocks[@]}"}; do
    echo "  Dockerfile RUN heredoc ($(basename "$b" .sh); line numbers are Dockerfile lines)"
    if ! "$SHELLCHECK" --shell=sh "$b"; then
        echo "::error::ShellCheck found problems in a Dockerfile RUN heredoc (line numbers above are Dockerfile lines)"
        fail=1
    fi
done

echo "== XML well-formedness =="
xml=(templates/cups.xml)
[ ! -e ca_profile.xml ] || xml+=(ca_profile.xml)
# -I: isolated mode, so nothing in the checkout can shadow the standard library modules imported here.
if ! python3 -I - "${xml[@]}" <<'PY'
import sys
import xml.etree.ElementTree as ET

bad = 0
for path in sys.argv[1:]:
    try:
        ET.parse(path)
        print(f"  PASS  {path}")
    except (ET.ParseError, OSError) as exc:
        print(f"::error file={path}::{path} is not well-formed XML: {exc}")
        bad = 1
sys.exit(bad)
PY
then
    fail=1
fi

if [ "$fail" != 0 ]; then
    echo "::error::lint failed"
    exit 1
fi
echo "lint passed"
