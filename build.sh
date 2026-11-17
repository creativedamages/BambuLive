#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
arch="$(uname -m)"
node="${NODE_BINARY:-$(command -v node)}"
license="${NODE_LICENSE:-$(dirname "$node")/../LICENSE}"
test -x "$node"
test -f "$license"
stage="$(mktemp -d)"
trap 'rm -rf "$stage"' EXIT
app="$stage/image/BambuLive.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" dist
iconset="$stage/AppIcon.iconset"
mkdir -p "$iconset"
for size in 16 32 128 256 512; do
    sips -z "$size" "$size" assets/AppIcon.png --out "$iconset/icon_${size}x${size}.png" >/dev/null
    double=$((size * 2))
    sips -z "$double" "$double" assets/AppIcon.png --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$iconset" -o "$app/Contents/Resources/AppIcon.icns"
cp Info.plist "$app/Contents/"
cp "$node" "$app/Contents/MacOS/node"
cp "$license" "$app/Contents/Resources/Node-LICENSE.txt"
swiftc -module-cache-path "${SWIFT_MODULE_CACHE:-$stage/modules}" -target "$arch-apple-macos13.5" -O Monitor.swift -o "$app/Contents/MacOS/BambuLive"
identity="${SIGN_IDENTITY:--}"
sign_flags=()
if [[ "$identity" != "-" ]]; then
    sign_flags=(--options runtime --timestamp)
fi
codesign --force --sign "$identity" ${sign_flags[@]+"${sign_flags[@]}"} --entitlements Node.entitlements "$app/Contents/MacOS/node"
codesign --force --sign "$identity" ${sign_flags[@]+"${sign_flags[@]}"} "$app"
codesign --verify --deep --strict "$app"
"$app/Contents/MacOS/node" --version
ln -s /Applications "$stage/image/Applications"
if [[ "${APP_ZIP:-0}" == 1 ]]; then
    ditto -c -k --keepParent "$app" "dist/BambuLive-$arch-app.zip"
fi
dmg="dist/BambuLive-$arch.dmg"
if ! hdiutil create -ov -srcfolder "$stage/image" -volname "BambuLive" -format UDZO "$dmg"; then
    hdiutil makehybrid -hfs -hfs-volume-name "BambuLive" -o "$stage/hybrid" "$stage/image"
    hdiutil convert "$stage/hybrid.dmg" -format UDZO -ov -o "$dmg"
fi
if [[ "$identity" != "-" ]]; then
    codesign --force --sign "$identity" --timestamp "$dmg"
fi
if [[ -n "${NOTARY_PROFILE:-}" ]]; then
    [[ "$identity" != "-" ]]
    xcrun notarytool submit "$dmg" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$dmg"
fi
hdiutil verify "$dmg"
