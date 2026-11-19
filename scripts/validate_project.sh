#!/bin/zsh

set -euo pipefail

SCRIPT_DIRECTORY="${0:A:h}"
PROJECT_DIRECTORY="${SCRIPT_DIRECTORY:h}"
INFO_PLIST="${PROJECT_DIRECTORY}/Resources/Info.plist"
ENTITLEMENTS="${PROJECT_DIRECTORY}/Resources/HwattakPDF.entitlements"
LOCALIZATION_DIRECTORY="${PROJECT_DIRECTORY}/Resources/Localization"
EXPECTED_LOCALIZATIONS=(ko en ja zh-Hans vi es fr de ru ar)
REQUIRED_RESOURCES=(
    AppIcon-Ember.png
    AboutAuthor-SeederPowerDrop-UserProvided.jpg
    AppIcon-FoldWorkspace.png
    AppIcon-PrecisionMarkup.png
    AppIcon-StackAndSelect.png
    HwattakPDFDocument.icns
    AIRichText/index.html
    AIRichText/renderer.js
    AIRichText/renderer.css
    AIRichText/vendor-manifest.json
    AIRichText/katex/katex.min.js
    AIRichText/katex/katex.min.css
    AIRichText/katex/fonts/KaTeX_Main-Regular.woff2
    AIRichText/katex/LICENSE
    AIRichText/marked/marked.umd.js
    AIRichText/marked/LICENSE
    AIRichText/dompurify/purify.min.js
    AIRichText/dompurify/LICENSE
)
EXAMPLE_PLUGIN_NAMES=(
    TranslationCompanion.hwattakplugin
    PageTranslator.hwattakplugin
    YouTubeStudy.hwattakplugin
    WebBrowser.hwattakplugin
    StudyMarkup.hwattakplugin
    TabletTools.hwattakplugin
    ReadingNavigation.hwattakplugin
    CommunityStarter.hwattakplugin
    OfflineChecklist.hwattakplugin
    ReadingColors.hwattakplugin
    MarkdownNotebook.hwattakplugin
    PageClipper.hwattakplugin
    RelatedDocuments.hwattakplugin
    HoverTranslator.hwattakplugin
    ReadingLab.hwattakplugin
)
CURRENT_VERSION_DOCUMENTS=(
    README.md
    Documentation/README.md
    Documentation/PRODUCT.md
    Documentation/ARCHITECTURE.md
    Documentation/PLUGINS.md
    Documentation/QUALITY_REPORT.md
)

fail() {
    echo "validation failed: $*" >&2
    exit 1
}

require_file() {
    [[ -f "$1" ]] || fail "missing file: ${1}"
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || fail "missing command: $1"
}

require_command plutil
require_command jq
require_command swift
require_command sort
require_command sed
require_command uniq
require_command cmp
require_command find
require_command head
require_command shasum
require_command lipo

require_file "${PROJECT_DIRECTORY}/Package.swift"
require_file "${PROJECT_DIRECTORY}/Sources/HwattakPDF/App/HwattakPDFApp.swift"
require_file "${PROJECT_DIRECTORY}/Sources/HwattakPDF/Views/HwattakPDFTheme.swift"
[[ -d "${PROJECT_DIRECTORY}/Tests/HwattakPDFTests" ]] \
    || fail "HwattakPDF test directory is missing"
require_file "${INFO_PLIST}"
require_file "${ENTITLEMENTS}"
require_file "${PROJECT_DIRECTORY}/LICENSE"
require_file "${PROJECT_DIRECTORY}/NOTICE"
require_file "${PROJECT_DIRECTORY}/ASSETS.md"
require_file "${PROJECT_DIRECTORY}/TRADEMARKS.md"
require_file "${PROJECT_DIRECTORY}/Documentation/RELEASE-NOTES-0.8.0.md"
require_file "${PROJECT_DIRECTORY}/Resources/AboutAuthor-UserProvided-NOTICE.txt"

grep -Fq "Mozilla Public License Version 2.0" "${PROJECT_DIRECTORY}/LICENSE" \
    || fail "LICENSE is not the MPL-2.0 text"
grep -Fq "Copyright 2026 SeederPowerDrop" "${PROJECT_DIRECTORY}/NOTICE" \
    || fail "NOTICE copyright is missing or stale"
grep -Fq "Mozilla Public License 2.0" \
    "${PROJECT_DIRECTORY}/Resources/AboutAuthor-UserProvided-NOTICE.txt" \
    || fail "About artwork license notice is missing"
grep -Fq "// SPDX-License-Identifier: MPL-2.0" "${PROJECT_DIRECTORY}/Package.swift" \
    || fail "Package.swift SPDX notice is missing"

while IFS= read -r source_file; do
    [[ "$(head -n 1 "${source_file}")" == "// SPDX-License-Identifier: MPL-2.0" ]] \
        || fail "Swift source SPDX notice is missing: ${source_file}"
done < <(find "${PROJECT_DIRECTORY}/Sources" "${PROJECT_DIRECTORY}/Tests" -type f -name '*.swift' -print)

plutil -lint "${INFO_PLIST}" >/dev/null
plutil -lint "${ENTITLEMENTS}" >/dev/null

SHORT_VERSION="$(plutil -extract CFBundleShortVersionString raw -o - "${INFO_PLIST}")"
BUILD_VERSION="$(plutil -extract CFBundleVersion raw -o - "${INFO_PLIST}")"
MINIMUM_SYSTEM="$(plutil -extract LSMinimumSystemVersion raw -o - "${INFO_PLIST}")"
BUNDLE_EXECUTABLE="$(plutil -extract CFBundleExecutable raw -o - "${INFO_PLIST}")"
BUNDLE_NAME="$(plutil -extract CFBundleName raw -o - "${INFO_PLIST}")"
BUNDLE_DISPLAY_NAME="$(plutil -extract CFBundleDisplayName raw -o - "${INFO_PLIST}")"
BUNDLE_IDENTIFIER="$(plutil -extract CFBundleIdentifier raw -o - "${INFO_PLIST}")"
BUNDLE_COPYRIGHT="$(plutil -extract NSHumanReadableCopyright raw -o - "${INFO_PLIST}")"

[[ "${SHORT_VERSION}" == <->.<->.<-> ]] \
    || fail "CFBundleShortVersionString must use semantic x.y.z form"
[[ "${BUILD_VERSION}" == <-> ]] \
    || fail "CFBundleVersion must be a positive integer"
(( BUILD_VERSION > 0 )) || fail "CFBundleVersion must be greater than zero"
require_file "${PROJECT_DIRECTORY}/Documentation/RELEASE-NOTES-${SHORT_VERSION}.md"
require_file "${PROJECT_DIRECTORY}/Documentation/RELEASE-VALIDATION-${SHORT_VERSION}.md"
require_file "${PROJECT_DIRECTORY}/Documentation/INSTALL-macOS.txt"
# Only the current document headers declare this package's version; older
# build numbers remain valid historical evidence later in the release notes.
INSTALL_VERSION_HEADER="$(head -n 8 "${PROJECT_DIRECTORY}/Documentation/INSTALL-macOS.txt" | sed -n '/^대상: /{p;q;}')"
[[ "${INSTALL_VERSION_HEADER}" == "대상: ${SHORT_VERSION} "*"(build ${BUILD_VERSION})" ]] \
    || fail "installation guide current version/build is missing or stale"
RELEASE_NOTES_PATH="${PROJECT_DIRECTORY}/Documentation/RELEASE-NOTES-${SHORT_VERSION}.md"
RELEASE_NOTES_TITLE="$(head -n 1 "${RELEASE_NOTES_PATH}")"
[[ "${RELEASE_NOTES_TITLE}" == "# EmberPDF ${SHORT_VERSION}" || "${RELEASE_NOTES_TITLE}" == "# EmberPDF ${SHORT_VERSION} "* ]] \
    || fail "release notes current title version is missing or stale"
RELEASE_VERSION_HEADER="$(head -n 8 "${RELEASE_NOTES_PATH}" | sed -n '/^\*\*버전 /{p;q;}')"
[[ "${RELEASE_VERSION_HEADER}" == "**버전 ${SHORT_VERSION} · build ${BUILD_VERSION} · "*"**" ]] \
    || fail "release notes current version/build is missing or stale"
PDF_DOCUMENT_ICON="$(plutil -extract CFBundleDocumentTypes.0.CFBundleTypeIconFile raw -o - "${INFO_PLIST}")"
[[ "${PDF_DOCUMENT_ICON}" == "HwattakPDFDocument.icns" ]] \
    || fail "PDF document icon registration is missing or stale"
[[ "${MINIMUM_SYSTEM}" == "14.0" ]] \
    || fail "Info.plist minimum macOS must remain 14.0"
[[ "${BUNDLE_EXECUTABLE}" == "EmberPDF" ]] \
    || fail "unexpected bundle executable: ${BUNDLE_EXECUTABLE}"
[[ "${BUNDLE_NAME}" == "EmberPDF" && "${BUNDLE_DISPLAY_NAME}" == "EmberPDF" ]] \
    || fail "bundle names must use EmberPDF"
[[ "${BUNDLE_IDENTIFIER}" == "com.vibepdf.mac" ]] \
    || fail "bundle identifier must preserve the existing upgrade identity"
[[ "${BUNDLE_COPYRIGHT}" == "Copyright © 2026 SeederPowerDrop" ]] \
    || fail "unexpected bundle copyright: ${BUNDLE_COPYRIGHT}"
grep -q '\.macOS(\.v14)' "${PROJECT_DIRECTORY}/Package.swift" \
    || fail "Package.swift minimum macOS does not match Info.plist"

CURRENT_VERSION_LABEL="${SHORT_VERSION} (build ${BUILD_VERSION})"
for document_name in "${CURRENT_VERSION_DOCUMENTS[@]}"; do
    document_path="${PROJECT_DIRECTORY}/${document_name}"
    require_file "${document_path}"
    grep -Fq "${CURRENT_VERSION_LABEL}" "${document_path}" \
        || fail "current version is missing or stale in ${document_name}"
done

typeset -a discovered_localizations
for localization_path in "${LOCALIZATION_DIRECTORY}"/*.lproj(N); do
    discovered_localizations+=("${${localization_path:t}%.lproj}")
done
typeset -a sorted_discovered_localizations sorted_expected_localizations
sorted_discovered_localizations=("${(@on)discovered_localizations}")
sorted_expected_localizations=("${(@on)EXPECTED_LOCALIZATIONS}")
[[ "${(j: :)sorted_discovered_localizations}" == "${(j: :)sorted_expected_localizations}" ]] \
    || fail "localization directories do not match the release manifest"

mkdir -p "${PROJECT_DIRECTORY}/work"
VALIDATION_TEMPORARY="$(mktemp -d "${PROJECT_DIRECTORY}/work/validation.XXXXXX")"
REFERENCE_KEYS="${VALIDATION_TEMPORARY}/reference-keys.txt"
TEMPORARY_KEYS="${VALIDATION_TEMPORARY}/locale-keys.txt"
cleanup() {
    rm -rf "${VALIDATION_TEMPORARY}"
}
trap cleanup EXIT

for language in "${EXPECTED_LOCALIZATIONS[@]}"; do
    strings_file="${LOCALIZATION_DIRECTORY}/${language}.lproj/Localizable.strings"
    require_file "${strings_file}"
    plutil -lint "${strings_file}" >/dev/null
    sed -n 's/^"\([^"]*\)"[[:space:]]*=.*/\1/p' "${strings_file}" \
        | sort > "${TEMPORARY_KEYS}"
    [[ -s "${TEMPORARY_KEYS}" ]] || fail "no localization keys in ${strings_file}"
    if [[ -n "$(uniq -d "${TEMPORARY_KEYS}")" ]]; then
        fail "duplicate localization key in ${strings_file}"
    fi
    if [[ "${language}" == "ko" ]]; then
        cp "${TEMPORARY_KEYS}" "${REFERENCE_KEYS}"
    elif ! cmp -s "${REFERENCE_KEYS}" "${TEMPORARY_KEYS}"; then
        fail "localization key parity mismatch: ${language} differs from ko"
    fi
done

for resource_name in "${REQUIRED_RESOURCES[@]}"; do
    require_file "${PROJECT_DIRECTORY}/Resources/${resource_name}"
done

for plugin_name in "${EXAMPLE_PLUGIN_NAMES[@]}"; do
    plugin_directory="${PROJECT_DIRECTORY}/Examples/Plugins/${plugin_name}"
    require_file "${plugin_directory}/manifest.json"
    require_file "${plugin_directory}/README.md"
    jq -e . "${plugin_directory}/manifest.json" >/dev/null \
        || fail "invalid JSON manifest: ${plugin_directory}/manifest.json"
done

[[ -s "${PROJECT_DIRECTORY}/Resources/AboutAuthor-SeederPowerDrop-UserProvided.jpg" ]] \
    || fail "About artwork is empty"

if git -C "${PROJECT_DIRECTORY}" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    tracked_junk="$(
        git -C "${PROJECT_DIRECTORY}" ls-files \
            | sed -n -E '/(^|\/)\.DS_Store$|(^|\/)\.build\/|(^|\/)work\/|(^|\/)outputs\//p'
    )"
    [[ -z "${tracked_junk}" ]] || fail "generated files are tracked:\n${tracked_junk}"
fi

mkdir -p \
    "${VALIDATION_TEMPORARY}/module-cache" \
    "${VALIDATION_TEMPORARY}/swiftpm-cache"
env \
    CLANG_MODULE_CACHE_PATH="${VALIDATION_TEMPORARY}/module-cache" \
    SWIFTPM_MODULECACHE_OVERRIDE="${VALIDATION_TEMPORARY}/module-cache" \
    XDG_CACHE_HOME="${VALIDATION_TEMPORARY}/swiftpm-cache" \
    swift package \
        --package-path "${PROJECT_DIRECTORY}" \
        --disable-sandbox \
        dump-package > "${VALIDATION_TEMPORARY}/package.json"
jq -e '
    .name == "EmberPDF"
    and any(.products[]; .name == "EmberPDF" and .targets == ["HwattakPDF"])
    and any(.products[]; .name == "EmberPluginWorker" and .targets == ["EmberPluginWorker"])
    and ([.targets[].name] | sort == ["CEmberPDFRawStreams", "CPDFium", "EmberPluginWorker", "HwattakPDF", "HwattakPDFTests"])
    and any(.targets[]; .name == "HwattakPDF"
        and any(.dependencies[]; .byName[0] == "CEmberPDFRawStreams"))
' "${VALIDATION_TEMPORARY}/package.json" >/dev/null \
    || fail "Swift package must provide EmberPDF and EmberPluginWorker while keeping existing HwattakPDF targets"

# The raw-stream bridge is linked into the app, so its pinned static inputs and
# their upstream notices are release inputs just like the PDFium framework.
QPDF_DIRECTORY="${PROJECT_DIRECTORY}/Vendor/QPDF"
require_file "${PROJECT_DIRECTORY}/Sources/CEmberPDFRawStreams/RawStreams.cpp"
require_file "${PROJECT_DIRECTORY}/Sources/CEmberPDFRawStreams/include/CEmberPDFRawStreams.h"
require_file "${QPDF_DIRECTORY}/build-manifest.json"
for qpdf_input in \
    README.md include/qpdf/QPDF.hh include/qpdf/QPDFObjectHandle.hh \
    lib/macos-arm64/libqpdf.a lib/macos-arm64/libjpeg.a \
    patches/0001-warn-missing-indirect-reference.patch \
    licenses/qpdf-LICENSE.txt licenses/qpdf-NOTICE.md \
    licenses/libjpeg-turbo-LICENSE.md licenses/libjpeg-turbo-README.ijg; do
    require_file "${QPDF_DIRECTORY}/${qpdf_input}"
    [[ -s "${QPDF_DIRECTORY}/${qpdf_input}" ]] || fail "empty qpdf input: ${qpdf_input}"
    jq -e --arg path "${qpdf_input}" '.files[$path] | type == "string" and test("^[0-9a-f]{64}$")' \
        "${QPDF_DIRECTORY}/build-manifest.json" >/dev/null \
        || fail "qpdf input is missing from the build manifest: ${qpdf_input}"
done
jq -e '.architecture == "arm64" and .minimumMacOS == "14.0" and .crypto == "native only"' \
    "${QPDF_DIRECTORY}/build-manifest.json" >/dev/null \
    || fail "qpdf build manifest does not match the supported deployment target"
for archive_name in libqpdf.a libjpeg.a; do
    [[ "$(lipo -archs "${QPDF_DIRECTORY}/lib/macos-arm64/${archive_name}")" == "arm64" ]] \
        || fail "qpdf archive must contain only arm64: ${archive_name}"
done
while IFS=$'\t' read -r relative_path expected_digest; do
    [[ -n "${relative_path}" && "${relative_path}" != /* && "/${relative_path}/" != */../* ]] \
        || fail "unsafe qpdf build manifest path"
    [[ ${#expected_digest} == 64 && "${expected_digest}" != *[^0-9a-f]* ]] \
        || fail "invalid qpdf build manifest digest: ${relative_path}"
    require_file "${QPDF_DIRECTORY}/${relative_path}"
    actual_digest="$(shasum -a 256 "${QPDF_DIRECTORY}/${relative_path}")"
    [[ "${actual_digest%% *}" == "${expected_digest}" ]] \
        || fail "qpdf build input checksum mismatch: ${relative_path}"
done < <(jq -r '.files | to_entries[] | [.key, .value] | @tsv' "${QPDF_DIRECTORY}/build-manifest.json")
zsh -n "${PROJECT_DIRECTORY}/scripts/build_app.sh"
zsh -n "${PROJECT_DIRECTORY}/scripts/prepare_pdfium.sh"
require_file "${PROJECT_DIRECTORY}/Vendor/PDFium/CPDFium.xcframework/Info.plist"
require_file "${PROJECT_DIRECTORY}/Vendor/PDFium/LICENSE"
require_file "${PROJECT_DIRECTORY}/Vendor/PDFium/licenses/pdfium.txt"
zsh -n "${PROJECT_DIRECTORY}/scripts/run_test_batches.sh"
zsh -n "${PROJECT_DIRECTORY}/scripts/validate_plugin.sh"

echo "Static validation passed"
echo "Version ${SHORT_VERSION} (${BUILD_VERSION}), macOS ${MINIMUM_SYSTEM}+"
echo "Localization parity: ${#EXPECTED_LOCALIZATIONS[@]} languages"
