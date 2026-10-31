#!/usr/bin/env python3
"""Focused login regressions: intercepted windows and isolated system actions."""
import os
from pathlib import Path
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parent.parent
TESTS = ROOT / 'macOSApp/Tests/WallpaperControlAppTests'
FILES = ['AutostartManagerTests.swift', 'WallpaperSessionRecoveryTests.swift',
         'UnifiedLoginControlsTests.swift', 'LoginRestorationRegressionTests.swift',
         'UserWallpaperOwnershipTests.swift', 'LockScreenSaverInstallerTests.swift',
         'AerialLockScreenInstallerTests.swift', 'Terminal/TerminalScreenSaverStoreCoordinatorTests.swift',
         'Terminal/TerminalPresentationRecoveryTests.swift']
names = []
for name in FILES:
    names.extend(re.findall(r'^(?:@Test[^\n]* )?func (\w+)\(', (TESTS / name).read_text(), re.M))
names.extend(['HiddenLoginPlaybackTests', 'TerminalLoginRestorationTests',
              'applyingTerminalInheritsApplicationLoginPreference', 'DockRefreshRegressionTests',
              'LockScreenFirstFrameHandoffTests', 'LockScreenPresentationQueueTests', 'nativeBridge',
              'incompleteIsolatedGenerationRecoversWithoutRepeatingProviderRestarts', 'desktopAgentNative'])
names.append('TerminalPresentationRecoveryTests')
names.append('TerminalNativeSurfaceHostingTests')
names.append('TerminalLockScreenRouteTests')
names.append('TerminalAutomaticLockTests')
names.append('TerminalLoginLockIndependenceTests')
names.append('TerminalLockScreenToggleTests')
names.append('TerminalFullscreenRuntimeTests')
names.extend(['terminalDeferred', 'terminalNewAppReplacesAnOldHelperInsteadOfSendingItAnotherRestartCommand',
              'terminalHelperUpgradeDoesNotDropTheSurfaceOfALockedOrPausedSession',
              'terminalStatusPollingPublishesOnlyActualChanges',
              'terminalRuntimeRejectsReusedPIDEvenWhenTheProcessExists',
              'legacyTerminalPIDCannotClaimAnUnrelatedProcessAfterReboot'])
names.extend(['terminalFullscreenPause', 'terminalManualPauseSurvivesFullscreenAndLockTransitions'])
names.extend(['terminalLockScreenPublisherWritesOnlyWhileLocked',
              'terminalLockScreenPublisherThrottlesDesktopSeedAndRestartsGeneration',
              'terminalFallbackFramePacingUsesCaptureStartNotEncodingCompletion',
              'terminalDesktopSeedSettlesPartialStartupWithoutContinuousBackgroundEncoding'])
names.extend(['lockScreenPlaybackToggleStaysResponsiveAndLatestChoiceWins',
              'failedLockScreenPlaybackToggleRestoresConfirmedState',
              'disablingLockScreenRestoresUserRouteAndKeepsDesktopPlayback',
              'disablingLockScreenStopsOnlyDedicatedAgentAndRemembersSelection',
              'reenablingLockScreenAfterDisableReusesSelection',
              'reenablingRunningWallpaperExplicitlyRearmsLockScreen',
              'enablingLockScreenWithoutDesktopStartsDedicatedRuntime',
              'lockScreenCheckboxRoutesToRunningTerminalInsteadOfSavedVideo',
              'lockScreenCheckboxRestoresFlagWhenTerminalCannotPrepareFrame'])
names.extend(['terminalLockScreenOffOnPreservesDesktopProcessAndRefreshesFrame',
              'terminalLockScreenDoesNotActivateWithoutFreshFrame'])
names.append('lockScreenPresentsPublishedFrameBeforeAnimationStartsAndRestoresExpiredRoute')
env = dict(os.environ)
xcode = Path('/Applications/Xcode.app/Contents/Developer')
if xcode.exists():
    env['DEVELOPER_DIR'] = str(xcode)
swift = subprocess.check_output(['xcrun', '--find', 'swift'], env=env, text=True).strip()
sdk = subprocess.check_output(['xcrun', '--sdk', 'macosx', '--show-sdk-path'], env=env, text=True).strip()
result = subprocess.run([swift, 'test', '--package-path', str(ROOT / 'macOSApp'), '--sdk', sdk,
                         '--no-parallel', '--filter', '|'.join(names), '--skip',
                         'terminalDesktopRecoversExistingStaticWindow|terminalDisplayDisappearancePreservesLease'], cwd=ROOT, env=env)
sys.exit(result.returncode)
