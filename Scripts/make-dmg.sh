#!/usr/bin/env bash
# Build a simple ClingBar.dmg from the Release app product.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

APP_NAME="ClingBar"
DERIVED="${DERIVED:-build}"
CONFIG="${CONFIG:-Release}"
APP_PATH="${DERIVED}/Build/Products/${CONFIG}/${APP_NAME}.app"
DIST_DIR="${DIST_DIR:-dist}"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${APP_PATH}/Contents/Info.plist" 2>/dev/null || echo "0.0.0")"
DMG_NAME="${APP_NAME}-${VERSION}.dmg"
STAGE="${DIST_DIR}/dmg-stage"
DMG_PATH="${DIST_DIR}/${DMG_NAME}"
VOL_NAME="${APP_NAME}"

if [[ ! -d "${APP_PATH}" ]]; then
  echo "error: missing ${APP_PATH}" >&2
  echo "Run: make release" >&2
  exit 1
fi

rm -rf "${STAGE}"
mkdir -p "${STAGE}" "${DIST_DIR}"

# Fresh copy of the app + Applications symlink for drag-install UX.
ditto "${APP_PATH}" "${STAGE}/${APP_NAME}.app"
ln -s /Applications "${STAGE}/Applications"

# Remove any previous DMG with this name.
rm -f "${DMG_PATH}"

# UDZO = compressed read-only disk image.
hdiutil create \
  -volname "${VOL_NAME}" \
  -srcfolder "${STAGE}" \
  -ov \
  -format UDZO \
  "${DMG_PATH}"

rm -rf "${STAGE}"

echo "Created ${DMG_PATH}"
ls -lh "${DMG_PATH}"
