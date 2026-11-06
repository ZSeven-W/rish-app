#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
[[ "${RISH_IOS_GUEST_CGI_ENABLED:-}" == 1 ]] || {
  echo 'Release preview tests require RISH_IOS_GUEST_CGI_ENABLED=1' >&2
  exit 1
}
# The GPUI host links the retained native services directly, without CocoaPods.
export IPHONEOS_DEPLOYMENT_TARGET=16.0
cargo rustc --locked --manifest-path apps/gpui/mobile/Cargo.toml \
  --target-dir apps/gpui/mobile/target --target aarch64-apple-ios-sim \
  --release --lib --crate-type staticlib
xcodegen generate --spec apps/gpui/ios/project.yml
vendor=${RISH_GPUI_NATIVE_VENDOR:-"$PWD/modules/rish/ios/Vendor"}
include=${RISH_GPUI_NATIVE_INCLUDE:-"$PWD/modules/rish/ios/include"}
output="$PWD/.build/preview-tests"
mkdir -p "$output"
xcrun simctl list devices available --json > "$output/devices.json"
device=$(python3 - "$output/devices.json" <<'PY'
import json, sys
inventory = json.load(open(sys.argv[1]))['devices']
for runtime, devices in sorted(inventory.items(), reverse=True):
    if '.iOS-' not in runtime:
        continue
    for device in devices:
        if device['name'].startswith('iPhone') and device.get('isAvailable'):
            print(device['udid'])
            sys.exit(0)
raise SystemExit('No available iPhone simulator')
PY
)
xcrun simctl boot "$device" || true
xcrun simctl bootstatus "$device" -b
trap 'xcrun simctl shutdown "$device" >/dev/null 2>&1 || true' EXIT
xcodebuild build-for-testing -project apps/gpui/ios/RishGPUI.xcodeproj \
  -scheme RishGPUI -configuration Release -destination "id=$device" \
  -derivedDataPath "$output/DerivedData" CODE_SIGNING_ALLOWED=NO \
  RISH_GUEST_CGI_ENABLED=1 RISH_NATIVE_VENDOR="$vendor" RISH_NATIVE_INCLUDE="$include" \
  -only-testing:RishTests/RishGuestCgiLiveTests \
  -only-testing:RishTests/AgentGuestCgiAdapterTests \
  -only-testing:RishTests/AgentPolicyTests \
  -only-testing:RishTests/RuntimeProgramTests \
  -only-testing:RishTests/CompletionWriteRevisionTests \
  -only-testing:RishTests/CompletionV2Tests \
  -only-testing:RishTests/DSHCompletionProviderTransportTests \
  -only-testing:RishTests/AgentProviderRoundServiceTests \
  -only-testing:RishTests/AgentNativeStoreTests \
  -only-testing:RishTests/AgentWorkspaceParentTests \
  -only-testing:RishTests/AgentGitIndexPathTests \
  -only-testing:RishTests/CompletionResponseParityTests \
  -only-testing:RishTests/RuntimeEnvironmentOwnershipTests \
  -only-testing:RishTests/RuntimeServiceVMTests \
  -only-testing:RishTests/RuntimeHTTPServerTests \
  -only-testing:RishTests/AgentRuntimeContractTests \
  -only-testing:RishTests/AgentRuntimeExecutorTests \
  -only-testing:RishTests/LocalEnvironmentsOwnedInstallTests \
  -only-testing:RishTests/AgentToolEffectsTests/testNonDirectoryParentRejectsWholeWriteBatchWithoutPartialEffects \
  -only-testing:RishTests/AgentToolEffectsTests/testGuestCgiRealBatchApprovalExecutionAndReplay \
  -only-testing:RishTests/AgentToolEffectsTests/testPlaceholderWriteRevisionsSettleThenRepairCreateReadAndUpdate \
  -only-testing:RishTests/AgentToolEffectsTests/testAWideCharacterPreviewIsClippedByBytesAndDoesNotRaise \
  -only-testing:RishTests/AgentToolEffectsTests/testAPreviewCutAtTheLineBoundStaysMarkedTruncated \
  -only-testing:RishTests/GuestVMOwnershipTests \
  -only-testing:RishTests/RuntimeEnvironmentStoreTests/testManifestRejectsUnsafeIdsAndWrongKernelAndInvalidNumericTypes \
  -only-testing:RishTests/RuntimeEnvironmentStoreTests/testStreamedImportPersistsSelectionAndLeaseCannotMutateOriginalOrBeRemoved \
  -only-testing:RishTests/RuntimeEnvironmentStoreTests/testCatalogSelectionNeedsNoDownloadAndPartialDirectoriesAreIgnoredAfterRestart \
  -only-testing:RishTests/RuntimeEnvironmentStoreTests/testCorruptPackageTrailingStreamAndExpansionPastDeclaredLimitNeverInstall \
  -only-testing:RishTests/RuntimeEnvironmentStoreTests/testOuterCatalogDigestAndSymlinkInputAreRejectedAndCancellationRemovesPartialDisk \
  -only-testing:RishTests/RuntimeEnvironmentStoreTests/testInstalledDiskTamperingIsRejectedBeforeRunLease \
  -only-testing:RishTests/RuntimeEnvironmentStoreTests/testDownloadStreamsOnlyExpectedBytesAndCleansCancellation \
  -only-testing:RishTests/RuntimeEnvironmentStoreTests/testDownloadRefusesAdvertisedSizeMismatchBeforeKeepingBody \
  -only-testing:RishTests/RuntimeEnvironmentStoreTests/testDownloadBoundsUnknownLengthAndRefusesCredentialURLsBeforeOpeningFile \
  -only-testing:RishTests/RuntimeEnvironmentStoreTests/testCancelImportLeavesNoSelectablePartialAndRetryWorks \
  -only-testing:RishTests/RuntimeEnvironmentStoreTests/testDownloadFailureNeverDeletesExistingDestination \
  -only-testing:RishTests/LocalProjectsModuleV2Tests/testEnableGitPreservesExistingWorkspaceFilesAndPublishesNativeGitPolicy \
  -only-testing:RishTests/RishGuestCgiHTTPTests \
  -only-testing:RishTests/SessionSnapshotStoreTests/testProtectionUsesFreshFileAttributesForDirectoryAndFile \
  -only-testing:RishTests/SessionSnapshotStoreTests/testFreshStoreLoadsAsMissingAndFirstCASCommitsV3 \
  -only-testing:RishTests/SessionSnapshotStoreTests/testLoadResultExposesWriterAndCurrentLaunchInstanceIds \
  -only-testing:RishTests/SessionSnapshotStoreTests/testInitAcceptsPrivatePrefixedExistingRootBeforeSessionFileExists \
  -only-testing:RishTests/SessionSnapshotStoreTests/testLegacyV2LoadsWithRawByteTokenAndMigratesOnlyWithThatToken \
  -only-testing:RishTests/SessionSnapshotStoreTests/testProtectionV2CoversRootLockSessionTombstoneAndTemporaryPaths \
  -only-testing:RishTests/SessionSnapshotStoreTests/testV2ProtectionRejectsFreshReadbackLoss \
  -only-testing:RishTests/AgentPreparedAttemptStoreTests/testPrepareCommitsTranscriptAuthorityAndOperationAtomicallyAndReplays \
  -only-testing:RishTests/AgentProviderRoundServiceTests/testFreshWorkspaceSessionCASPreparesAndCompletesRealStoredAgentRound \
  -only-testing:RishTests/AgentProviderRoundServiceTests/testFrozenLegacyRegistryKeepsOriginalProviderWriteSchemas \
  -only-testing:RishTests/AgentProviderRoundServiceTests/testProviderRejectsWrongRegistryVersionBeforeDispatchEvenWithMatchingDigest \
  -only-testing:RishTests/AgentNativeStoreTests/testDeviceMetadataFirstTransactionAndRelaunchPreserveTranscript \
  -only-testing:RishTests/AgentNativeStoreTests/testDeviceMetadataFailuresPreserveCommittedWALBytes \
  -only-testing:RishTests/AgentNativeStoreTests/testDeviceMetadataReadFailureAndInodeSwapNeverReplaceCommittedWAL \
  -only-testing:RishTests/AgentNativeStoreTests/testWALProtectionUsesFreshFileAttributesForDirectoryAndFile \
  -only-testing:RishTests/AgentNativeStoreTests/testCommittedStateIsRereadWhenTheFileIsReplacedBehindTheStore \
  -only-testing:RishTests/AgentRuntimeModuleTests/testRoundPersistenceDiagnosticsExposeOnlyFixedOperationAndKind \
  -only-testing:RishTests/AgentProviderRoundServiceTests/testRoundV3RejectsCreateAndDispatchWhenRealWALWriteFails \
  -only-testing:RishTests/AgentProviderRoundServiceTests/testFreshWorkspaceRoundCreationFailureDoesNotDispatchProvider \
  -only-testing:RishTests/AgentRuntimeModuleTests/testToolDefinitionValidationErrorsAreBadArgumentsWithoutLeakingDescription \
  -only-testing:RishTests/AgentRuntimeModuleTests/testToolDefinitionMappingDoesNotClaimOtherDomainsOrResponseErrors
python3 - "$output/DerivedData/Build/Products" "$PWD/scripts/tests/fixtures/guest-cgi" <<'PY'
import pathlib, plistlib, sys
paths = list(pathlib.Path(sys.argv[1]).glob('*.xctestrun'))
if len(paths) != 1:
    raise SystemExit('Expected one generated xctestrun file')
path = paths[0]
config = plistlib.loads(path.read_bytes())
updated = 0
def visit(value):
    global updated
    if isinstance(value, dict):
        if 'TestBundlePath' in value:
            value.setdefault('EnvironmentVariables', {}).update({
                'RISH_GUEST_CGI_LIVE': '1', 'RISH_GUEST_CGI_FIXTURE_DIR': sys.argv[2],
            })
            updated += 1
        else:
            for child in value.values(): visit(child)
    elif isinstance(value, list):
        for child in value: visit(child)
visit(config)
if not updated: raise SystemExit('No test targets found in xctestrun')
path.write_bytes(plistlib.dumps(config))
PY
plans=("$output"/DerivedData/Build/Products/*.xctestrun)
xcodebuild test-without-building -xctestrun "${plans[0]}" \
  -destination "id=$device" -parallel-testing-enabled NO \
  -resultBundlePath "$output/Preview.xcresult" \
  -only-testing:RishTests/RishGuestCgiLiveTests \
  -only-testing:RishTests/AgentGuestCgiAdapterTests \
  -only-testing:RishTests/AgentPolicyTests \
  -only-testing:RishTests/RuntimeProgramTests \
  -only-testing:RishTests/CompletionWriteRevisionTests \
  -only-testing:RishTests/CompletionV2Tests \
  -only-testing:RishTests/DSHCompletionProviderTransportTests \
  -only-testing:RishTests/AgentProviderRoundServiceTests \
  -only-testing:RishTests/AgentNativeStoreTests \
  -only-testing:RishTests/AgentWorkspaceParentTests \
  -only-testing:RishTests/AgentGitIndexPathTests \
  -only-testing:RishTests/CompletionResponseParityTests \
  -only-testing:RishTests/RuntimeEnvironmentOwnershipTests \
  -only-testing:RishTests/RuntimeServiceVMTests \
  -only-testing:RishTests/RuntimeHTTPServerTests \
  -only-testing:RishTests/AgentRuntimeContractTests \
  -only-testing:RishTests/AgentRuntimeExecutorTests \
  -only-testing:RishTests/LocalEnvironmentsOwnedInstallTests \
  -only-testing:RishTests/AgentToolEffectsTests/testNonDirectoryParentRejectsWholeWriteBatchWithoutPartialEffects \
  -only-testing:RishTests/AgentToolEffectsTests/testGuestCgiRealBatchApprovalExecutionAndReplay \
  -only-testing:RishTests/AgentToolEffectsTests/testPlaceholderWriteRevisionsSettleThenRepairCreateReadAndUpdate \
  -only-testing:RishTests/AgentToolEffectsTests/testAWideCharacterPreviewIsClippedByBytesAndDoesNotRaise \
  -only-testing:RishTests/AgentToolEffectsTests/testAPreviewCutAtTheLineBoundStaysMarkedTruncated \
  -only-testing:RishTests/GuestVMOwnershipTests \
  -only-testing:RishTests/RuntimeEnvironmentStoreTests/testManifestRejectsUnsafeIdsAndWrongKernelAndInvalidNumericTypes \
  -only-testing:RishTests/RuntimeEnvironmentStoreTests/testStreamedImportPersistsSelectionAndLeaseCannotMutateOriginalOrBeRemoved \
  -only-testing:RishTests/RuntimeEnvironmentStoreTests/testCatalogSelectionNeedsNoDownloadAndPartialDirectoriesAreIgnoredAfterRestart \
  -only-testing:RishTests/RuntimeEnvironmentStoreTests/testCorruptPackageTrailingStreamAndExpansionPastDeclaredLimitNeverInstall \
  -only-testing:RishTests/RuntimeEnvironmentStoreTests/testOuterCatalogDigestAndSymlinkInputAreRejectedAndCancellationRemovesPartialDisk \
  -only-testing:RishTests/RuntimeEnvironmentStoreTests/testInstalledDiskTamperingIsRejectedBeforeRunLease \
  -only-testing:RishTests/RuntimeEnvironmentStoreTests/testDownloadStreamsOnlyExpectedBytesAndCleansCancellation \
  -only-testing:RishTests/RuntimeEnvironmentStoreTests/testDownloadRefusesAdvertisedSizeMismatchBeforeKeepingBody \
  -only-testing:RishTests/RuntimeEnvironmentStoreTests/testDownloadBoundsUnknownLengthAndRefusesCredentialURLsBeforeOpeningFile \
  -only-testing:RishTests/RuntimeEnvironmentStoreTests/testCancelImportLeavesNoSelectablePartialAndRetryWorks \
  -only-testing:RishTests/RuntimeEnvironmentStoreTests/testDownloadFailureNeverDeletesExistingDestination \
  -only-testing:RishTests/LocalProjectsModuleV2Tests/testEnableGitPreservesExistingWorkspaceFilesAndPublishesNativeGitPolicy \
  -only-testing:RishTests/RishGuestCgiHTTPTests \
  -only-testing:RishTests/SessionSnapshotStoreTests/testProtectionUsesFreshFileAttributesForDirectoryAndFile \
  -only-testing:RishTests/SessionSnapshotStoreTests/testFreshStoreLoadsAsMissingAndFirstCASCommitsV3 \
  -only-testing:RishTests/SessionSnapshotStoreTests/testLoadResultExposesWriterAndCurrentLaunchInstanceIds \
  -only-testing:RishTests/SessionSnapshotStoreTests/testInitAcceptsPrivatePrefixedExistingRootBeforeSessionFileExists \
  -only-testing:RishTests/SessionSnapshotStoreTests/testLegacyV2LoadsWithRawByteTokenAndMigratesOnlyWithThatToken \
  -only-testing:RishTests/SessionSnapshotStoreTests/testProtectionV2CoversRootLockSessionTombstoneAndTemporaryPaths \
  -only-testing:RishTests/SessionSnapshotStoreTests/testV2ProtectionRejectsFreshReadbackLoss \
  -only-testing:RishTests/AgentPreparedAttemptStoreTests/testPrepareCommitsTranscriptAuthorityAndOperationAtomicallyAndReplays \
  -only-testing:RishTests/AgentProviderRoundServiceTests/testFreshWorkspaceSessionCASPreparesAndCompletesRealStoredAgentRound \
  -only-testing:RishTests/AgentProviderRoundServiceTests/testFrozenLegacyRegistryKeepsOriginalProviderWriteSchemas \
  -only-testing:RishTests/AgentProviderRoundServiceTests/testProviderRejectsWrongRegistryVersionBeforeDispatchEvenWithMatchingDigest \
  -only-testing:RishTests/AgentNativeStoreTests/testDeviceMetadataFirstTransactionAndRelaunchPreserveTranscript \
  -only-testing:RishTests/AgentNativeStoreTests/testDeviceMetadataFailuresPreserveCommittedWALBytes \
  -only-testing:RishTests/AgentNativeStoreTests/testDeviceMetadataReadFailureAndInodeSwapNeverReplaceCommittedWAL \
  -only-testing:RishTests/AgentNativeStoreTests/testWALProtectionUsesFreshFileAttributesForDirectoryAndFile \
  -only-testing:RishTests/AgentNativeStoreTests/testCommittedStateIsRereadWhenTheFileIsReplacedBehindTheStore \
  -only-testing:RishTests/AgentRuntimeModuleTests/testRoundPersistenceDiagnosticsExposeOnlyFixedOperationAndKind \
  -only-testing:RishTests/AgentProviderRoundServiceTests/testRoundV3RejectsCreateAndDispatchWhenRealWALWriteFails \
  -only-testing:RishTests/AgentProviderRoundServiceTests/testFreshWorkspaceRoundCreationFailureDoesNotDispatchProvider \
  -only-testing:RishTests/AgentRuntimeModuleTests/testToolDefinitionValidationErrorsAreBadArgumentsWithoutLeakingDescription \
  -only-testing:RishTests/AgentRuntimeModuleTests/testToolDefinitionMappingDoesNotClaimOtherDomainsOrResponseErrors
xcrun xcresulttool get test-results tests --path "$output/Preview.xcresult" --compact > "$output/tests.json"
python3 - "$output/tests.json" <<'PY'
import json, sys
nodes = json.load(open(sys.argv[1]))['testNodes']
required = {
    'testFrozenLegacyRegistryKeepsOriginalProviderWriteSchemas',
    'testProviderRejectsWrongRegistryVersionBeforeDispatchEvenWithMatchingDigest',
    'testBunCompatibilityIsBoundToAuditedDiskAndKeepsLiteralArgv',
    'testAWideCharacterPreviewIsClippedByBytesAndDoesNotRaise',
    'testAPreviewCutAtTheLineBoundStaysMarkedTruncated',
    'testPublicModuleCancelsLongRuntimeProgramBeforeCoordinatorCAS',
    'testPublicModuleCancelsServiceStartupBeforeCoordinatorCAS',
    'testServiceFromPriorAttemptCanBeStoppedOnlyBySameConversationRoot',
    'testEncodedControlCharacterFeedbackStaysWithinCanonicalBudget',
    'testActiveServiceCanStopAtUnconfirmedReceiptCapacity',
    'testBusyRefusalCleanupCannotCancelAnAgentDownload',
    'testOldCleanupCannotCancelANewerManualInstallation',
    'testNonDirectoryParentRejectsWholeWriteBatchWithoutPartialEffects',
    'testGuestCgiRealBatchApprovalExecutionAndReplay',
    'testPlaceholderWriteRevisionsSettleThenRepairCreateReadAndUpdate',
    'testProtectedTranscriptReopensWithPlaceholderAndOpaqueWriteRevisions',
    'testPrepareIsReadOnlyAndApprovedWriteCreatesNestedParents',
    'testTwoPreparedWritesCanShareMissingParents',
    'testCrashAfterMkdirWithoutFileRemainsAmbiguousAndRecoveryIsReadOnly',
    'testRetiredAgentTokenCannotCancelTheNextManualDownload',
    'testCachedInstallDoesNotDownloadOrOwnAnUnrelatedTransfer',
    'testCancellationFromAnotherThreadWakesTheIdleService',
    'testLoopbackForwardsGETQueryBinaryStatusAndRepeatedSetCookieHeaders',
    'testPOSTRequiresSameOriginCookieAndForwardsBinaryBody',
    'testStopClosesPendingRequestAndLateCallbackCannotWriteAfterRestart',
    'testNativeRegistryVersionThreeExposesActualRuntimeToolsAndNullableWriteRevision',
    'testPreviousRegistryDigestsStillValidateWithoutAdmittingRuntimeTools',
    'testNativeRuntimeValidationUsesCoreForArgumentsAndDiagnosticFeedback',
    'testStreamedImportPersistsSelectionAndLeaseCannotMutateOriginalOrBeRemoved',
    'testCorruptPackageTrailingStreamAndExpansionPastDeclaredLimitNeverInstall',
    'testForegroundRunCancellationDoesNotReportStoppedBeforeWorkerReturns',
    'testRootIsRevalidatedAfterSlowEnvironmentCopyBeforeBoot',
    'testOnlyOneConcurrentReservationWinsAndWrongOwnerCannotRelease',
    'testOptInRealGuestCgiCounterOverLoopback',
    'testDescribeRealWorkspaceKeepsRegistryAndChatStorageUntouched',
    'testDescribeRevalidatesBindingAndDoesNotSubstituteAnotherRoot',
    'testEnableGitPreservesExistingWorkspaceFilesAndPublishesNativeGitPolicy',
    'testHTTPClientHonorsWholeRequestDeadlineAndRejectsTruncation',
    'testProtectionUsesFreshFileAttributesForDirectoryAndFile',
    'testFreshStoreLoadsAsMissingAndFirstCASCommitsV3',
    'testLoadResultExposesWriterAndCurrentLaunchInstanceIds',
    'testInitAcceptsPrivatePrefixedExistingRootBeforeSessionFileExists',
    'testLegacyV2LoadsWithRawByteTokenAndMigratesOnlyWithThatToken',
    'testProtectionV2CoversRootLockSessionTombstoneAndTemporaryPaths',
    'testV2ProtectionRejectsFreshReadbackLoss',
    'testPrepareCommitsTranscriptAuthorityAndOperationAtomicallyAndReplays',
    'testFreshWorkspaceSessionCASPreparesAndCompletesRealStoredAgentRound',
    'testDeviceMetadataFirstTransactionAndRelaunchPreserveTranscript',
    'testDeviceMetadataFailuresPreserveCommittedWALBytes',
    'testDeviceMetadataReadFailureAndInodeSwapNeverReplaceCommittedWAL',
    'testWALProtectionUsesFreshFileAttributesForDirectoryAndFile',
    'testCommittedStateIsRereadWhenTheFileIsReplacedBehindTheStore',
    'testRoundPersistenceDiagnosticsExposeOnlyFixedOperationAndKind',
    'testRoundV3RejectsCreateAndDispatchWhenRealWALWriteFails',
    'testFreshWorkspaceRoundCreationFailureDoesNotDispatchProvider',
    'testToolDefinitionValidationErrorsAreBadArgumentsWithoutLeakingDescription',
    'testToolDefinitionMappingDoesNotClaimOtherDomainsOrResponseErrors',
}
found = {name: [] for name in required}
def visit(node):
    if node.get('nodeType') == 'Test Case':
        for name in required:
            if name in node.get('name', ''):
                found[name].append(node.get('result'))
    for child in node.get('children', []): visit(child)
for node in nodes: visit(node)
if any(results != ['Passed'] for results in found.values()):
    raise SystemExit(f'Release service and storage tests must run and pass; observed: {found}')
print('Release guest preview, session storage, and real agent persistence tests passed.')
PY
