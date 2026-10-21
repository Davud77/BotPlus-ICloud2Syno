#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
python3 generate_project.py

# Documents may be managed by iCloud, which attaches attributes forbidden by codesign.
# Build and sign outside File Provider storage; keep the portable ZIP in the project.
buildRoot=$(mktemp -d "${TMPDIR:-/tmp}/SynologyPhotoSync.XXXXXX")
xcodebuild -project SynologyPhotoSync.xcodeproj \
           -scheme SynologyPhotoSync \
           -configuration Release \
           -derivedDataPath "$buildRoot" \
           build "$@"

appPath="$buildRoot/Build/Products/Release/SynologyPhotoSync.app"
/usr/bin/codesign --verify --deep --strict "$appPath"
mkdir -p build_output
/usr/bin/ditto -c -k --keepParent "$appPath" build_output/SynologyPhotoSync.zip
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$appPath/Contents/Info.plist")
cp build_output/SynologyPhotoSync.zip "build_output/SynologyPhotoSync-$version-arm64.zip"
echo "Приложение: $appPath"
echo "Архив: $(pwd)/build_output/SynologyPhotoSync.zip"

./package_dmg.sh "$appPath"
