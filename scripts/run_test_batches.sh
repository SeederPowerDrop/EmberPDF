#!/bin/zsh

set -euo pipefail

SCRIPT_DIRECTORY="${0:A:h}"
PROJECT_DIRECTORY="${SCRIPT_DIRECTORY:h}"
TEST_DIRECTORY="${PROJECT_DIRECTORY}/Tests/HwattakPDFTests"

typeset -a presentation_tests=(
    AboutContentTests
    AppAppearanceTests
    PDFNativeRenderingAvailabilityTests
    PDFReadingThemeTests
    AppEditCommandRouterTests
    AppExternalFileOpenCoordinatorTests
    AppFileCommandRouterTests
    AppMenuRegistrationTests
    AIAssistantWindowPresentationTests
    DefaultPDFApplicationTests
    HelpTutorialContentTests
    LocalizationAndIconSettingsTests
    OCRExportDestinationTests
    OCRLanguageTests
    OCRPageSelectionTests
    PDFComparisonConfigurationTests
    PDFComparisonDragSessionTests
    PDFComparisonGeometryTests
    PDFComparisonSplitTests
    PDFExportPermissionPresentationTests
    PDFGridLayoutModeTests
    PDFGridPagingEdgeCaseTests
    PDFMainPageNavigationTests
    PDFPageDisplayRangeTests
    PDFPageDragPayloadTests
    PDFPageFitModeTests
    PDFPageJumpRequestTests
    PDFShareNoteTests
    PDFSearchScrollPolicyTests
    PDFViewportScrollInteractionTests
    PageScrollHUDStateTests
    PageSidebarKeyboardNavigationTests
    PageSidebarLayoutModeTests
    ResourceMonitorTests
    SearchNavigatorPresentationTests
    SignatureCaptureConfigurationTests
)

typeset -a document_tests=(
    PDFBodyGeneratedNativeDonorTests
    PDFBodyTextResultOwnerTests
    PDFBodyTextHanSpacingTests
    PDFBodyTextInferredSpacingTests
    PDFBodySourceSpacingTests
    PDFBodyTextFitDiagnosticsTests
    PDFBodyTextColdDeclaredBoundsTests
    PDFBodyTextOriginalGlyphInkTests
    PDFBodyTextNativeFormClearanceTests
    PDFGlyphOutlineIdentityTests
    PDFBodyEditedTagPreserverTests
    PDFBodyEditedAnnotationTagTests
    PDFBodyLeadingSpaceDrawingTests
    PDFBodyLeadingWhitespaceTests
    PDFBodyTextDeclaredExtentTests
    PDFBodyTextExtentCompatibilityTests
    PDFBodyTextFactoryAuthorityTests
    PDFCatalogSelectedPreparationTests
    PDFDetachedTagForestPreservationTests
    PDFEmptyAcroFormPreservationTests
    PDFGeneratedDonorTextNormalizerTests
    PDFIndexedNativeCopyTests
    PDFInertOutlineParentTests
    PDFInkCGMatchingFractionalTests
    PDFInkGeometryEditPriorityTests
    PDFInkNamePreservationTests
    PDFNativeStagingRealCorpusTests
    PDFNativeStagingWriterTests
    PDFOriginalInkNumberTests
    PDFOriginalResourceNumberTests
    PDFRawFlateBlankProofTests
    PDFSearchDebounceTests
    PDFSparseParentArraySerializationTests
    PDFStagedInheritedResourceTests
    PDFStoredNavigationMetadataTests
    PDFUnnamedSignatureConversionTests
    PDFWidgetEncodedAppearanceTests
    PDFReferenceIdentityTests
    PDFExternalValidationFixtureTests
    PDFCanonicalFormMaterializerTests
    PDFWidgetAppearancePreserverTests
    PDFWidgetAppearanceCacheTests
    PDFPrivateSnapshotDefaultProofTests
    PDFAnnotationRelationshipPreserverTests
    PDFBackgroundExportTests
    PDFCatalogPageMetadataPreserverTests
    PDFCatalogNameTreeLimitsTests
    PDFCatalogOutputIntentScopeTests
    PDFEmbeddedFileNameEncodingTests
    PDFCatalogSaveOptionsTests
    PDFCatalogReorderedPagePreservationTests
    PDFCatalogAnnotationLineageTests
    PDFCatalogGeometryPreservationTests
    PDFCatalogEditedPagePreservationTests
    PDFCatalogImageResourcePrunerTests
    PDFAssemblyImageResourcePruningTests
    PDFOptionalContentPreserverTests
    PDFTaggedStructurePreserverTests
    PDFTaggedParentTreeRepairTests
    PDFSparseParentTreeTests
    PDFTaggedFormResourcePreservationTests
    PDFSerializationCrossReferenceRepairTests
    PDFDocumentDifferenceCorpusTests
    PDFPageStructurePreserverTests
    PDFNativeNavigationPreservationTests
    PDFPageStructureRealFileTests
    DocumentConversionTests
    DocumentStabilizationTests
    AdvancedStabilizationTests
    HTMLPDFConversionTests
    InlineTextEditingTests
    InlineTextHorizontalScaleTests
    PDFBodyTextAttributedLayoutTests
    PDFBodyTextMultiEditStyleTests
    PDFContentStreamBoundaryTests
    PDFBodyTextInlineMaskTests
    PDFBodyTextLineSpacingTests
    PDFBodyTextTightLeadingTests
    PDFBodyTextSavePreservationTests
    PDFBodyTextParagraphTests
    PDFBodyTextTaggedBlockTests
    PDFScannedBodyTextEditorTests
    PDFScannedBodyTextSafetyTests
    PDFScannedBodyTextRecognitionGeometryTests
    PDFScannedContentStreamTests
    PDFOutlinedOCRSnapshotTests
    PDFScannedReadOrderContentTests
    PDFOutlinedOCRMetadataTests
    PDFOutlinedOCRArtworkTests
    PDFBodyTextOutlinedRenderingTests
    PDFBodyTextReadOrderSourceRowsTests
    PDFBodyTextInertSpaceTests
    PDFBodyTextRootInertSpaceTests
    PDFDecimalNumberTests
    PDFInlineTextEditorVisibilityTests
    PDFBodyTextEditorTests
    PDFBodyTextSourcePreservationTests
    PDFBodyTextSelectionTests
    PDFBodyTextWorkspaceTests
    PDFBodyTextLifecycleTests
    PDFBodyTextFileSizeTests
    PDFBodyTextPositionTests
    PDFBodyTextGeneratedSpaceTests
    PDFBodyTextContentStreamTests
    PDFBodyTextLosslessTests
    PDFBodyTextPageSnapshotTests
    PDFBodyTextDirectSaveTests
    PDFBodyTextContentTemplateTests
    PDFRawStreamSourceTests
    PDFRawEmptyPageProofTests
    PDFThumbnailPaintingCacheTests
    PDFBodyTextStreamCompressionTests
    PDFMonochromeImageEncoderTests
    PDFBodyTextDocumentGraphTests
    PDFBodyTextOutlineGraphIdentityTests
    PDFBodyTextCIDFontSafetyTests
    PDFBodyTextRepeatedLineTests
    PDFBodyTextViewportTests
    PDFInlineTextBaselineTests
    PDFImageFileSizeTests
    JPEGImagePreservationTests
    PDFOriginalJPEGTests
    ImageInsertionOptionsTests
    ImageInsertionApprovalTests
    ImageStampGeometryTests
    InkPresetStoreTests
    PDFCompressionServiceTests
    PDFCompressionPresentationTests
    PDFCompressionWorkspaceTests
    PDFCompressionSheetVisualTests
    PDFMergeFileSizeTests
    PDFAnnotationPrivacyTests
    PDFDocumentSearchTests
    PDFSearchHitGeometryTests
    PDFEditHistoryTests
    PDFEraserGestureTests
    PDFExternalModificationConflictTests
    PDFPageOperationsTests
    PDFOfficeBoundsTests
    PDFOCRApplicationTests
    OCRRecognitionGateTests
    OCRExportSaveTests
    OCRTextRepairTests
    OCRPartialExportTests
    OCRPageScopeWorkspaceTests
    PDFRegionTextSelectionTests
    PDFSelectionPreviewTests
    PDFNativeSelectionProxyTests
    PDFNativeTextLayoutTests
    PDFInkCompositingTests
    PDFInkDrawingOptionsTests
    PDFInkInputBufferTests
    PDFInkPartialEraserTests
    PDFInkStyleTests
    PDFVisualTextDragTests
    PageThumbnailRenderingTests
    PDFThumbnailBackgroundRenderingTests
    PressureInkCopyTests
    RecoverySchedulingTests
    RecoverySnapshotIsolationTests
    RecoveryCatalogPreservationTests
    PDFSecurityTests
    PDFWorkspaceSafetyTests
    SecureSignatureStoreTests
    StudyLinkStoreTests
    StudyLinkTargetCatalogTests
    StudyLinkTextSearchTests
    StudyNoteDraftInsertionTests
    StudyNoteStyleTests
    StudyNoteVisibilityTests
    StudyNotesPerformanceTests
    StudyUnderlineRenderingTests
    WorkspaceSaveCoordinatorTests
    PDFSaveDurabilityTests
    PDFBodyTextOutlineDestinationTests
    PDFRemoteNavigationPreserverTests
)

# ImageAnnotationEditingTests drives a real PDFView through live AppKit mouse
# gestures. PDFKit leaves process-global field-editor state behind on headless
# hosts, which can terminate a later AcroForm test even though both classes pass
# alone. Give each interaction-heavy class its own xctest process; this is the
# same containment strategy already used between the larger batches below.
typeset -a image_interaction_tests=(
    ImageAnnotationEditingTests
    PDFBodyTextInteractionTests
)

# Region selection yields to MainActor while live PDFViews are mounted. Even
# different methods in these classes can flush stale offscreen PDFKit tile surfaces
# on macOS 15, so the runner below gives each method its own test process.
typeset -a region_interaction_tests=(
    PDFCollapsedNativeSelectionTests
    PDFRegionSelectionInteractionTests
    PDFNativeSelectionPreviewTests
    PDFSelectionOverlayGeometryTests
    PDFVisualSelectionRealFileTests
    PDFSelectionResponsivenessProfileTests
    PDFDirectTextEditingInteractionTests
    PDFBodyTextFocusScrollTests
    PDFScannedBodyTextInteractionTests
    PDFStadiumBodyTextInteractionTests
    PDFComparisonDisplayTests
    PDFComparisonScrollSyncTests
    PDFComparisonTeardownTests
    PDFInkAnnotationGeometryTests
    PDFInkGestureSettingsTests
    PDFInkPointerInteractionTests
    StudyNoteSelectionContinuityTests
)

# Native window and WebKit tests each get a fresh process. Class filters avoid
# assuming that a test class has its own identically named source file.
typeset -a isolated_ui_tests=(
    LiveLocalizationMenuHistoryTests
    AsyncPDFSaveTests
    AsyncWorkspaceSaveCoordinatorTests
    PDFBackgroundSaveWriterTests
    PDFDocumentDifferenceTests
    AboutWindowChromeTests
    PDFIntegrationLocalizationTests
    WorkspaceLiveLocalizationTests
    WritingToolsVisualTests
    AIAssistantRichTextWebTests
)

# Native AcroForm tests also construct live PDFView/field-editor hierarchies.
# Keep them out of the document batch so process-global PDFKit editor state from
# unrelated classes cannot terminate the host before assertions complete.
typeset -a native_form_interaction_tests=(
    PDFNativeFormInputBoundaryTests
)

# Held-key navigation uses AppKit windows, event monitors and live PDFView
# hierarchies. Isolate their lifetime from the AcroForm and document batches.
typeset -a keyboard_interaction_tests=(
    PDFArrowKeyRepeaterTests
    PDFKeyboardNavigationInteractionTests
)

# Search decoration observes live scrolling and asynchronous result delivery.
# Keep its hosted PDFView lifetime separate from other native interaction tests.
typeset -a search_interaction_tests=(
    PDFSearchScrollControllerTests
)

# Native SwiftUI search fields use the AppKit field editor and real key events.
# Mount them in a fresh process rather than inheriting PDFKit's global editor
# state from the broad presentation or search-decoration batches.
typeset -a search_toolbar_interaction_tests=(
    SearchToolbarInteractionTests
)

# Reading effects exercise live PDFViews, forms and Core Image composition.
# Keep PDFKit's process-global view state out of the search interaction batch.
typeset -a reading_interaction_tests=(
    PDFReadingDisplayTests
    RealPDFResponsivenessTests
    PDFCompactSpreadTests
    PDFCompactSpreadInteractionTests
    PDFCompactSpreadRealFileTests
)

typeset -a workspace_tests=(
    ComparisonBackgroundOpenTests
    ComparisonChooserTests
    MultiDocumentEncryptedBatchTests
    MultiDocumentWorkspaceStateTests
    PDFDocumentGalleryPreviewTests
    PDFComparisonMembershipTests
    PDFPageGalleryTests
    PDFGallerySearchTests
    PDFGalleryNavigationTests
    PDFGallerySearchPreviewTests
    PDFTabGroupTests
    PDFTabMemoryManagerTests
    PDFWorkspaceModeTests
    RealPDFStressTests
    RecentDocumentsStoreTests
    WorkspaceChangeCoalescingTests
    WorkspaceIdlePersistenceTests
    WorkspaceSessionStoreTests
    RecoveryLifecycleTests
)

typeset -a assistant_tests=(
    AIAssistantMarkupTests
    AIAssistantMathFormatterTests
    AIAssistantPageSelectionTests
    AIAssistantRichTextDocumentTests
    AIAssistantSessionModelTests
    AIProviderServiceTests
    AIKeychainPromptPolicyTests
    AIProviderCredentialReplacementTests
    AIConversationHistoryTests
    AIResponseImageTests
    LegacyKeychainPromptNameMigrationTests
    PDFAIContextAndRelatedSearchTests
)

typeset -a plugin_tests=(
    PageTranslationTests
    PageTranslationLayoutTests
    PageTranslationExportPolicyTests
    LocalTranslationServiceTests
    PluginScriptSessionTests
    PluginRuntimeManifestTests
    PluginExtensionHostTests
    PluginScriptStorageTests
    PluginScriptHostAPITests
    PluginPackageBoundaryTests
    PluginPermissionTests
    PluginNotesTests
    PluginPageClipTests
    PluginFoundationTests
    PluginSystemTests
    PluginAuthoringTests
    PluginWebURLPolicyTests
    PDFPermissionBoundaryTests
)

typeset -A listed_classes
for class_name in \
    "${presentation_tests[@]}" \
    "${image_interaction_tests[@]}" \
    "${region_interaction_tests[@]}" \
    "${isolated_ui_tests[@]}" \
    "${native_form_interaction_tests[@]}" \
    "${keyboard_interaction_tests[@]}" \
    "${search_interaction_tests[@]}" \
    "${search_toolbar_interaction_tests[@]}" \
    "${reading_interaction_tests[@]}" \
    "${document_tests[@]}" \
    "${workspace_tests[@]}" \
    "${assistant_tests[@]}" \
    "${plugin_tests[@]}"
do
    [[ -z "${listed_classes[${class_name}]-}" ]] \
        || { echo "Duplicate test class in batch manifest: ${class_name}" >&2; exit 1; }
    listed_classes[${class_name}]=1
done

typeset -a discovered_classes
discovered_classes=("${(@f)$(
    sed -n -E 's/^final class ([A-Za-z0-9_]+Tests).*$/\1/p' \
        "${TEST_DIRECTORY}"/*.swift | sort -u
)}")

for class_name in "${discovered_classes[@]}"; do
    [[ -n "${listed_classes[${class_name}]-}" ]] \
        || { echo "Unbatched test class: ${class_name}" >&2; exit 1; }
done
[[ "${#discovered_classes[@]}" -eq "${#listed_classes[@]}" ]] \
    || { echo "Batch manifest contains a missing test class" >&2; exit 1; }

mkdir -p "${PROJECT_DIRECTORY}/work"
if [[ -n "${HWATTAK_TEST_WORK_DIRECTORY:-}" ]]; then
    # Keep an explicitly chosen work directory for reproducing host failures
    # without recompiling the whole app. SwiftPM still rebuilds changed inputs.
    TEST_TEMPORARY="${HWATTAK_TEST_WORK_DIRECTORY:A}"
    mkdir -p "${TEST_TEMPORARY}"
else
    TEST_TEMPORARY="$(mktemp -d "${PROJECT_DIRECTORY}/work/test-batches.XXXXXX")"
fi
TEST_HELPER_LINK=""
TEST_HELPER_PARENT_CREATED=0
cleanup() {
    if [[ -n "${TEST_HELPER_LINK}" && -L "${TEST_HELPER_LINK}" \
        && "$(readlink "${TEST_HELPER_LINK}")" == "${BUILD_PATH}/debug/EmberPluginWorker" ]]; then
        rm "${TEST_HELPER_LINK}"
    fi
    if [[ "${TEST_HELPER_PARENT_CREATED}" == "1" ]]; then
        rmdir "${PROJECT_DIRECTORY}/.build/debug" 2>/dev/null || true
        rmdir "${PROJECT_DIRECTORY}/.build" 2>/dev/null || true
    fi
    if [[ -z "${HWATTAK_TEST_WORK_DIRECTORY:-}" ]]; then
        rm -rf "${TEST_TEMPORARY}"
    fi
}
trap cleanup EXIT

# A local integration run may reuse an already compiled package to avoid
# duplicating gigabytes of disposable Swift output on a nearly full disk.
# CI keeps the fresh, isolated default. SKIP_BUILD requires that the caller has
# just successfully compiled the current sources into the selected build path.
BUILD_PATH="${HWATTAK_TEST_BUILD_PATH:-${TEST_TEMPORARY}/build}"
MODULE_CACHE="${TEST_TEMPORARY}/module-cache"
SWIFTPM_CACHE="${TEST_TEMPORARY}/swiftpm-cache"
mkdir -p "${BUILD_PATH}" "${MODULE_CACHE}" "${SWIFTPM_CACHE}"
TEST_PROCESS_COUNT=0

run_batch() {
    local name="$1"
    shift
    local selector
    local -a selectors=()
    for selector in "$@"; do
        if [[ "${selector}" == */* ]]; then
            selectors+=("${selector}")
        else
            selectors+=("^HwattakPDFTests[.]${selector}/")
        fi
    done
    local filter="${(j:|:)selectors}"
    local -a arguments=(
        --package-path "${PROJECT_DIRECTORY}"
        --scratch-path "${BUILD_PATH}"
        --disable-sandbox
        --filter "${filter}"
    )
    if [[ "${name}" != "presentation" || "${HWATTAK_TEST_SKIP_BUILD:-0}" == "1" ]]; then
        arguments+=(--skip-build)
    fi
    TEST_PROCESS_COUNT=$((TEST_PROCESS_COUNT + 1))
    echo "Running test batch: ${name}"
    env \
        CLANG_MODULE_CACHE_PATH="${MODULE_CACHE}" \
        SWIFTPM_MODULECACHE_OVERRIDE="${MODULE_CACHE}" \
        XDG_CACHE_HOME="${SWIFTPM_CACHE}" \
        swift test "${arguments[@]}" | tee "${TEST_TEMPORARY}/last-batch.log"
    if [[ "${name}" == region-interaction:* ]]; then
        grep -Eq 'Executed 1 test,.*0 failures' "${TEST_TEMPORARY}/last-batch.log" \
            || { echo "Region interaction filter did not run exactly one test: ${filter}" >&2; exit 1; }
    fi
}

run_region_interactions() {
    local class_name test_name
    local -a test_names
    for class_name in "${region_interaction_tests[@]}"; do
        test_names=("${(@f)$(
            sed -n -E 's/^    func (test[A-Za-z0-9_]+)\(.*/\1/p' \
                "${TEST_DIRECTORY}/${class_name}.swift"
        )}")
        (( ${#test_names[@]} > 0 )) \
            || { echo "No region interaction tests discovered: ${class_name}" >&2; exit 1; }
        for test_name in "${test_names[@]}"; do
            run_batch "region-interaction: ${test_name}" "^HwattakPDFTests[.]${class_name}/${test_name}$"
        done
    done
}

# Each batch gets its own xctest process. This contains PDFKit/AppKit host
# lifetime issues while sharing one deterministic compile output.
run_batch presentation "${presentation_tests[@]}"
# The debug helper locator uses the package's conventional .build/debug path.
# A scratch-path test build must expose that exact worker without overwriting
# an existing build. Remove only our own temporary link when the run ends.
if [[ ! -x "${PROJECT_DIRECTORY}/.build/debug/EmberPluginWorker" ]]; then
    [[ -x "${BUILD_PATH}/debug/EmberPluginWorker" ]] \
        || { echo "Missing compiled plugin worker in ${BUILD_PATH}" >&2; exit 1; }
    [[ ! -e "${PROJECT_DIRECTORY}/.build/debug/EmberPluginWorker" && ! -L "${PROJECT_DIRECTORY}/.build/debug/EmberPluginWorker" ]] \
        || { echo "Existing plugin worker is not executable" >&2; exit 1; }
    [[ -d "${PROJECT_DIRECTORY}/.build/debug" ]] || TEST_HELPER_PARENT_CREATED=1
    mkdir -p "${PROJECT_DIRECTORY}/.build/debug"
    TEST_HELPER_LINK="${PROJECT_DIRECTORY}/.build/debug/EmberPluginWorker"
    ln -s "${BUILD_PATH}/debug/EmberPluginWorker" "${TEST_HELPER_LINK}"
fi
for class_name in "${image_interaction_tests[@]}"; do
    run_batch "image-interaction: ${class_name}" "^HwattakPDFTests[.]${class_name}/"
done
run_region_interactions
for class_name in "${isolated_ui_tests[@]}"; do
    run_batch "isolated-ui: ${class_name}" "^HwattakPDFTests[.]${class_name}/"
done
run_batch native-form-interaction "${native_form_interaction_tests[@]}"
run_batch keyboard-interaction "${keyboard_interaction_tests[@]}"
run_batch search-interaction "${search_interaction_tests[@]}"
run_batch search-toolbar-interaction "${search_toolbar_interaction_tests[@]}"
run_batch reading-interaction "${reading_interaction_tests[@]}"
run_batch document "${document_tests[@]}"
run_batch workspace "${workspace_tests[@]}"
run_batch assistant "${assistant_tests[@]}"
run_batch plugins "${plugin_tests[@]}"

echo "All ${#discovered_classes[@]} test classes passed (${TEST_PROCESS_COUNT} isolated test processes)"
