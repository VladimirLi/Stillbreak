#!/bin/sh
# Checks that the install command recommended in README.md reports failure
# when the download is missing, empty or cut short, runs when it is whole, and
# never overwrites or leaves behind files in the current folder or the temp dir.
# Uses file:// URLs, so it needs no network and installs nothing.
set -u
root=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/stillbreak-entrypoint.XXXXXX")
trap 'rm -rf "$work"' EXIT

template=$(grep -m1 '^(f=\$(mktemp) && .* sh "\$f")$' "$root/README.md")
[ -n "$template" ] || { echo "FAIL: recommended command not found in README.md" >&2; exit 1; }
url_in_readme='https://raw.githubusercontent.com/VladimirLi/Stillbreak/main/install.sh'
case $template in *"$url_in_readme"*) ;; *) echo "FAIL: README command does not use $url_in_readme" >&2; exit 1 ;; esac
if grep -nE 'curl .*(-o install\.sh|-[a-zA-Z]*O[a-zA-Z]* )' "$root/README.md" "$root/docs/index.html" "$root/install.sh"; then
    echo "FAIL: a documented command still downloads into ./install.sh" >&2; exit 1
fi

failures=0
run_case() { # name, source file, expected status (zero|nonzero)
    name=$1 src=$2 want=$3
    dir="$work/$name"; tmp="$dir/tmp"; mkdir -p "$tmp"
    printf 'precious\n' >"$dir/install.sh"
    cmd=$(printf '%s' "$template" | sed "s|$url_in_readme|file://$src|")
    cmd="${cmd%)} --help)"
    (cd "$dir" && HOME="$dir" TMPDIR="$tmp" sh -c "$cmd" >"$dir/out" 2>&1)
    status=$?
    problems=
    if [ "$want" = zero ]; then [ "$status" -eq 0 ] || problems="exit $status, wanted zero"
    else [ "$status" -ne 0 ] || problems="exit $status, wanted nonzero"; fi
    [ "$(cat "$dir/install.sh")" = precious ] || problems="$problems; existing install.sh was changed"
    [ -z "$(ls -A "$tmp")" ] || problems="$problems; temp files left behind: $(ls -A "$tmp")"
    if [ -z "$problems" ]; then
        echo "ok   $name (exit $status)"
    else
        echo "FAIL $name: $problems" >&2; sed 's/^/     /' "$dir/out" >&2
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
