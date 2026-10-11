#!/bin/sh
# Installs the signed universal CLI and helper from GitHub Releases.
set -eu
[ "$(uname -s)" = Darwin ] || { echo 'Thermo requires macOS 13 or newer.' >&2; exit 1; }
THERMO_ASSET_BASE="${THERMO_RELEASE_BASE_URL:-https://github.com/leeguooooo/thermo/releases/latest/download}"
thermo_install_dir="${THERMO_INSTALL_DIR:-$HOME/.local/bin}"
thermo_stage="$(mktemp -d)"
trap 'rm -rf "$thermo_stage"' EXIT HUP INT TERM
thermo_archive=thermo-cli-macos-universal.tar.gz
curl -fLSs "$THERMO_ASSET_BASE/$thermo_archive" -o "$thermo_stage/$thermo_archive"
curl -fLSs "$THERMO_ASSET_BASE/$thermo_archive.sha256" -o "$thermo_stage/$thermo_archive.sha256"
(cd "$thermo_stage" && shasum -a 256 -c "$thermo_archive.sha256")
tar -tzf "$thermo_stage/$thermo_archive" | awk '$0 != "thermo" && $0 != "thermo-helper" { bad = 1 } END { exit bad }'
tar -xzf "$thermo_stage/$thermo_archive" -C "$thermo_stage"
for thermo_binary in thermo thermo-helper; do
    [ -f "$thermo_stage/$thermo_binary" ] && [ ! -L "$thermo_stage/$thermo_binary" ]
    codesign --verify --strict "$thermo_stage/$thermo_binary"
    codesign -dv "$thermo_stage/$thermo_binary" 2>&1 | awk '$0 == "TeamIdentifier=6ZPXG4KVVS" { trusted = 1 } END { exit !trusted }'
done
mkdir -p "$thermo_install_dir"
# Rename replaces an existing symlink rather than writing into its target in Thermo.app.
for thermo_binary in thermo thermo-helper; do
    cp "$thermo_stage/$thermo_binary" "$thermo_install_dir/.$thermo_binary.new"
    chmod 755 "$thermo_install_dir/.$thermo_binary.new"
    mv -f "$thermo_install_dir/.$thermo_binary.new" "$thermo_install_dir/$thermo_binary"
done
ln -sfn thermo "$thermo_install_dir/thermo-use"
"$thermo_install_dir/thermo" --version
printf 'Installed to %s. Add this directory to PATH if needed.\n' "$thermo_install_dir"
echo 'The privileged fan helper is not installed or restarted automatically.'
