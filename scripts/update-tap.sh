#!/bin/sh
# Writes Casks/thermo.rb for VERSION into the Homebrew tap (leeguooooo/homebrew-tap) and pushes it.
# Run after `make publish`, so the DMG it points at is already public.
#   scripts/update-tap.sh 1.1.25 [releases/Thermo-1.1.25.dmg]
set -eu
version="${1:?usage: scripts/update-tap.sh VERSION [DMG]}"
dmg="${2:-releases/Thermo-$version.dmg}"
[ -f "$dmg" ] || { echo "missing $dmg" >&2; exit 1; }
sha=$(shasum -a 256 "$dmg" | cut -d' ' -f1)
url="https://app.leeguoo.com/thermo/Thermo-$version.dmg"
# The cask must point at what users will download, byte for byte.
remote=$(curl -fsSL "$url" | shasum -a 256 | cut -d' ' -f1)
[ "$remote" = "$sha" ] || { echo "published DMG does not match $dmg ($remote vs $sha); publish first" >&2; exit 1; }

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
gh repo clone leeguooooo/homebrew-tap "$work/tap" -- --quiet
mkdir -p "$work/tap/Casks"
cat > "$work/tap/Casks/thermo.rb" <<CASK
cask "thermo" do
  version "$version"
  sha256 "$sha"

  url "https://app.leeguoo.com/thermo/Thermo-#{version}.dmg"
  name "Thermo"
  desc "Temperatures, fans, disk cleanup and AI agent diagnostics"
  homepage "https://app.leeguoo.com/thermo"

  livecheck do
    url "https://app.leeguoo.com/thermo/appcast.xml"
    strategy :sparkle, &:short_version
  end

  auto_updates true
  depends_on macos: :ventura

  app "Thermo.app"
  binary "#{appdir}/Thermo.app/Contents/Helpers/thermo"

  # Stopping the helper returns the fans to automatic control and restores the sleep setting.
  uninstall launchctl: "dev.thermo.helper",
            quit:      "dev.thermo.app",
            delete:    [
              "/Library/LaunchDaemons/dev.thermo.helper.plist",
              "/Library/PrivilegedHelperTools/dev.thermo.helper",
            ]

  zap trash: [
    "~/Library/Application Support/Thermo",
    "~/Library/Caches/dev.thermo",
    "~/Library/Logs/Thermo",
    "~/Library/Preferences/dev.thermo.app.plist",
  ]
end
CASK
cd "$work/tap"
git add Casks/thermo.rb
if git diff --cached --quiet; then echo "tap already at $version"; exit 0; fi
git commit -qm "thermo $version"
git push -q
echo "tap: thermo $version ($sha)"
