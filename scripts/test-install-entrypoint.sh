#!/bin/sh
# Checks that the install command recommended in README.md reports failure
# when the download is missing, empty or cut short, and runs when it is whole.
# Uses file:// URLs, so it needs no network and installs nothing.
set -u
root=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/stillbreak-entrypoint.XXXXXX")
trap 'rm -rf "$work"' EXIT

template=$(grep -m1 '^curl -fsSL .* -o install.sh && ' "$root/README.md")
[ -n "$template" ] || { echo "FAIL: recommended command not found in README.md" >&2; exit 1; }
url_in_readme='https://raw.githubusercontent.com/VladimirLi/Stillbreak/main/install.sh'
case $template in *"$url_in_readme"*) ;; *) echo "FAIL: README command does not use $url_in_readme" >&2; exit 1 ;; esac

failures=0
run_case() { # name, source file, expected status (zero|nonzero)
    name=$1 src=$2 want=$3
    dir="$work/$name"; mkdir "$dir"
    cmd=$(printf '%s' "$template" | sed "s|$url_in_readme|file://$src|")
    (cd "$dir" && HOME="$dir" sh -c "$cmd --help" >"$dir/out" 2>&1)
    status=$?
    if { [ "$want" = zero ] && [ "$status" -eq 0 ]; } || { [ "$want" = nonzero ] && [ "$status" -ne 0 ]; }; then
        echo "ok   $name (exit $status)"
    else
        echo "FAIL $name: exit $status, wanted $want" >&2; sed 's/^/     /' "$dir/out" >&2
        failures=$((failures + 1))
    fi
}

: >"$work/empty.sh"
sed '$d' "$root/install.sh" >"$work/no-last-line.sh"
head -c 2000 "$root/install.sh" >"$work/cut-mid-file.sh"
head -c "$(($(wc -c <"$root/install.sh") - 20))" "$root/install.sh" >"$work/cut-in-last-line.sh"

run_case complete "$root/install.sh" zero
run_case missing "$work/does-not-exist.sh" nonzero
run_case empty "$work/empty.sh" nonzero
run_case no-last-line "$work/no-last-line.sh" nonzero
run_case cut-mid-file "$work/cut-mid-file.sh" nonzero
run_case cut-in-last-line "$work/cut-in-last-line.sh" nonzero

[ "$failures" -eq 0 ] || exit 1
