#!/bin/sh
set -eu

ICON_SOURCE_DIR="${SRCROOT}/SupraAI/Assets.xcassets/AppIcon.appiconset"
DESTINATION="${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}/AppIcon.icns"
ICONSET_DIR="${DERIVED_FILE_DIR}/SupraAI-AppIcon.iconset"

rm -rf "${ICONSET_DIR}"
mkdir -p "${ICONSET_DIR}"

copy_icon() {
  source_name="$1"
  destination_name="$2"

  cp "${ICON_SOURCE_DIR}/${source_name}" "${ICONSET_DIR}/${destination_name}"
}

copy_icon "icon_16.png" "icon_16x16.png"
copy_icon "icon_32.png" "icon_16x16@2x.png"
copy_icon "icon_32.png" "icon_32x32.png"
copy_icon "icon_64.png" "icon_32x32@2x.png"
copy_icon "icon_128.png" "icon_128x128.png"
copy_icon "icon_256.png" "icon_128x128@2x.png"
copy_icon "icon_256.png" "icon_256x256.png"
copy_icon "icon_512.png" "icon_256x256@2x.png"
copy_icon "icon_512.png" "icon_512x512.png"
copy_icon "icon_1024.png" "icon_512x512@2x.png"

/usr/bin/iconutil -c icns "${ICONSET_DIR}" -o "${DESTINATION}"
