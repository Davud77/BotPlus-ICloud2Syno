#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
sparkleBin=${1:?Usage: ./make_appcast.sh /path/to/Sparkle/bin}
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)
archive="SynologyPhotoSync-$version-arm64.zip"
if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ || ! -f "build_output/$archive" ]]; then
    echo "Build the release archive before generating the appcast" >&2
    exit 1
fi
stageRoot=$(mktemp -d "${TMPDIR:-/tmp}/SynologyPhotoSync-appcast.XXXXXX")
trap 'rm -rf "$stageRoot"' EXIT
cp "build_output/$archive" "$stageRoot/$archive"
if [[ -f appcast.xml ]]; then cp appcast.xml "$stageRoot/appcast.xml"; fi
"$sparkleBin/generate_appcast" --account com.synologyphotosync.app \
    --maximum-deltas 0 \
    --download-url-prefix "https://github.com/Davud77/BotPlus-ICloud2Syno/releases/download/v$version/" \
    --link https://github.com/Davud77/BotPlus-ICloud2Syno \
    "$stageRoot"
"$sparkleBin/sign_update" --account com.synologyphotosync.app --verify "$stageRoot/appcast.xml"
cp "$stageRoot/appcast.xml" appcast.xml
echo "Signed feed: $(pwd)/appcast.xml"
