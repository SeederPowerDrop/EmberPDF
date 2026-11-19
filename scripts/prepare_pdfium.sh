#!/bin/zsh
# Rebuild the checked-in macOS framework from pinned, checksum-verified binaries.
# Normal application builds use Vendor/PDFium and do not access the network.
set -euo pipefail
SCRIPT_DIRECTORY="${0:A:h}"
PROJECT_DIRECTORY="${SCRIPT_DIRECTORY:h}"
VENDOR_DIRECTORY="${PROJECT_DIRECTORY}/Vendor/PDFium"
STAGING_DIRECTORY="$(mktemp -d "${TMPDIR:-/tmp}/ember-pdfium.XXXXXX")"
trap 'rm -rf "${STAGING_DIRECTORY}"' EXIT
PDFIUM_BUILD=8086
PDFIUM_ARM64_SHA=e98679e052c07edbb5a627980902abb823d4b3f35744d877bd21668bd9fc13ab
PDFIUM_X64_SHA=933a85a138f6027243c56bff8676375c33ceeb767401389415ffc44d689ca85d

for architecture in arm64 x64; do
    archive="${STAGING_DIRECTORY}/pdfium-${architecture}.tgz"
    curl --fail --location --silent --show-error \
        "https://github.com/bblanchon/pdfium-binaries/releases/download/chromium/${PDFIUM_BUILD}/pdfium-mac-${architecture}.tgz" \
        --output "${archive}"
    expected_checksum="${PDFIUM_ARM64_SHA}"
    [[ "${architecture}" == x64 ]] && expected_checksum="${PDFIUM_X64_SHA}"
    actual_checksum="$(shasum -a 256 "${archive}" | cut -d ' ' -f 1)"
    [[ "${actual_checksum}" == "${expected_checksum}" ]] \
        || { echo "PDFium ${architecture} checksum mismatch" >&2; exit 1; }
    mkdir -p "${STAGING_DIRECTORY}/${architecture}"
    tar -xzf "${archive}" -C "${STAGING_DIRECTORY}/${architecture}"
done

FRAMEWORK="${STAGING_DIRECTORY}/CPDFium.framework"
mkdir -p "${FRAMEWORK}/Headers" "${FRAMEWORK}/Modules"
cp "${STAGING_DIRECTORY}/arm64/include/"*.h "${FRAMEWORK}/Headers/"
lipo -create "${STAGING_DIRECTORY}/arm64/lib/libpdfium.dylib" \
    "${STAGING_DIRECTORY}/x64/lib/libpdfium.dylib" -output "${FRAMEWORK}/CPDFium"
install_name_tool -id @rpath/CPDFium.framework/CPDFium "${FRAMEWORK}/CPDFium"
python3 - "${FRAMEWORK}" <<'PY'
import plistlib
import sys
from pathlib import Path
p = Path(sys.argv[1])
headers = ['fpdfview.h'] + sorted(h.name for h in (p/'Headers').glob('*.h') if h.name != 'fpdfview.h')
(p/'Headers/CPDFium.h').write_text(''.join('#include "'+h+'"\n' for h in headers))
(p/'Modules/module.modulemap').write_text('framework module CPDFium {\n  umbrella header "CPDFium.h"\n  export *\n  module * { export * }\n}\n')
with (p/'Info.plist').open('wb') as f:
    plistlib.dump({'CFBundleIdentifier':'org.emberpdf.CPDFium', 'CFBundleName':'CPDFium',
                  'CFBundleExecutable':'CPDFium', 'CFBundlePackageType':'FMWK',
                  'CFBundleShortVersionString':'157.0.8086', 'CFBundleVersion':'8086',
                  'CFBundleSupportedPlatforms':['MacOSX'], 'MinimumOSVersion':'14.0'}, f)
PY
codesign --force --sign - "${FRAMEWORK}"
xcodebuild -create-xcframework -framework "${FRAMEWORK}" \
    -output "${STAGING_DIRECTORY}/CPDFium.xcframework"
codesign --verify --strict "${STAGING_DIRECTORY}/CPDFium.xcframework/macos-arm64_x86_64/CPDFium.framework"
mkdir -p "${VENDOR_DIRECTORY}"
# Replace only after both downloads, verification and framework creation pass.
rm -rf "${VENDOR_DIRECTORY}/CPDFium.xcframework"
mv "${STAGING_DIRECTORY}/CPDFium.xcframework" "${VENDOR_DIRECTORY}/CPDFium.xcframework"
cp "${STAGING_DIRECTORY}/arm64/LICENSE" "${STAGING_DIRECTORY}/arm64/VERSION" \
    "${STAGING_DIRECTORY}/arm64/args.gn" "${VENDOR_DIRECTORY}/"
cp -R "${STAGING_DIRECTORY}/arm64/licenses" "${VENDOR_DIRECTORY}/"
echo "Prepared PDFium 157.0.${PDFIUM_BUILD}.0 for arm64 and x86_64."
