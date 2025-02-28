import Foundation
import UIKit
import Postbox
import TelegramCore
import Display
import SwiftSignalKit
import MonotonicTime
import AccountContext
import TelegramPresentationData
import PasscodeUI
import TelegramUIPreferences
import ImageBlur
import FastBlur
import AppLockState

private func isLocked(passcodeSettings: PresentationPasscodeSettings, state: LockState, isApplicationActive: Bool) -> Bool {
    if state.isManuallyLocked {
        return true
    } else if let autolockTimeout = passcodeSettings.autolockTimeout {
        var bootTimestamp: Int32 = 0
        let uptime = getDeviceUptimeSeconds(&bootTimestamp)
        let timestamp = MonotonicTimestamp(bootTimestamp: bootTimestamp, uptime: uptime)
        
        let applicationActivityTimestamp = state.applicationActivityTimestamp
        
        if let applicationActivityTimestamp = applicationActivityTimestamp {
            if timestamp.bootTimestamp != applicationActivityTimestamp.bootTimestamp {
                return true
            }
            if timestamp.uptime >= applicationActivityTimestamp.uptime + autolockTimeout {
                return true
            }
        } else {
            return true
        }
    }
    return false
}

// MARK: Postufgram Code: {
private func getPublicCoveringViewSnapshot(window: Window1) -> UIImage? {
    let scale: CGFloat = 0.5
    let unscaledSize = window.hostView.containerView.frame.size
    
    return generateImage(CGSize(width: floor(unscaledSize.width * scale), height: floor(unscaledSize.height * scale)), rotatedContext: { size, context in
        context.clear(CGRect(origin: CGPoint(), size: size))
        context.scaleBy(x: scale, y: scale)
        UIGraphicsPushContext(context)
        window.forEachViewController { controller in
            if let tabBarController = controller as? TabBarController {
                tabBarController.controllers.forEach { controller in
                    if let controller = controller as? ChatListController {
                        controller.view.drawHierarchy(in: CGRect(origin: CGPoint(), size: unscaledSize), afterScreenUpdates: false)
                    }
                }
            }
            return true
        }
        UIGraphicsPopContext()
    }).flatMap(applyScreenshotEffectToImage)
}
// MARK: Postufgram Code: }

private func getCoveringViewSnaphot(window: Window1) -> UIImage? {
    let scale: CGFloat = 0.5
    let unscaledSize = window.hostView.containerView.frame.size
    return generateImage(CGSize(width: floor(unscaledSize.width * scale), height: floor(unscaledSize.height * scale)), rotatedContext: { size, context in
        context.clear(CGRect(origin: CGPoint(), size: size))
        context.scaleBy(x: scale, y: scale)
        UIGraphicsPushContext(context)
        window.forEachViewController({ controller in
            if let controller = controller as? PasscodeEntryController {
                controller.displayNode.alpha = 0.0
            }
            return true
        })
        window.hostView.containerView.drawHierarchy(in: CGRect(origin: CGPoint(), size: unscaledSize), afterScreenUpdates: false)
        window.forEachViewController({ controller in
            if let controller = controller as? PasscodeEntryController {
                controller.displayNode.alpha = 1.0
            }
            return true
        })
        UIGraphicsPopContext()
    }).flatMap(applyScreenshotEffectToImage)
}

public final class AppLockContextImpl: AppLockContext {
    private let rootPath: String
    private let syncQueue = Queue()
    
    private let applicationBindings: TelegramApplicationBindings
    private let accountManager: AccountManager<TelegramAccountManagerTypes>
    private let presentationDataSignal: Signal<PresentationData, NoError>
    private let window: Window1?
    private let rootController: UIViewController?
    
    // MARK: Postufgram Code: {
    private var snapshotView: LockedWindowCoveringView?
    // MARK: Postufgram Code: }
    private var coveringView: LockedWindowCoveringView?
    private var passcodeController: PasscodeEntryController?
    
    private var timestampRenewTimer: SwiftSignalKit.Timer?
    
    private var currentStateValue: LockState
    private let currentState = Promise<LockState>()
    
    private let autolockTimeout = ValuePromise<Int32?>(nil, ignoreRepeated: true)
    private let autolockReportTimeout = ValuePromise<Int32?>(nil, ignoreRepeated: true)
    
    private let isCurrentlyLockedPromise = Promise<Bool>()
    public var isCurrentlyLocked: Signal<Bool, NoError> {
        return self.isCurrentlyLockedPromise.get()
        |> distinctUntilChanged
    }
    
    private var lastActiveTimestamp: Double?
    private var lastActiveValue: Bool = false
    // MARK: Postufgram Code: {
    private var isCurrentAccountHidden = false
    
    private let checkCurrentAccountDisposable = MetaDisposable()
    private var hiddenAccountsAccessChallengeDataDisposable: Disposable?
    public private(set) var hiddenAccountsAccessChallengeData = [AccountRecordId:PostboxAccessChallengeData]()

    private var applicationInForegroundDisposable: Disposable?
    
    public var lockingIsCompletePromise = Promise<Bool>()
    public var onUnlockedDismiss = ValuePipe<Void>()
    public var isUnlockedAndReady: Signal<Void, NoError> {
        return self.isCurrentlyLockedPromise.get()
            |> filter { !$0 }
            |> distinctUntilChanged(isEqual: ==)
            |> mapToSignal { [weak self] _ in
                guard let strongSelf = self else { return .never() }
                
                return strongSelf.accountManager.hiddenAccountManager.unlockedHiddenAccountRecordIdPromise.get()
                |> mapToSignal { unlockedHiddenAccountRecordId in
                    if unlockedHiddenAccountRecordId == nil {
                        return .single(())
                    } else {
                        return strongSelf.accountManager.hiddenAccountManager.didFinishChangingAccountPromise.get() |> delay(0.1, queue: .mainQueue())
                    }
                }
        }
    }
    // MARK: Postufgram Code: }
    
    public init(rootPath: String, window: Window1?, rootController: UIViewController?, applicationBindings: TelegramApplicationBindings, accountManager: AccountManager<TelegramAccountManagerTypes>, presentationDataSignal: Signal<PresentationData, NoError>, lockIconInitialFrame: @escaping () -> CGRect?) {
        assert(Queue.mainQueue().isCurrent())
        
        self.applicationBindings = applicationBindings
        self.accountManager = accountManager
        self.presentationDataSignal = presentationDataSignal
        self.rootPath = rootPath
        self.window = window
        self.rootController = rootController
        
        if let data = try? Data(contentsOf: URL(fileURLWithPath: appLockStatePath(rootPath: self.rootPath))), let current = try? JSONDecoder().decode(LockState.self, from: data) {
            self.currentStateValue = current
        } else {
            self.currentStateValue = LockState()
        }
        self.autolockTimeout.set(self.currentStateValue.autolockTimeout)
        
        self.hiddenAccountsAccessChallengeDataDisposable = (accountManager.hiddenAccountManager.getHiddenAccountsAccessChallengeDataPromise.get() |> deliverOnMainQueue).start(next: { [weak self] value in
            guard let strongSelf = self else {
                return
            }
            
            strongSelf.hiddenAccountsAccessChallengeData = value
        })
        
        let _ = (combineLatest(queue: .mainQueue(),
            accountManager.accessChallengeData(),
            accountManager.sharedData(keys: Set([ApplicationSpecificSharedDataKeys.presentationPasscodeSettings])),
            presentationDataSignal,
            applicationBindings.applicationIsActive,
            self.currentState.get()
        )
        |> deliverOnMainQueue).start(next: { [weak self] accessChallengeData, sharedData, presentationData, appInForeground, state in
            guard let strongSelf = self else {
                return
            }
            
            let passcodeSettings: PresentationPasscodeSettings = sharedData.entries[ApplicationSpecificSharedDataKeys.presentationPasscodeSettings]?.get(PresentationPasscodeSettings.self) ?? .defaultSettings
            
            let timestamp = CFAbsoluteTimeGetCurrent()
            var becameActiveRecently = false
            if appInForeground {
                if !strongSelf.lastActiveValue {
                    strongSelf.lastActiveValue = true
                    strongSelf.lastActiveTimestamp = timestamp
                }
                
                if let lastActiveTimestamp = strongSelf.lastActiveTimestamp {
                    if lastActiveTimestamp + 0.5 > timestamp {
                        becameActiveRecently = true
                    }
                }
            } else {
                strongSelf.lastActiveValue = false
            }
            // MARK: Postufgram Code: {
            strongSelf.checkCurrentAccountDisposable.set(strongSelf.updateIsCurrentAccountHiddenProperty())
            // MARK: Postufgram Code: }
            var shouldDisplayCoveringView = false
            var isCurrentlyLocked = false
            
            if !accessChallengeData.data.isLockable {
                if let passcodeController = strongSelf.passcodeController {
                    strongSelf.passcodeController = nil
                    passcodeController.dismiss()
                }
                
                strongSelf.autolockTimeout.set(nil)
                strongSelf.autolockReportTimeout.set(nil)
            } else {
                if let _ = passcodeSettings.autolockTimeout, !appInForeground {
                    shouldDisplayCoveringView = true
                }
                
                if !appInForeground {
                    if let autolockTimeout = passcodeSettings.autolockTimeout {
                        strongSelf.autolockReportTimeout.set(autolockTimeout)
                    } else if state.isManuallyLocked {
                        strongSelf.autolockReportTimeout.set(1)
                    } else {
                        strongSelf.autolockReportTimeout.set(nil)
                    }
                } else {
                    strongSelf.autolockReportTimeout.set(nil)
                }
                
                strongSelf.autolockTimeout.set(passcodeSettings.autolockTimeout)
                
                if isLocked(passcodeSettings: passcodeSettings, state: state, isApplicationActive: appInForeground) {
                    isCurrentlyLocked = true
                    
                    let biometrics: PasscodeEntryControllerBiometricsMode
                    if passcodeSettings.enableBiometrics {
                        biometrics = .enabled(passcodeSettings.biometricsDomainState)
                    } else {
                        biometrics = .none
                    }
                    
                    if let passcodeController = strongSelf.passcodeController {
                        if becameActiveRecently, case .enabled = biometrics, appInForeground {
                            passcodeController.requestBiometrics()
                        }
                        passcodeController.ensureInputFocused()
                    } else {
                        strongSelf.lockingIsCompletePromise.set(.single(false))

                        let passcodeController = PasscodeEntryController(applicationBindings: strongSelf.applicationBindings, accountManager: strongSelf.accountManager, appLockContext: strongSelf, presentationData: presentationData, presentationDataSignal: strongSelf.presentationDataSignal, statusBarHost: window?.statusBarHost, challengeData: accessChallengeData.data, biometrics: biometrics, arguments: PasscodeEntryControllerPresentationArguments(animated: !becameActiveRecently, lockIconInitialFrame: {
                            if let lockViewFrame = lockIconInitialFrame() {
                                return lockViewFrame
                            } else {
                                return CGRect()
                            }
                        }), hiddenAccountsAccessChallengeData: strongSelf.hiddenAccountsAccessChallengeData, hasPublicAccountsSignal: accountManager.hiddenAccountManager.hasPublicAccounts(accountManager: accountManager))
                        if becameActiveRecently, appInForeground {
                            passcodeController.presentationCompleted = { [weak passcodeController, weak self] in
                                if let strongSelf = self {
                                    strongSelf.accountManager.hiddenAccountManager.unlockedHiddenAccountRecordIdPromise.set(nil)
                                    strongSelf.lockingIsCompletePromise.set(.single(true))
                                }
                                if case .enabled = biometrics {
                                    passcodeController?.requestBiometrics()
                                }
                                passcodeController?.ensureInputFocused()
                            }
                        } else {
                            passcodeController.presentationCompleted = { [weak self] in
                                if let strongSelf = self {
                                    strongSelf.accountManager.hiddenAccountManager.unlockedHiddenAccountRecordIdPromise.set(nil)
                                    strongSelf.lockingIsCompletePromise.set(.single(true))
                                }
                            }
                        }
                        passcodeController.presentedOverCoveringView = true
                        passcodeController.isOpaqueWhenInOverlay = true
                        strongSelf.passcodeController = passcodeController
                        if let rootViewController = strongSelf.rootController {
                            if let _ = rootViewController.presentedViewController as? UIActivityViewController {
                            } else {
                                rootViewController.dismiss(animated: false, completion: nil)
                            }
                        }
                        // MARK: Postufgram Code: {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                            if let window = strongSelf.window {
                                let coveringView = LockedWindowCoveringView(theme: presentationData.theme)
                                coveringView.updateSnapshot(getPublicCoveringViewSnapshot(window: window))
                                strongSelf.snapshotView = coveringView
                            }
                        }
                        // MARK: Postufgram Code: }
                        strongSelf.window?.present(passcodeController, on: .passcode)
                    }
                } else if let passcodeController = strongSelf.passcodeController {
                    strongSelf.passcodeController = nil
                    // MARK: Postufgram Code: {
                    passcodeController.dismiss() { [weak self] in
                        self?.onUnlockedDismiss.putNext(())
                    }
                    // MARK: Postufgram Code: }
                }
            }
            
            strongSelf.updateTimestampRenewTimer(shouldRun: appInForeground && !isCurrentlyLocked)
            // MARK: Postufgram Code: {
            strongSelf.isCurrentlyLockedPromise.set(.single(isCurrentlyLocked))
            // MARK: Postufgram Code: }
            
            if shouldDisplayCoveringView {
                if strongSelf.coveringView == nil, let window = strongSelf.window {
                    let coveringView = LockedWindowCoveringView(theme: presentationData.theme)
                    // MARK: Postufgram Code: {
                    coveringView.updateSnapshot(getCoveringViewSnaphot(window: window))
                    // MARK: Postufgram Code: }
                    strongSelf.coveringView = coveringView
                    window.coveringView = coveringView
                    
                    if let rootViewController = strongSelf.rootController {
                        if let _ = rootViewController.presentedViewController as? UIActivityViewController {
                        } else {
                            rootViewController.dismiss(animated: false, completion: nil)
                        }
                    }
                }
            } else {
                if let _ = strongSelf.coveringView {
                    strongSelf.coveringView = nil
                    strongSelf.window?.coveringView = nil
                }
            }
        })
        
        self.currentState.set(.single(self.currentStateValue))
        
        self.applicationInForegroundDisposable = (applicationBindings.applicationInForeground
            |> distinctUntilChanged(isEqual: ==)
            |> filter { !$0 }
            |> deliverOnMainQueue).start(next: { [weak self] _ in
                guard let strongSelf = self else { return }
                
                if strongSelf.accountManager.hiddenAccountManager.unlockedHiddenAccountRecordId != nil {
                    //FIXME: - Проверить нужна ли нам это строка
                    //UIApplication.shared.isStatusBarHidden = false
                }
                
                // MARK: Postufgram Code: {
                if strongSelf.isCurrentAccountHidden {
                    strongSelf.coveringView = strongSelf.snapshotView
                    strongSelf.window?.coveringView = strongSelf.snapshotView
                }
                // MARK: Postufgram Code: }
                
                strongSelf.accountManager.hiddenAccountManager.unlockedHiddenAccountRecordIdPromise.set(nil)
        })
        
        let _ = (self.autolockTimeout.get()
        |> deliverOnMainQueue).start(next: { [weak self] autolockTimeout in
            self?.updateLockState { state in
                var state = state
                state.autolockTimeout = autolockTimeout
                return state
            }
        })
    }
    
    // MARK: Postufgram Code: {
    private func updateIsCurrentAccountHiddenProperty() -> Disposable {
        (accountManager.currentAccountRecord(allocateIfNotExists: false)
            |> mapToQueue { [weak self] accountRecord -> Signal<Bool, NoError> in
                guard let strongSelf = self,
                      let accountRecord = accountRecord else { return .never() }
                let accountRecordId = accountRecord.0
                return strongSelf.accountManager.hiddenAccountManager.isAccountHidden(accountRecordId: accountRecordId, accountManager: strongSelf.accountManager)
            }).start() { [weak self] isAccountHidden in
                self?.isCurrentAccountHidden = isAccountHidden
            }
    }
    // MARK: Postufgram Code: }
    
    private func updateTimestampRenewTimer(shouldRun: Bool) {
        if shouldRun {
            if self.timestampRenewTimer == nil {
                let timestampRenewTimer = SwiftSignalKit.Timer(timeout: 5.0, repeat: true, completion: { [weak self] in
                    guard let strongSelf = self else {
                        return
                    }
                    strongSelf.updateApplicationActivityTimestamp()
                }, queue: .mainQueue())
                self.timestampRenewTimer = timestampRenewTimer
                timestampRenewTimer.start()
            }
        } else {
            if let timestampRenewTimer = self.timestampRenewTimer {
                self.timestampRenewTimer = nil
                timestampRenewTimer.invalidate()
            }
        }
    }
    
    private func updateApplicationActivityTimestamp() {
        self.updateLockState { state in
            var bootTimestamp: Int32 = 0
            let uptime = getDeviceUptimeSeconds(&bootTimestamp)
            
            var state = state
            state.applicationActivityTimestamp = MonotonicTimestamp(bootTimestamp: bootTimestamp, uptime: uptime)
            return state
        }
    }
    
    private func updateLockState(_ f: @escaping (LockState) -> LockState) {
        Queue.mainQueue().async {
            let updatedState = f(self.currentStateValue)
            if updatedState != self.currentStateValue {
                self.currentStateValue = updatedState
                self.currentState.set(.single(updatedState))
                
                let path = appLockStatePath(rootPath: self.rootPath)
                
                self.syncQueue.async {
                    if let data = try? JSONEncoder().encode(updatedState) {
                        let _ = try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
                    }
                }
            }
        }
    }
    
    public var invalidAttempts: Signal<AccessChallengeAttempts?, NoError> {
        return self.currentState.get()
        |> map { state in
            return state.unlockAttemts.flatMap { unlockAttemts in
                return AccessChallengeAttempts(count: unlockAttemts.count, bootTimestamp: unlockAttemts.timestamp.bootTimestamp, uptime: unlockAttemts.timestamp.uptime)
            }
        }
    }
    
    public var autolockDeadline: Signal<Int32?, NoError> {
        return self.autolockReportTimeout.get()
        |> distinctUntilChanged
        |> map { value -> Int32? in
            if let value = value {
                return Int32(Date().timeIntervalSince1970) + value
            } else {
                return nil
            }
        }
    }
    
    public func lock() {
        self.updateLockState { state in
            var state = state
            state.isManuallyLocked = true
            return state
        }
    }
    
    public func unlock() {
        self.updateLockState { state in
            var state = state
            
            state.unlockAttemts = nil
            
            state.isManuallyLocked = false
            
            var bootTimestamp: Int32 = 0
            let uptime = getDeviceUptimeSeconds(&bootTimestamp)
            let timestamp = MonotonicTimestamp(bootTimestamp: bootTimestamp, uptime: uptime)
            state.applicationActivityTimestamp = timestamp
            
            return state
        }
    }
    
    public func failedUnlockAttempt() {
        self.updateLockState { state in
            var state = state
            var unlockAttemts = state.unlockAttemts ?? UnlockAttempts(count: 0, timestamp: MonotonicTimestamp(bootTimestamp: 0, uptime: 0))
            
            unlockAttemts.count += 1
            
            var bootTimestamp: Int32 = 0
            let uptime = getDeviceUptimeSeconds(&bootTimestamp)
            let timestamp = MonotonicTimestamp(bootTimestamp: bootTimestamp, uptime: uptime)
            
            unlockAttemts.timestamp = timestamp
            state.unlockAttemts = unlockAttemts
            return state
        }
    }
    
    deinit {
        self.hiddenAccountsAccessChallengeDataDisposable?.dispose()
        self.applicationInForegroundDisposable?.dispose()
    }
}
