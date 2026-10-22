#!/bin/sh
# Installs the signed universal CLI and helper from the public release mirror.
set -eu
[ "$(uname -s)" = Darwin ] || { echo 'Thermo requires macOS 13 or newer.' >&2; exit 1; }
THERMO_ASSET_BASE="${THERMO_RELEASE_BASE_URL:-https://thermo-updates.pages.dev}"
thermo_install_dir="${THERMO_INSTALL_DIR:-$HOME/.local/bin}"
thermo_stage="$(mktemp -d)"
thermo_new_file=
trap 'if [ -n "$thermo_new_file" ]; then rm -f "$thermo_new_file"; fi; rm -rf "$thermo_stage"' EXIT HUP INT TERM
thermo_archive=thermo-cli-macos-universal.tar.gz
curl -fLSs "$THERMO_ASSET_BASE/$thermo_archive" -o "$thermo_stage/$thermo_archive"
curl -fLSs "$THERMO_ASSET_BASE/$thermo_archive.sha256" -o "$thermo_stage/$thermo_archive.sha256"
(cd "$thermo_stage" && shasum -a 256 -c "$thermo_archive.sha256")
# Validate names and entry types before extraction; license directories must not be links.
tar -tzf "$thermo_stage/$thermo_archive" | awk '
    $0 == "thermo" || $0 == "thermo-helper" || $0 == "ThirdPartyNotices/" ||
    $0 ~ /^ThirdPartyNotices\/[A-Za-z0-9][A-Za-z0-9._-]*\.txt$/ {
        if (seen[$0]++) bad = 1
        next
    }
    { bad = 1 }
    END { exit bad }'
tar -tvzf "$thermo_stage/$thermo_archive" | awk '
    substr($1, 1, 1) != "-" && substr($1, 1, 1) != "d" { bad = 1 }
    / -> | link to / { bad = 1 }
    END { exit bad }'
tar -xzf "$thermo_stage/$thermo_archive" -C "$thermo_stage"
for thermo_binary in thermo thermo-helper; do
    [ -f "$thermo_stage/$thermo_binary" ] && [ ! -L "$thermo_stage/$thermo_binary" ]
    codesign --verify --strict "$thermo_stage/$thermo_binary"
    codesign -dv "$thermo_stage/$thermo_binary" 2>&1 | awk '$0 == "TeamIdentifier=6ZPXG4KVVS" { trusted = 1 } END { exit !trusted }'
done
mkdir -p "$thermo_install_dir"
# Rename replaces an existing symlink rather than writing into its target in Thermo.app.
thermo_install_file() {
    thermo_new_file="$(mktemp "${2%/*}/.thermo-install-XXXXXX")"
    cp "$1" "$thermo_new_file"
    chmod "$3" "$thermo_new_file"
    mv -f "$thermo_new_file" "$2"
    thermo_new_file=
}
thermo_notices="$thermo_install_dir/thermo-notices"
if [ -d "$thermo_stage/ThirdPartyNotices" ]; then
    if [ -L "$thermo_notices" ] || { [ -e "$thermo_notices" ] && [ ! -d "$thermo_notices" ]; }; then
        echo 'Refusing an unsafe thermo-notices destination.' >&2
        exit 1
    fi
    mkdir -p "$thermo_notices"
    for thermo_notice in "$thermo_stage/ThirdPartyNotices/"*.txt; do
        [ -f "$thermo_notice" ] || continue
        thermo_install_file "$thermo_notice" "$thermo_notices/${thermo_notice##*/}" 644
    done
fi
for thermo_binary in thermo thermo-helper; do
    thermo_install_file "$thermo_stage/$thermo_binary" "$thermo_install_dir/$thermo_binary" 755
done
ln -sfn thermo "$thermo_install_dir/thermo-use"
"$thermo_install_dir/thermo" --version
printf 'Installed to %s. Add this directory to PATH if needed.\n' "$thermo_install_dir"
echo 'The privileged fan helper is not installed or restarted automatically.'
