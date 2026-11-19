#!/bin/zsh

set -euo pipefail

SCRIPT_DIRECTORY="${0:A:h}"
PROJECT_DIRECTORY="${SCRIPT_DIRECTORY:h}"
BUILD_DIRECTORY="${EMBER_BUILD_DIRECTORY:-${PROJECT_DIRECTORY}/.build}"
OUTPUT_DIRECTORY="${EMBER_OUTPUT_DIRECTORY:-${HWATTAK_OUTPUT_DIRECTORY:-${PROJECT_DIRECTORY}/outputs}}"
APP_NAME="EmberPDF"
BUILD_EXECUTABLE_NAME="EmberPDF"
WORKER_EXECUTABLE_NAME="EmberPluginWorker"
BUNDLE_EXECUTABLE_NAME="EmberPDF"
APP_BUNDLE="${OUTPUT_DIRECTORY}/${APP_NAME}.app"
PACKAGE_TEMPORARY="${PROJECT_DIRECTORY}/work/package-${APP_NAME}.app"
MODULE_CACHE="${PROJECT_DIRECTORY}/work/module-cache"
SWIFTPM_CACHE="${PROJECT_DIRECTORY}/work/swiftpm-cache"
INFO_PLIST="${PROJECT_DIRECTORY}/Resources/Info.plist"
LOCALIZATION_DIRECTORY="${PROJECT_DIRECTORY}/Resources/Localization"
EXPECTED_LOCALIZATIONS=(ko en ja zh-Hans vi es fr de ru ar)
EXPECTED_ENTITLEMENTS=(
    com.apple.security.app-sandbox
    com.apple.security.files.bookmarks.app-scope
    com.apple.security.files.user-selected.read-write
    com.apple.security.network.client
)
TARGET_ARCHITECTURE="arm64"

mkdir -p "${MODULE_CACHE}" "${SWIFTPM_CACHE}" "${OUTPUT_DIRECTORY}" "${PROJECT_DIRECTORY}/work"

plutil -lint "${INFO_PLIST}"
SHORT_VERSION="$(plutil -extract CFBundleShortVersionString raw -o - "${INFO_PLIST}")"
BUILD_VERSION="$(plutil -extract CFBundleVersion raw -o - "${INFO_PLIST}")"
ARCHIVE_NAME="${APP_NAME}-${SHORT_VERSION}-macOS-${TARGET_ARCHITECTURE}.zip"
ARCHIVE_PATH="${OUTPUT_DIRECTORY}/${ARCHIVE_NAME}"
ARCHIVE_CHECKSUM_PATH="${ARCHIVE_PATH}.sha256"
ARCHIVE_TEMPORARY="${PROJECT_DIRECTORY}/work/${ARCHIVE_NAME}.tmp"
INSTALL_GUIDE="${PROJECT_DIRECTORY}/Documentation/INSTALL-macOS.txt"
RELEASE_NOTES_NAME="RELEASE-NOTES-${SHORT_VERSION}.md"
RELEASE_NOTES="${PROJECT_DIRECTORY}/Documentation/${RELEASE_NOTES_NAME}"

for release_document in "${INSTALL_GUIDE}" "${RELEASE_NOTES}"; do
    if [[ ! -f "${release_document}" ]]; then
        echo "Missing release document: ${release_document}" >&2
        exit 1
    fi
done

# A failed build must not leave a previous archive looking like fresh output.
rm -f "${ARCHIVE_PATH}" "${ARCHIVE_CHECKSUM_PATH}" "${ARCHIVE_TEMPORARY}"

VERIFICATION_DIRECTORY=""
DISTRIBUTION_DIRECTORY=""

cleanup() {
    if [[ -e "${PACKAGE_TEMPORARY}" ]]; then
        rm -rf "${PACKAGE_TEMPORARY}"
    fi
    if [[ -e "${ARCHIVE_TEMPORARY}" ]]; then
        rm -f "${ARCHIVE_TEMPORARY}"
    fi
    if [[ -n "${VERIFICATION_DIRECTORY}" && -e "${VERIFICATION_DIRECTORY}" ]]; then
        rm -rf "${VERIFICATION_DIRECTORY}"
    fi
    if [[ -n "${DISTRIBUTION_DIRECTORY}" && -e "${DISTRIBUTION_DIRECTORY}" ]]; then
        rm -rf "${DISTRIBUTION_DIRECTORY}"
    fi
}
trap cleanup EXIT

VERIFICATION_DIRECTORY="$(mktemp -d "${PROJECT_DIRECTORY}/work/verify-${APP_NAME}.XXXXXX")"
DISTRIBUTION_DIRECTORY="$(mktemp -d "${PROJECT_DIRECTORY}/work/distribute-${APP_NAME}.XXXXXX")"

for product_name in "${BUILD_EXECUTABLE_NAME}" "${WORKER_EXECUTABLE_NAME}"; do
env \
    CLANG_MODULE_CACHE_PATH="${MODULE_CACHE}" \
    SWIFTPM_MODULECACHE_OVERRIDE="${MODULE_CACHE}" \
    XDG_CACHE_HOME="${SWIFTPM_CACHE}" \
    swift build \
        --package-path "${PROJECT_DIRECTORY}" \
        --scratch-path "${BUILD_DIRECTORY}" \
        --jobs "${EMBER_BUILD_JOBS:-2}" \
        --product "${product_name}" \
        --configuration release \
        --disable-sandbox \
        -Xswiftc -file-prefix-map \
        -Xswiftc "${PROJECT_DIRECTORY}=." \
        -Xswiftc -debug-prefix-map \
        -Xswiftc "${PROJECT_DIRECTORY}=."
done

if [[ -e "${PACKAGE_TEMPORARY}" ]]; then
    rm -rf "${PACKAGE_TEMPORARY}"
fi

mkdir -p "${PACKAGE_TEMPORARY}/Contents/MacOS" "${PACKAGE_TEMPORARY}/Contents/Resources" "${PACKAGE_TEMPORARY}/Contents/Helpers"
cp "${INFO_PLIST}" "${PACKAGE_TEMPORARY}/Contents/Info.plist"
cp "${BUILD_DIRECTORY}/release/${BUILD_EXECUTABLE_NAME}" "${PACKAGE_TEMPORARY}/Contents/MacOS/${BUNDLE_EXECUTABLE_NAME}"
chmod 755 "${PACKAGE_TEMPORARY}/Contents/MacOS/${BUNDLE_EXECUTABLE_NAME}"
strip -S -x "${PACKAGE_TEMPORARY}/Contents/MacOS/${BUNDLE_EXECUTABLE_NAME}"
cp "${BUILD_DIRECTORY}/release/${WORKER_EXECUTABLE_NAME}" "${PACKAGE_TEMPORARY}/Contents/Helpers/${WORKER_EXECUTABLE_NAME}"
chmod 755 "${PACKAGE_TEMPORARY}/Contents/Helpers/${WORKER_EXECUTABLE_NAME}"
strip -S -x "${PACKAGE_TEMPORARY}/Contents/Helpers/${WORKER_EXECUTABLE_NAME}"

DEFAULT_ICON_MASTER="${PROJECT_DIRECTORY}/Resources/AppIcon-Ember.png"
APP_ICON="AppIcon.icns"
DOCUMENT_ICON="HwattakPDFDocument.icns"
ICON_VARIANTS=(
    "AppIcon-Ember.png"
    "AppIcon-StackAndSelect.png"
    "AppIcon-PrecisionMarkup.png"
    "AppIcon-FoldWorkspace.png"
)
ABOUT_IMAGE="AboutAuthor-SeederPowerDrop-UserProvided.jpg"
BUNDLED_PLUGIN_NAMES=(
    "TranslationCompanion.hwattakplugin"
    "PageTranslator.hwattakplugin"
    "WebBrowser.hwattakplugin"
    "StudyMarkup.hwattakplugin"
    "TabletTools.hwattakplugin"
    "ReadingNavigation.hwattakplugin"
    "ReadingColors.hwattakplugin"
    "MarkdownNotebook.hwattakplugin"
    "PageClipper.hwattakplugin"
    "RelatedDocuments.hwattakplugin"
    "HoverTranslator.hwattakplugin"
    "ReadingLab.hwattakplugin"
    "ResearchTrail.hwattakplugin"
)
SOURCE_ONLY_PLUGIN_NAMES=(
    "YouTubeStudy.hwattakplugin"
)
LEGAL_DOCUMENTS=(
    "LICENSE"
    "NOTICE"
    "ASSETS.md"
    "TRADEMARKS.md"
)

if [[ ! -f "${DEFAULT_ICON_MASTER}" ]]; then
    echo "Missing app icon: ${DEFAULT_ICON_MASTER}" >&2
    exit 1
fi
cp "${DEFAULT_ICON_MASTER}" "${PACKAGE_TEMPORARY}/Contents/Resources/AppIcon.png"
# Give Finder and Dock native standard/Retina representations of the new mark.
APP_ICONSET="${VERIFICATION_DIRECTORY}/AppIcon.iconset"
mkdir -p "${APP_ICONSET}"
for icon_points in 16 32 128 256 512; do
    sips -z "${icon_points}" "${icon_points}" "${DEFAULT_ICON_MASTER}" \
        --out "${APP_ICONSET}/icon_${icon_points}x${icon_points}.png" >/dev/null
    icon_pixels=$((icon_points * 2))
    sips -z "${icon_pixels}" "${icon_pixels}" "${DEFAULT_ICON_MASTER}" \
        --out "${APP_ICONSET}/icon_${icon_points}x${icon_points}@2x.png" >/dev/null
done
iconutil -c icns "${APP_ICONSET}" \
    -o "${PACKAGE_TEMPORARY}/Contents/Resources/${APP_ICON}"
rm -rf "${APP_ICONSET}"

DOCUMENT_ICON_PATH="${PROJECT_DIRECTORY}/Resources/${DOCUMENT_ICON}"
if [[ ! -f "${DOCUMENT_ICON_PATH}" ]]; then
    echo "Missing PDF document icon: ${DOCUMENT_ICON_PATH}" >&2
    exit 1
fi
cp "${DOCUMENT_ICON_PATH}" "${PACKAGE_TEMPORARY}/Contents/Resources/${DOCUMENT_ICON}"

for icon_name in "${ICON_VARIANTS[@]}"; do
    icon_path="${PROJECT_DIRECTORY}/Resources/${icon_name}"
    if [[ ! -f "${icon_path}" ]]; then
        echo "Missing alternate app icon: ${icon_path}" >&2
        exit 1
    fi
    cp "${icon_path}" "${PACKAGE_TEMPORARY}/Contents/Resources/${icon_name}"
done

ABOUT_IMAGE_PATH="${PROJECT_DIRECTORY}/Resources/${ABOUT_IMAGE}"
if [[ ! -f "${ABOUT_IMAGE_PATH}" ]]; then
    echo "Missing About artwork: ${ABOUT_IMAGE_PATH}" >&2
    exit 1
fi
cp "${ABOUT_IMAGE_PATH}" "${PACKAGE_TEMPORARY}/Contents/Resources/${ABOUT_IMAGE}"
cp "${PROJECT_DIRECTORY}/scripts/translation_argos_worker.py" \
    "${PACKAGE_TEMPORARY}/Contents/Resources/translation_argos_worker.py"
cp "${PROJECT_DIRECTORY}/scripts/start_local_translation.command" \
    "${PACKAGE_TEMPORARY}/Contents/Resources/start_local_translation.command"
chmod 755 "${PACKAGE_TEMPORARY}/Contents/Resources/start_local_translation.command"
cp "${PROJECT_DIRECTORY}/Documentation/LOCAL-TRANSLATION.md" \
    "${PACKAGE_TEMPORARY}/Contents/Resources/LOCAL-TRANSLATION.md"

# AI answers render Markdown and equations offline; ship their pinned renderer,
# fonts and original third-party license notices as one resource directory.
AI_RICH_TEXT_DIRECTORY="${PROJECT_DIRECTORY}/Resources/AIRichText"
test -f "${AI_RICH_TEXT_DIRECTORY}/index.html"
test -f "${AI_RICH_TEXT_DIRECTORY}/katex/LICENSE"
test -f "${AI_RICH_TEXT_DIRECTORY}/marked/LICENSE"
test -f "${AI_RICH_TEXT_DIRECTORY}/dompurify/LICENSE"
cp -R "${AI_RICH_TEXT_DIRECTORY}" "${PACKAGE_TEMPORARY}/Contents/Resources/AIRichText"

# SwiftPM links the native body-text engine as a framework. Ship and sign it
# inside the app so a copied/released app never depends on the source checkout.
PDFIUM_VENDOR="${PROJECT_DIRECTORY}/Vendor/PDFium"
PDFIUM_FRAMEWORK="${PDFIUM_VENDOR}/CPDFium.xcframework/macos-arm64_x86_64/CPDFium.framework"
mkdir -p "${PACKAGE_TEMPORARY}/Contents/Frameworks"
cp -R "${PDFIUM_FRAMEWORK}" "${PACKAGE_TEMPORARY}/Contents/Frameworks/"
# SwiftPM's command-line products use a sibling framework; application bundles
# resolve it from Contents/Frameworks instead.
install_name_tool -add_rpath @executable_path/../Frameworks \
    "${PACKAGE_TEMPORARY}/Contents/MacOS/${BUNDLE_EXECUTABLE_NAME}"
# The linker may add its selected Swift toolchain as an absolute search path.
# Keep only system and contained bundle paths in both distributable executables.
python3 - "${PACKAGE_TEMPORARY}" <<'PY_PORTABLE_RUNTIME'
from pathlib import Path
import re
import subprocess
import sys

app = Path(sys.argv[1]).resolve(strict=True)
swiftc = Path(subprocess.check_output(
    ['/usr/bin/xcrun', '--find', 'swiftc'], text=True).rstrip('\n')).resolve(strict=True)
if swiftc.parent.name != 'bin' or swiftc.parent.parent.name != 'usr':
    raise SystemExit('Cannot establish the selected Swift toolchain root')
toolchain = swiftc.parents[2]
binaries = [app / 'Contents/MacOS/EmberPDF', app / 'Contents/Helpers/EmberPluginWorker']
load_commands = {'LC_LOAD_DYLIB', 'LC_LOAD_WEAK_DYLIB', 'LC_REEXPORT_DYLIB',
                 'LC_LOAD_UPWARD_DYLIB', 'LC_LAZY_LOAD_DYLIB'}

def entries(text):
    rpaths, dependencies = [], []
    for block in re.split(r'^Load command \d+\s*$', text, flags=re.M):
        command = re.search(r'^\s*cmd (\S+)\s*$', block, flags=re.M)
        if command is None:
            continue
        kind = command[1]
        if kind != 'LC_RPATH' and kind not in load_commands:
            continue
        key = 'path' if kind == 'LC_RPATH' else 'name'
        # Use the final offset suffix: spaces in a selected toolchain stay intact.
        values = re.findall(r'^\s*' + key + r' (.+) \(offset \d+\)\s*$', block, flags=re.M)
        if len(values) != 1:
            raise SystemExit('Ambiguous Mach-O path load command')
        (rpaths if kind == 'LC_RPATH' else dependencies).append(values[0])
    if len(rpaths) != len(set(rpaths)):
        raise SystemExit('Duplicate Mach-O search path')
    return rpaths, dependencies

def system_path(value):
    path = Path(value)
    return path.is_absolute() and '..' not in path.parts and any(
        path.is_relative_to(base) for base in (Path('/System/Library'), Path('/usr/lib')))

def path_kind(value, binary):
    path = Path(value)
    if path.is_absolute() and '..' not in path.parts and path.is_relative_to(toolchain):
        return 'selected-toolchain'
    if system_path(value):
        return 'system'
    for token in ('@loader_path', '@executable_path'):
        if value == token or value.startswith(token + '/'):
            resolved = (binary.parent / value[len(token):].lstrip('/')).resolve(strict=True)
            if resolved.is_dir() and resolved.is_relative_to(app):
                return 'bundle'
    raise SystemExit('Unknown or escaping Mach-O search path: ' + value)

def inspect(binary):
    text = subprocess.check_output(['/usr/bin/otool', '-arch', 'arm64', '-l', str(binary)], text=True)
    rpaths, dependencies = entries(text)
    kinds = [path_kind(value, binary) for value in rpaths]
    for value in dependencies:
        if system_path(value):
            continue
        if binary == binaries[0] and value == '@rpath/CPDFium.framework/CPDFium':
            framework = (app / 'Contents/Frameworks/CPDFium.framework/CPDFium').resolve(strict=True)
            if (framework.is_file() and framework.is_relative_to(app)
                    and '@executable_path/../Frameworks' in rpaths):
                continue
        raise SystemExit('Unknown or non-bundled Mach-O dependency: ' + value)
    return rpaths, dependencies, kinds

# Validate both new executables before mutating either; no original app is read.
plans = [(binary, inspect(binary)) for binary in binaries]
for binary, (rpaths, dependencies, kinds) in plans:
    removed = [value for value, kind in zip(rpaths, kinds) if kind == 'selected-toolchain']
    for value in removed:
        subprocess.run(['/usr/bin/install_name_tool', '-delete_rpath', value, str(binary)], check=True)
    fresh_paths, fresh_dependencies, fresh_kinds = inspect(binary)
    expected = [value for value, kind in zip(rpaths, kinds) if kind != 'selected-toolchain']
    if (fresh_paths != expected or fresh_dependencies != dependencies
            or 'selected-toolchain' in fresh_kinds):
        raise SystemExit('Mach-O search path normalization did not preserve the declared runtime')
    print('Verified portable runtime paths:', binary.name, 'removed', len(removed))
PY_PORTABLE_RUNTIME
codesign --force --sign - "${PACKAGE_TEMPORARY}/Contents/Frameworks/CPDFium.framework"

mkdir -p "${PACKAGE_TEMPORARY}/Contents/Resources/Legal"
mkdir -p "${PACKAGE_TEMPORARY}/Contents/Resources/Legal/PDFium"
cp "${PDFIUM_VENDOR}/LICENSE" "${PACKAGE_TEMPORARY}/Contents/Resources/Legal/PDFium/"
cp -R "${PDFIUM_VENDOR}/licenses" "${PACKAGE_TEMPORARY}/Contents/Resources/Legal/PDFium/"
# qpdf and libjpeg are linked statically; their notices travel with every app.
QPDF_LICENSES="${PROJECT_DIRECTORY}/Vendor/QPDF/licenses"
for qpdf_notice in qpdf-LICENSE.txt qpdf-NOTICE.md libjpeg-turbo-LICENSE.md libjpeg-turbo-README.ijg; do
    test -f "${QPDF_LICENSES}/${qpdf_notice}"
done
mkdir -p "${PACKAGE_TEMPORARY}/Contents/Resources/Legal/QPDF"
cp -R "${QPDF_LICENSES}/." "${PACKAGE_TEMPORARY}/Contents/Resources/Legal/QPDF/"
for legal_document in "${LEGAL_DOCUMENTS[@]}"; do
    legal_document_path="${PROJECT_DIRECTORY}/${legal_document}"
    if [[ ! -f "${legal_document_path}" ]]; then
        echo "Missing legal document: ${legal_document_path}" >&2
        exit 1
    fi
    cp "${legal_document_path}" \
        "${PACKAGE_TEMPORARY}/Contents/Resources/Legal/${legal_document}"
done
cp "${PROJECT_DIRECTORY}/Resources/AboutAuthor-UserProvided-NOTICE.txt" \
    "${PACKAGE_TEMPORARY}/Contents/Resources/Legal/AboutAuthor-UserProvided-NOTICE.txt"

mkdir -p "${PACKAGE_TEMPORARY}/Contents/Resources/BundledPlugins"
for plugin_name in "${BUNDLED_PLUGIN_NAMES[@]}"; do
    plugin_path="${PROJECT_DIRECTORY}/Examples/Plugins/${plugin_name}"
    if [[ ! -d "${plugin_path}" ]]; then
        echo "Missing bundled plugin: ${plugin_path}" >&2
        exit 1
    fi
    cp -R "${plugin_path}" "${PACKAGE_TEMPORARY}/Contents/Resources/BundledPlugins/"
done
for plugin_name in "${SOURCE_ONLY_PLUGIN_NAMES[@]}"; do
    if [[ -e "${PACKAGE_TEMPORARY}/Contents/Resources/BundledPlugins/${plugin_name}" ]]; then
        echo "Source-only plugin must not be packaged: ${plugin_name}" >&2
        exit 1
    fi
done

for language in "${EXPECTED_LOCALIZATIONS[@]}"; do
    localization_path="${LOCALIZATION_DIRECTORY}/${language}.lproj"
    strings_path="${localization_path}/Localizable.strings"
    if [[ ! -f "${strings_path}" ]]; then
        echo "Missing localization: ${strings_path}" >&2
        exit 1
    fi
    plutil -lint "${strings_path}"
    cp -R "${localization_path}" "${PACKAGE_TEMPORARY}/Contents/Resources/"
done

if LC_ALL=C strings -a "${PACKAGE_TEMPORARY}/Contents/MacOS/${BUNDLE_EXECUTABLE_NAME}" \
    | grep -E '/Users/|/private/var/folders/|/var/folders/' >/dev/null; then
    echo "Release executable contains a local build path" >&2
    exit 1
fi

codesign \
    --force \
    --sign - \
    --entitlements "${PROJECT_DIRECTORY}/Resources/EmberPluginWorker.entitlements" \
    "${PACKAGE_TEMPORARY}/Contents/Helpers/${WORKER_EXECUTABLE_NAME}"

codesign \
    --force \
    --sign - \
    --entitlements "${PROJECT_DIRECTORY}/Resources/HwattakPDF.entitlements" \
    "${PACKAGE_TEMPORARY}"

if [[ -e "${APP_BUNDLE}" ]]; then
    rm -rf "${APP_BUNDLE}"
fi
mv "${PACKAGE_TEMPORARY}" "${APP_BUNDLE}"

plutil -lint "${APP_BUNDLE}/Contents/Info.plist"
codesign --verify --deep --strict "${APP_BUNDLE}"
test -x "${APP_BUNDLE}/Contents/Helpers/${WORKER_EXECUTABLE_NAME}"
codesign --verify --strict "${APP_BUNDLE}/Contents/Helpers/${WORKER_EXECUTABLE_NAME}"

PACKAGED_DOCUMENT_ICON="$(plutil -extract CFBundleDocumentTypes.0.CFBundleTypeIconFile raw -o - "${APP_BUNDLE}/Contents/Info.plist")"
[[ "${PACKAGED_DOCUMENT_ICON}" == "${DOCUMENT_ICON}" ]] \
    || { echo "PDF document icon registration does not match bundled resource" >&2; exit 1; }
cmp "${DOCUMENT_ICON_PATH}" "${APP_BUNDLE}/Contents/Resources/${DOCUMENT_ICON}"

for icon_name in "${ICON_VARIANTS[@]}"; do
    test -f "${APP_BUNDLE}/Contents/Resources/${icon_name}"
done
test -f "${APP_BUNDLE}/Contents/Resources/${ABOUT_IMAGE}"
cmp "${PROJECT_DIRECTORY}/scripts/translation_argos_worker.py" \
    "${APP_BUNDLE}/Contents/Resources/translation_argos_worker.py"
test -x "${APP_BUNDLE}/Contents/Resources/start_local_translation.command"
diff -qr "${AI_RICH_TEXT_DIRECTORY}" "${APP_BUNDLE}/Contents/Resources/AIRichText"
for legal_document in "${LEGAL_DOCUMENTS[@]}"; do
    test -f "${APP_BUNDLE}/Contents/Resources/Legal/${legal_document}"
done
test -f "${APP_BUNDLE}/Contents/Resources/Legal/AboutAuthor-UserProvided-NOTICE.txt"
test -f "${APP_BUNDLE}/Contents/Resources/Legal/PDFium/licenses/pdfium.txt"
diff -qr "${QPDF_LICENSES}" "${APP_BUNDLE}/Contents/Resources/Legal/QPDF"
codesign --verify --strict "${APP_BUNDLE}/Contents/Frameworks/CPDFium.framework"
for plugin_name in "${BUNDLED_PLUGIN_NAMES[@]}"; do
    test -f "${APP_BUNDLE}/Contents/Resources/BundledPlugins/${plugin_name}/manifest.json"
done
for language in "${EXPECTED_LOCALIZATIONS[@]}"; do
    test -f "${APP_BUNDLE}/Contents/Resources/${language}.lproj/Localizable.strings"
done

PACKAGED_SHORT_VERSION="$(plutil -extract CFBundleShortVersionString raw -o - "${APP_BUNDLE}/Contents/Info.plist")"
PACKAGED_BUILD_VERSION="$(plutil -extract CFBundleVersion raw -o - "${APP_BUNDLE}/Contents/Info.plist")"
if [[ "${PACKAGED_SHORT_VERSION}" != "${SHORT_VERSION}" || "${PACKAGED_BUILD_VERSION}" != "${BUILD_VERSION}" ]]; then
    echo "Packaged version does not match ${SHORT_VERSION} (${BUILD_VERSION})" >&2
    exit 1
fi

BINARY_ARCHITECTURES="$(lipo -archs "${APP_BUNDLE}/Contents/MacOS/${BUNDLE_EXECUTABLE_NAME}")"
if [[ "${BINARY_ARCHITECTURES}" != "${TARGET_ARCHITECTURE}" ]]; then
    echo "Expected ${TARGET_ARCHITECTURE} binary, found: ${BINARY_ARCHITECTURES}" >&2
    exit 1
fi

# Keep the standalone app output while staging three convenient ZIP-root items.
COPYFILE_DISABLE=1 ditto --norsrc --noextattr \
    "${APP_BUNDLE}" "${DISTRIBUTION_DIRECTORY}/${APP_NAME}.app"
cp "${INSTALL_GUIDE}" "${DISTRIBUTION_DIRECTORY}/INSTALL-macOS.txt"
# The source release notes link to other repository documents. Those documents
# live in the matching source package, not beside the app in this ZIP. Preserve
# external links and replace relative links with readable source references.
perl -pe '
    s{(?<!!)\[([^\]\n]+)\]\(((?![A-Za-z][A-Za-z0-9+.-]*:|\#)[^)\s]+)\)}{
        my ($label, $path) = ($1, $2);
        $path = $path =~ m{\A\.\./} ? substr($path, 3) : "Documentation/$path";
        "$label (별도 소스 패키지의 `$path` 참조)"
    }ge;
' "${RELEASE_NOTES}" > "${DISTRIBUTION_DIRECTORY}/${RELEASE_NOTES_NAME}"
test -s "${DISTRIBUTION_DIRECTORY}/${RELEASE_NOTES_NAME}"

COPYFILE_DISABLE=1 ditto \
    -c \
    -k \
    --norsrc \
    --noextattr \
    "${DISTRIBUTION_DIRECTORY}" \
    "${ARCHIVE_TEMPORARY}"

COPYFILE_DISABLE=1 ditto -x -k --norsrc --noextattr \
    "${ARCHIVE_TEMPORARY}" "${VERIFICATION_DIRECTORY}"
VERIFIED_APP="${VERIFICATION_DIRECTORY}/${APP_NAME}.app"
VERIFIED_ENTITLEMENTS="${VERIFICATION_DIRECTORY}/verified-entitlements.plist"
ARCHIVED_ROOT_ENTRIES=("${VERIFICATION_DIRECTORY}"/*(DN))
if [[ ${#ARCHIVED_ROOT_ENTRIES[@]} -ne 3 ]]; then
    echo "Archive must contain exactly the app, installation guide and release notes" >&2
    exit 1
fi
test -d "${VERIFIED_APP}"
cmp "${INSTALL_GUIDE}" "${VERIFICATION_DIRECTORY}/INSTALL-macOS.txt"
cmp "${DISTRIBUTION_DIRECTORY}/${RELEASE_NOTES_NAME}" \
    "${VERIFICATION_DIRECTORY}/${RELEASE_NOTES_NAME}"
if find "${VERIFICATION_DIRECTORY}" \( -name '._*' -o -name '__MACOSX' \) \
    -print -quit | grep -q .; then
    echo "Archive contains AppleDouble metadata" >&2
    exit 1
fi
plutil -lint "${VERIFIED_APP}/Contents/Info.plist"
codesign --verify --deep --strict "${VERIFIED_APP}"
VERIFIED_WORKER="${VERIFIED_APP}/Contents/Helpers/${WORKER_EXECUTABLE_NAME}"
test -x "${VERIFIED_WORKER}"
cmp "${APP_BUNDLE}/Contents/Helpers/${WORKER_EXECUTABLE_NAME}" "${VERIFIED_WORKER}"
codesign --verify --strict "${VERIFIED_WORKER}"
[[ "$(lipo -archs "${VERIFIED_WORKER}")" == "${TARGET_ARCHITECTURE}" ]] \
    || { echo "Archived plugin worker architecture mismatch" >&2; exit 1; }
VERIFIED_WORKER_ENTITLEMENTS="${VERIFICATION_DIRECTORY}/verified-worker-entitlements.plist"
codesign -d --entitlements - --xml "${VERIFIED_WORKER}" > "${VERIFIED_WORKER_ENTITLEMENTS}" 2>/dev/null
plutil -lint "${VERIFIED_WORKER_ENTITLEMENTS}"
python3 - "${VERIFIED_WORKER_ENTITLEMENTS}" <<'PY'
import plistlib
import sys
with open(sys.argv[1], 'rb') as stream:
    actual = plistlib.load(stream)
expected = {'com.apple.security.app-sandbox': True, 'com.apple.security.inherit': True}
if actual != expected:
    raise SystemExit('Plugin worker must contain exactly the two sandbox inheritance entitlements')
PY
if LC_ALL=C strings -a "${VERIFIED_WORKER}" | grep -E '/Users/|/private/var/folders/|/var/folders/' >/dev/null; then
    echo "Archived plugin worker contains a local build path" >&2
    exit 1
fi
cmp "${DEFAULT_ICON_MASTER}" "${VERIFIED_APP}/Contents/Resources/AppIcon.png"
PACKAGED_APP_ICON="$(plutil -extract CFBundleIconFile raw -o - "${VERIFIED_APP}/Contents/Info.plist")"
[[ "${PACKAGED_APP_ICON}" == "${APP_ICON}" ]] || { echo "Unexpected app icon registration" >&2; exit 1; }
VERIFIED_APP_ICONSET="${VERIFICATION_DIRECTORY}/VerifiedAppIcon.iconset"
iconutil -c iconset "${VERIFIED_APP}/Contents/Resources/${APP_ICON}" -o "${VERIFIED_APP_ICONSET}"
for icon_points in 16 32 128 256 512; do
    test -f "${VERIFIED_APP_ICONSET}/icon_${icon_points}x${icon_points}.png"
    test -f "${VERIFIED_APP_ICONSET}/icon_${icon_points}x${icon_points}@2x.png"
done
cmp "${DOCUMENT_ICON_PATH}" "${VERIFIED_APP}/Contents/Resources/${DOCUMENT_ICON}"
# Decode the archived resource, not just the source, to validate both format
# and all standard/Retina representations used by Finder at different sizes.
DOCUMENT_ICONSET="${VERIFICATION_DIRECTORY}/DocumentIcon.iconset"
iconutil -c iconset "${VERIFIED_APP}/Contents/Resources/${DOCUMENT_ICON}" -o "${DOCUMENT_ICONSET}"
for icon_points in 16 32 128 256 512; do
    test -f "${DOCUMENT_ICONSET}/icon_${icon_points}x${icon_points}.png"
    test -f "${DOCUMENT_ICONSET}/icon_${icon_points}x${icon_points}@2x.png"
done
codesign -d --entitlements - --xml "${VERIFIED_APP}" \
    > "${VERIFIED_ENTITLEMENTS}" 2>/dev/null
plutil -lint "${VERIFIED_ENTITLEMENTS}"
for entitlement_name in "${EXPECTED_ENTITLEMENTS[@]}"; do
    # plutil treats periods as key-path separators unless they are escaped.
    entitlement_key_path="${entitlement_name//./\\.}"
    entitlement_value="$(
        plutil -extract "${entitlement_key_path}" raw -o - "${VERIFIED_ENTITLEMENTS}"
    )"
    if [[ "${entitlement_value}" != "true" && "${entitlement_value}" != "1" ]]; then
        echo "Archived app is missing entitlement: ${entitlement_name}" >&2
        exit 1
    fi
done
for icon_name in "${ICON_VARIANTS[@]}"; do
    test -f "${VERIFIED_APP}/Contents/Resources/${icon_name}"
done
test -f "${VERIFIED_APP}/Contents/Resources/${ABOUT_IMAGE}"
diff -qr "${AI_RICH_TEXT_DIRECTORY}" "${VERIFIED_APP}/Contents/Resources/AIRichText"
for legal_document in "${LEGAL_DOCUMENTS[@]}"; do
    test -f "${VERIFIED_APP}/Contents/Resources/Legal/${legal_document}"
done
test -f "${VERIFIED_APP}/Contents/Resources/Legal/AboutAuthor-UserProvided-NOTICE.txt"
test -f "${VERIFIED_APP}/Contents/Resources/Legal/PDFium/licenses/pdfium.txt"
diff -qr "${QPDF_LICENSES}" "${VERIFIED_APP}/Contents/Resources/Legal/QPDF"
codesign --verify --strict "${VERIFIED_APP}/Contents/Frameworks/CPDFium.framework"
for plugin_name in "${BUNDLED_PLUGIN_NAMES[@]}"; do
    test -f "${VERIFIED_APP}/Contents/Resources/BundledPlugins/${plugin_name}/manifest.json"
done
for plugin_name in "${SOURCE_ONLY_PLUGIN_NAMES[@]}"; do
    if [[ -e "${VERIFIED_APP}/Contents/Resources/BundledPlugins/${plugin_name}" ]]; then
        echo "Archived app contains source-only plugin: ${plugin_name}" >&2
        exit 1
    fi
done
for language in "${EXPECTED_LOCALIZATIONS[@]}"; do
    verified_strings="${VERIFIED_APP}/Contents/Resources/${language}.lproj/Localizable.strings"
    test -f "${verified_strings}"
    plutil -lint "${verified_strings}"
done

VERIFIED_SHORT_VERSION="$(plutil -extract CFBundleShortVersionString raw -o - "${VERIFIED_APP}/Contents/Info.plist")"
VERIFIED_BUILD_VERSION="$(plutil -extract CFBundleVersion raw -o - "${VERIFIED_APP}/Contents/Info.plist")"
VERIFIED_ARCHITECTURES="$(lipo -archs "${VERIFIED_APP}/Contents/MacOS/${BUNDLE_EXECUTABLE_NAME}")"
if [[ "${VERIFIED_SHORT_VERSION}" != "${SHORT_VERSION}" || "${VERIFIED_BUILD_VERSION}" != "${BUILD_VERSION}" ]]; then
    echo "Archived version does not match ${SHORT_VERSION} (${BUILD_VERSION})" >&2
    exit 1
fi
if [[ "${VERIFIED_ARCHITECTURES}" != "${TARGET_ARCHITECTURE}" ]]; then
    echo "Archived binary is not ${TARGET_ARCHITECTURE}: ${VERIFIED_ARCHITECTURES}" >&2
    exit 1
fi
if LC_ALL=C strings -a "${VERIFIED_APP}/Contents/MacOS/${BUNDLE_EXECUTABLE_NAME}" \
    | grep -E '/Users/|/private/var/folders/|/var/folders/' >/dev/null; then
    echo "Archived executable contains a local build path" >&2
    exit 1
fi

mv -f "${ARCHIVE_TEMPORARY}" "${ARCHIVE_PATH}"
ARCHIVE_SHA256="$(shasum -a 256 "${ARCHIVE_PATH}" | awk '{print $1}')"
printf '%s  %s\n' "${ARCHIVE_SHA256}" "${ARCHIVE_NAME}" \
    > "${ARCHIVE_CHECKSUM_PATH}"
grep -Fqx "${ARCHIVE_SHA256}  ${ARCHIVE_NAME}" "${ARCHIVE_CHECKSUM_PATH}"

echo "Built ${APP_BUNDLE}"
echo "Version ${SHORT_VERSION} (${BUILD_VERSION}), architecture ${TARGET_ARCHITECTURE}"
echo "Archived ${ARCHIVE_PATH}"
echo "SHA-256 ${ARCHIVE_SHA256}"
