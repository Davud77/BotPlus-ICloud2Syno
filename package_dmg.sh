#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

appPath=${1:?Usage: ./package_dmg.sh /path/to/SynologyPhotoSync.app}
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$appPath/Contents/Info.plist")
identifier=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$appPath/Contents/Info.plist")
if [[ "$identifier" != "com.synologyphotosync.app" || ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "Unexpected application bundle or version" >&2
    exit 1
fi
/usr/bin/codesign --verify --deep --strict "$appPath"

stageRoot=$(mktemp -d "${TMPDIR:-/tmp}/SynologyPhotoSync-dmg.XXXXXX")
trap 'rm -rf "$stageRoot"' EXIT
mkdir -p "$stageRoot/volume" build_output
/usr/bin/ditto --noextattr --norsrc "$appPath" "$stageRoot/volume/SynologyPhotoSync.app"
ln -s /Applications "$stageRoot/volume/Applications"
cat > "$stageRoot/volume/Установка.txt" <<'TXT'
SynologyPhotoSync — Apple Silicon, macOS 13 или новее

Перетащите SynologyPhotoSync в Applications и запустите приложение.
Затем откройте настройки из строки меню и подключите ваш Synology NAS.

Сборка имеет локальную ad-hoc подпись. Apple notarization не выполнялась.
Исходники: https://github.com/Davud77/BotPlus-ICloud2Syno
TXT
/usr/bin/codesign --verify --deep --strict "$stageRoot/volume/SynologyPhotoSync.app"
name="SynologyPhotoSync-$version-arm64.dmg"
/usr/bin/hdiutil create -ov -volname SynologyPhotoSync -fs HFS+ -format UDZO \
    -srcfolder "$stageRoot/volume" "$stageRoot/$name"
/usr/bin/hdiutil verify "$stageRoot/$name"
cp "$stageRoot/$name" "build_output/$name"
(cd build_output && /usr/bin/shasum -a 256 "$name" > "$name.sha256")
echo "DMG: $(pwd)/build_output/$name"
