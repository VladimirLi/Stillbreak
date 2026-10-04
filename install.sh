#!/bin/sh
# Stillbreak installer for macOS.
#
#   (f=$(mktemp) && trap 'rm -f "$f"' EXIT && curl -fsSL URL -o "$f" && grep -qx 'main "$@" --script-complete' "$f" && sh "$f")
#
# (URL is https://raw.githubusercontent.com/VladimirLi/Stillbreak/main/install.sh.)
# The grep fails on an empty or cut-off download, and the temporary file means
# an install.sh in the current folder is never overwritten. Do not pipe into
# sh: a pipe reports only sh's status, so a failed download looks like success.
#
# Everything runs from main(), called on the last line, so a truncated download
# defines functions at most and never executes half an install.
set -eu

APP_NAME=Stillbreak
REPO_URL=https://github.com/VladimirLi/Stillbreak
VERSION_RE='^v?[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?$'

TMP=
STAGE=
OLDDIR=
OLD=
TARGET=

say() { printf '==> %s\n' "$*"; }
note() { printf '    %s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

usage() {
    cat <<EOF
Install, build or remove $APP_NAME ($REPO_URL).

Usage: sh install.sh [options]

  (no options)      Install the latest release into /Applications
                    (or ~/Applications if /Applications is not writable).
  --version VER     Install release VER (for example v1.2.3) instead of the latest.
  --from-source     Clone the repository and build with Swift 6.3+ instead of
                    downloading a release. With --version, builds that tag.
  --dir DIR         Install into DIR instead of /Applications.
  --no-open         Do not launch the newly installed app. A running $APP_NAME
                    is still quit to be replaced, and it may save its data
                    folder while quitting.
  --uninstall       Remove $APP_NAME.app. Keeps your data unless --purge is given.
  --purge           With --uninstall, also delete
                    ~/Library/Application Support/$APP_NAME.
  -h, --help        Show this help.

Environment (for testing):
  STILLBREAK_BASE_URL    Directory, file:// or https:// URL holding the release
                         .zip and SHA256SUMS.txt, used instead of GitHub Releases.
  STILLBREAK_CLONE_URL   Repository to clone for --from-source.

No sudo, no telemetry. Only GitHub downloads (and git clone for --from-source)
touch the network; only a temporary directory and the install directory are
written to (--from-source also uses the Swift package manager's own caches).
EOF
}

cleanup() {
    # A second signal must not cut the restore short.
    trap '' INT HUP TERM
    keep_old=0
    if [ -n "$OLD" ]; then
        if [ -e "$OLD" ] || [ -L "$OLD" ]; then
            # The previous app is in the backup folder: put it back unless
            # something already occupies the target.
            if [ -n "$TARGET" ] && [ ! -e "$TARGET" ] && [ ! -L "$TARGET" ] \
                && mv "$OLD" "$TARGET" 2>/dev/null; then
                :
            else
                keep_old=1
                printf '%s\n' "ERROR: could not restore the previous $APP_NAME.app. It is still at: $OLD" >&2
            fi
        elif [ -z "$TARGET" ] || { [ ! -e "$TARGET" ] && [ ! -L "$TARGET" ]; }; then
            # Neither the backup nor the target exists, so the backup move may
            # have been cut short. Never delete the folder in that state.
            keep_old=1
            printf '%s\n' "ERROR: the previous $APP_NAME.app may be in: $OLDDIR" >&2
        fi
    fi
    [ "$keep_old" = 1 ] || [ -z "$OLDDIR" ] || rm -rf "$OLDDIR"
    [ -z "$STAGE" ] || rm -rf "$STAGE"
    [ -z "$TMP" ] || rm -rf "$TMP"
}

fetch() {
    curl --fail --location --silent --show-error \
        --proto '=https,file' --proto-redir '=https' \
        --connect-timeout 20 --retry 2 \
        --output "$2" "$1"
}

check_platform() {
    [ "$(uname -s)" = Darwin ] || die "$APP_NAME is a macOS app; this installer only runs on macOS."
    major=$(sw_vers -productVersion | cut -d. -f1)
    [ "$major" -ge 14 ] 2>/dev/null || die "$APP_NAME needs macOS 14 (Sonoma) or newer; this is macOS $(sw_vers -productVersion)."
    [ -n "${HOME:-}" ] || die "HOME is not set."
}

# Quits a running app politely (no kill); refuses to continue if it stays up.
quit_running_app() {
    pgrep -x "$APP_NAME" >/dev/null 2>&1 || return 0
    say "Quitting running $APP_NAME"
    osascript -e "tell application \"$APP_NAME\" to quit" >/dev/null 2>&1 || true
    i=0
    while pgrep -x "$APP_NAME" >/dev/null 2>&1; do
        i=$((i + 1))
        [ "$i" -le 20 ] || die "$APP_NAME is still running. Quit it from its menu bar item and run the installer again."
        sleep 0.5
    done
}

resolve_install_dir() {
    if [ -n "$1" ]; then
        mkdir -p "$1" || die "cannot create $1"
        INSTALL_DIR=$(CDPATH='' cd -- "$1" && pwd)
    elif [ -w /Applications ]; then
        INSTALL_DIR=/Applications
    else
        say "/Applications is not writable for this user; using ~/Applications"
        mkdir -p "$HOME/Applications"
        INSTALL_DIR=$HOME/Applications
    fi
    [ -w "$INSTALL_DIR" ] || die "$INSTALL_DIR is not writable. Choose another folder with --dir (this installer never uses sudo)."
    TARGET=$INSTALL_DIR/$APP_NAME.app
}

check_swift() {
    command -v git >/dev/null 2>&1 || die "git is required for --from-source."
    if ! xcode-select -p >/dev/null 2>&1 || ! command -v swift >/dev/null 2>&1; then
        die "Swift is required for --from-source. Install the Command Line Tools with: xcode-select --install"
    fi
    swift_ver=$(swift --version 2>&1 | sed -n 's/.*Swift version \([0-9][0-9]*\.[0-9][0-9]*\).*/\1/p' | head -n 1)
    [ -n "$swift_ver" ] || die "could not read the Swift version from 'swift --version'."
    swift_major=${swift_ver%.*}
    swift_minor=${swift_ver#*.}
    if [ "$swift_major" -lt 6 ] || { [ "$swift_major" -eq 6 ] && [ "$swift_minor" -lt 3 ]; }; then
        die "Swift $swift_ver found, but $APP_NAME needs Swift 6.3 or newer. Update Xcode or the Command Line Tools, or install a release instead (omit --from-source)."
    fi
    note "Swift $swift_ver"
}

# Normalizes STILLBREAK_BASE_URL (directory or URL, no trailing slash) to a URL.
base_url() {
    case $1 in
        file://* | https://*) url=$1 ;;
        *://*) die "STILLBREAK_BASE_URL must be a directory, file:// or https:// URL." ;;
        /*) url=file://$1 ;;
        *) url=file://$(pwd)/$1 ;;
    esac
    printf '%s\n' "${url%/}"
}

# Sets APP_SRC to the verified, unpacked app inside $TMP.
obtain_release() {
    version=$1
    if [ -n "${STILLBREAK_BASE_URL:-}" ]; then
        base=$(base_url "$STILLBREAK_BASE_URL")
        say "Using $base instead of GitHub Releases"
    else
        if [ -z "$version" ]; then
            say "Looking up the latest release"
            final=$(curl --fail --location --silent --show-error --head \
                --proto '=https' --proto-redir '=https' --connect-timeout 20 \
                --output /dev/null --write-out '%{url_effective}' "$REPO_URL/releases/latest") \
                || die "could not reach GitHub."
            case $final in
                */releases/tag/*) tag=${final##*/releases/tag/} ;;
                *) die "no published release found. Build it yourself with: sh install.sh --from-source" ;;
            esac
            printf '%s' "$tag" | grep -Eq "$VERSION_RE" || die "unexpected release tag \"$tag\"."
            version=$tag
        fi
        case $version in v*) ;; *) version=v$version ;; esac
        base=$REPO_URL/releases/download/$version
    fi

    say "Downloading SHA256SUMS.txt"
    fetch "$base/SHA256SUMS.txt" "$TMP/SHA256SUMS.txt" || die "could not download $base/SHA256SUMS.txt"

    if [ -z "$version" ]; then
        names=$(awk '{ n = $2; sub(/^\*/, "", n); if (n ~ /^Stillbreak-.*\.zip$/) print n }' "$TMP/SHA256SUMS.txt")
        [ -n "$names" ] && [ "$(printf '%s\n' "$names" | wc -l)" -eq 1 ] \
            || die "SHA256SUMS.txt must list exactly one $APP_NAME-<version>.zip; pass --version."
        zip_name=$names
    else
        zip_name=$APP_NAME-${version#v}.zip
    fi
    printf '%s' "$zip_name" | grep -Eq '^[A-Za-z0-9._-]+\.zip$' || die "unexpected file name \"$zip_name\"."

    say "Downloading $zip_name"
    fetch "$base/$zip_name" "$TMP/$zip_name" || die "could not download $base/$zip_name"

    say "Verifying SHA-256"
    expected=$(awk -v f="$zip_name" '{ n = $2; sub(/^\*/, "", n); if (n == f) print $1 }' "$TMP/SHA256SUMS.txt")
    [ -n "$expected" ] && [ "$(printf '%s\n' "$expected" | wc -l)" -eq 1 ] \
        || die "SHA256SUMS.txt has no single entry for $zip_name."
    printf '%s' "$expected" | grep -Eq '^[0-9a-fA-F]{64}$' || die "malformed checksum for $zip_name."
    actual=$(shasum -a 256 "$TMP/$zip_name" | awk '{ print $1 }')
    expected=$(printf '%s' "$expected" | tr 'A-F' 'a-f')
    if [ "$actual" != "$expected" ]; then
        die "checksum mismatch for $zip_name (expected $expected, got $actual). Nothing was installed."
    fi
    note "$actual"

    say "Unpacking"
    mkdir "$TMP/unpacked"
    ditto -x -k "$TMP/$zip_name" "$TMP/unpacked"
    APP_SRC=$TMP/unpacked/$APP_NAME.app
    [ -d "$APP_SRC" ] || die "$zip_name does not contain $APP_NAME.app."
}

obtain_source() {
    version=$1
    check_swift
    clone_url=${STILLBREAK_CLONE_URL:-$REPO_URL.git}
    if [ -n "$version" ]; then
        case $version in v*) ;; *) version=v$version ;; esac
    fi
    say "Cloning ${version:-the default branch} (shallow) from $clone_url"
    if [ -n "$version" ]; then
        git clone --quiet --depth 1 --branch "$version" "$clone_url" "$TMP/src"
        export VERSION="$version"
    else
        git clone --quiet --depth 1 "$clone_url" "$TMP/src"
    fi
    say "Building with scripts/package-app.sh (this takes a few minutes)"
    (cd "$TMP/src" && ./scripts/package-app.sh)
    APP_SRC=$TMP/src/.build/$APP_NAME.app
    [ -d "$APP_SRC" ] || die "build did not produce $APP_NAME.app."
}

install_app() {
    say "Checking the code signature"
    codesign --verify --deep --strict "$APP_SRC" || die "code signature check failed. Nothing was installed."

    quit_running_app

    say "Installing to $TARGET"
    # Fresh private directories (mode 700, unpredictable names) so a leftover or
    # planted path can never redirect the copy or the move.
    STAGE=$(mktemp -d "$INSTALL_DIR/.$APP_NAME.new.XXXXXX") || die "cannot create a staging folder in $INSTALL_DIR."
    OLDDIR=$(mktemp -d "$INSTALL_DIR/.$APP_NAME.old.XXXXXX") || die "cannot create a backup folder in $INSTALL_DIR."
    ditto "$APP_SRC" "$STAGE/$APP_NAME.app"
    if [ -e "$TARGET" ] || [ -L "$TARGET" ]; then
        note "Replacing the existing $APP_NAME.app"
        OLD=$OLDDIR/$APP_NAME.app
        mv "$TARGET" "$OLD"
    fi
    mv "$STAGE/$APP_NAME.app" "$TARGET" || die "could not move the new app into place."
    rm -rf "$OLDDIR" "$STAGE"
    OLD=
    OLDDIR=
    STAGE=

    say "Clearing any quarantine flag"
    xattr -dr com.apple.quarantine "$TARGET" 2>/dev/null \
        || note "Could not clear the quarantine flag; if macOS warns on first launch, follow the steps in the README or run: xattr -dr com.apple.quarantine \"$TARGET\""

    shown=$(plutil -extract CFBundleShortVersionString raw -o - "$TARGET/Contents/Info.plist" 2>/dev/null || echo unknown)
    note "Installed $APP_NAME $shown"

    for other in /Applications "$HOME/Applications"; do
        if [ "$other" != "$INSTALL_DIR" ] && [ -d "$other/$APP_NAME.app" ]; then
            note "Note: another copy exists at $other/$APP_NAME.app. Remove it to avoid starting the old one."
        fi
    done
}

uninstall_app() {
    dir_opt=$1
    purge=$2
    found=0
    quit_running_app
    if [ -n "$dir_opt" ]; then
        set -- "$dir_opt"
    else
        set -- /Applications "$HOME/Applications"
    fi
    for d in "$@"; do
        app=$d/$APP_NAME.app
        if [ -d "$app" ] || [ -L "$app" ]; then
            say "Removing $app"
            rm -rf "$app" || die "could not remove $app."
            found=1
        fi
    done
    [ "$found" -eq 1 ] || say "No $APP_NAME.app found${dir_opt:+ in $dir_opt}; nothing to remove."

    data="$HOME/Library/Application Support/$APP_NAME"
    if [ "$purge" -eq 1 ]; then
        if [ -d "$data" ]; then
            say "Deleting $data"
            rm -rf "$data"
        fi
    elif [ -d "$data" ]; then
        say "Left in place: $data (your history and settings; add --purge to delete it)"
    fi
    note "If Launch at login was on, check System Settings > General > Login Items & Extensions for a leftover entry."
}

main() {
    # The last argument is an end marker; a download cut inside the final line
    # lacks it, so it cannot run with silently dropped options.
    [ "$#" -ge 1 ] || die "this script looks truncated; download it again."
    for last in "$@"; do :; done
    [ "$last" = --script-complete ] || die "this script looks truncated; download it again."
    count=$(($# - 1))
    while [ "$count" -gt 0 ]; do
        set -- "$@" "$1"
        shift
        count=$((count - 1))
    done
    shift

    version=
    version_set=0
    dir_opt=
    dir_set=0
    from_source=0
    uninstall=0
    purge=0
    open_app=1
    while [ "$#" -gt 0 ]; do
        case $1 in
            --version)
                [ "$#" -ge 2 ] || die "--version needs a value."
                version=$2
                version_set=1
                shift 2
                ;;
            --version=*) version=${1#--version=}; version_set=1; shift ;;
            --dir)
                [ "$#" -ge 2 ] || die "--dir needs a value."
                dir_opt=$2
                dir_set=1
                shift 2
                ;;
            --dir=*) dir_opt=${1#--dir=}; dir_set=1; shift ;;
            --from-source) from_source=1; shift ;;
            --uninstall) uninstall=1; shift ;;
            --purge) purge=1; shift ;;
            --no-open) open_app=0; shift ;;
            -h | --help) usage; return 0 ;;
            *) usage >&2; die "unknown option: $1" ;;
        esac
    done
    if [ "$version_set" -eq 1 ]; then
        printf '%s' "$version" | grep -Eq "$VERSION_RE" || die "--version must look like v1.2.3 (got \"$version\")."
    fi
    if [ "$dir_set" -eq 1 ] && [ -z "$dir_opt" ]; then
        die "--dir needs a non-empty folder; refusing to fall back to the default location."
    fi
    if [ "$purge" -eq 1 ] && [ "$uninstall" -eq 0 ]; then die "--purge only works together with --uninstall."; fi
    if [ "$uninstall" -eq 1 ] && { [ "$from_source" -eq 1 ] || [ -n "$version" ]; }; then
        die "--uninstall cannot be combined with --from-source or --version."
    fi
    if [ -n "$dir_opt" ] && [ "$uninstall" -eq 1 ]; then
        [ -d "$dir_opt" ] || die "$dir_opt is not a directory."
    fi

    check_platform

    if [ "$uninstall" -eq 1 ]; then
        uninstall_app "$dir_opt" "$purge"
        say "Done."
        return 0
    fi

    resolve_install_dir "$dir_opt"

    TMP=$(mktemp -d "${TMPDIR:-/tmp}/stillbreak-install.XXXXXX")
    trap cleanup EXIT
    trap 'exit 130' INT
    trap 'exit 143' HUP TERM

    if [ "$from_source" -eq 1 ]; then
        obtain_source "$version"
    else
        obtain_release "$version"
    fi
    install_app

    if [ "$open_app" -eq 1 ]; then
        say "Opening $APP_NAME (it lives in the menu bar)"
        open "$TARGET" || note "Could not open it automatically; open $TARGET yourself."
    fi
    say "Done."
}

main "$@" --script-complete
