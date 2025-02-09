import Foundation
import UIKit
import SwiftSignalKit
import Display
import TelegramCore
import Postbox
import TelegramPresentationData
import ProgressNavigationButtonNode
import AccountContext
import SearchUI
import ChatListUI

public final class PeerSelectionControllerImpl: ViewController, PeerSelectionController {
    private let context: AccountContext
    
    private var presentationData: PresentationData
    private var presentationDataDisposable: Disposable?
    
    private var customTitle: String?
    
    public var peerSelected: ((Peer) -> Void)?
    public var multiplePeersSelected: (([Peer], [PeerId: Peer], NSAttributedString, PeerSelectionControllerSendMode, ChatInterfaceForwardOptionsState?) -> Void)?
    private let filter: ChatListNodePeersFilter
    
    private let attemptSelection: ((Peer) -> Void)?
    private let createNewGroup: (() -> Void)?
    
    public var inProgress: Bool = false {
        didSet {
            if self.inProgress != oldValue {
                if self.isNodeLoaded {
                    self.peerSelectionNode.inProgress = self.inProgress
                }
                
                if self.inProgress {
                    self.navigationItem.rightBarButtonItem = UIBarButtonItem(customDisplayNode: ProgressNavigationButtonNode(color: self.presentationData.theme.rootController.navigationBar.controlColor))
                } else {
                    self.navigationItem.rightBarButtonItem = nil
                }
            }
        }
    }
    
    public var customDismiss: (() -> Void)?
    
    private var peerSelectionNode: PeerSelectionControllerNode {
        return super.displayNode as! PeerSelectionControllerNode
    }
    
    let openMessageFromSearchDisposable: MetaDisposable = MetaDisposable()
    
    private let _ready = Promise<Bool>()
    override public var ready: Promise<Bool> {
        return self._ready
    }
    
    private let hasChatListSelector: Bool
    private let hasContactSelector: Bool
    private let hasGlobalSearch: Bool
    private let pretendPresentedInModal: Bool
    private let forwardedMessageIds: [EngineMessage.Id]
    
    override public var _presentedInModal: Bool {
        get {
            if self.pretendPresentedInModal {
                return true
            } else {
                return super._presentedInModal
            }
        } set(value) {
            if !self.pretendPresentedInModal {
                super._presentedInModal = value
            }
        }
    }
    
    private var searchContentNode: NavigationBarSearchContentNode?
    
    public init(_ params: PeerSelectionControllerParams) {
        self.context = params.context
        self.filter = params.filter
        self.hasChatListSelector = params.hasChatListSelector
        self.hasContactSelector = params.hasContactSelector
        self.hasGlobalSearch = params.hasGlobalSearch
        self.presentationData = params.updatedPresentationData?.initial ?? params.context.sharedContext.currentPresentationData.with { $0 }
        self.attemptSelection = params.attemptSelection
        self.createNewGroup = params.createNewGroup
        self.pretendPresentedInModal = params.pretendPresentedInModal
        self.forwardedMessageIds = params.forwardedMessageIds
        
        super.init(navigationBarPresentationData: NavigationBarPresentationData(presentationData: self.presentationData))
        
        self.navigationPresentation = .modal
        
        self.statusBar.statusBarStyle = self.presentationData.theme.rootController.statusBarStyle.style
        
        self.customTitle = params.title
        self.title = self.customTitle ?? self.presentationData.strings.Conversation_ForwardTitle
        
        self.navigationItem.leftBarButtonItem = UIBarButtonItem(title: self.presentationData.strings.Common_Cancel, style: .plain, target: self, action: #selector(self.cancelPressed))
        
        self.scrollToTop = { [weak self] in
            if let strongSelf = self {
                if let searchContentNode = strongSelf.searchContentNode {
                    searchContentNode.updateExpansionProgress(1.0, animated: true)
                }
                strongSelf.peerSelectionNode.scrollToTop()
            }
        }
        
        self.presentationDataDisposable = ((params.updatedPresentationData?.signal ?? self.context.sharedContext.presentationData)
        |> deliverOnMainQueue).start(next: { [weak self] presentationData in
            if let strongSelf = self {
                let previousTheme = strongSelf.presentationData.theme
                let previousStrings = strongSelf.presentationData.strings
                
                strongSelf.presentationData = presentationData
                
                if previousTheme !== presentationData.theme || previousStrings !== presentationData.strings {
                    strongSelf.updateThemeAndStrings()
                }
            }
        })
        
        self.searchContentNode = NavigationBarSearchContentNode(theme: self.presentationData.theme, placeholder: self.presentationData.strings.Common_Search, activate: { [weak self] in
            self?.activateSearch()
        })
        self.navigationBar?.setContentNode(self.searchContentNode, animated: false)
        
        if params.multipleSelection {
            self.navigationItem.rightBarButtonItem = UIBarButtonItem(title: self.presentationData.strings.Common_Select, style: .plain, target: self, action: #selector(self.beginSelection))
        }
    }
    
    required public init(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    deinit {
        self.openMessageFromSearchDisposable.dispose()
        self.presentationDataDisposable?.dispose()
    }
    
    private func updateThemeAndStrings() {
        self.statusBar.statusBarStyle = self.presentationData.theme.rootController.statusBarStyle.style
        self.navigationBar?.updatePresentationData(NavigationBarPresentationData(presentationData: self.presentationData))
        self.searchContentNode?.updateThemeAndPlaceholder(theme: self.presentationData.theme, placeholder: self.presentationData.strings.Common_Search)
        self.title = self.customTitle ?? self.presentationData.strings.Conversation_ForwardTitle
        self.navigationItem.backBarButtonItem = UIBarButtonItem(title: self.presentationData.strings.Common_Back, style: .plain, target: nil, action: nil)
        self.peerSelectionNode.updatePresentationData(self.presentationData)
    }
    
    override public func loadDisplayNode() {
        self.displayNode = PeerSelectionControllerNode(context: self.context, presentationData: self.presentationData, filter: self.filter, hasChatListSelector: self.hasChatListSelector, hasContactSelector: self.hasContactSelector, hasGlobalSearch: self.hasGlobalSearch, forwardedMessageIds: self.forwardedMessageIds, createNewGroup: self.createNewGroup, present: { [weak self] c, a in
            self?.present(c, in: .window(.root), with: a)
        }, presentInGlobalOverlay: { [weak self] c, a in
            self?.presentInGlobalOverlay(c, with: a)
        }, dismiss: { [weak self] in
            self?.presentingViewController?.dismiss(animated: false, completion: nil)
        })
        
        self.peerSelectionNode.navigationBar = self.navigationBar
        self.peerSelectionNode.requestSend = { [weak self] peers, peerMap, text, mode, forwardOptionsState in
            self?.multiplePeersSelected?(peers, peerMap, text, mode, forwardOptionsState)
        }
        
        self.peerSelectionNode.requestSend = { [weak self] peers, peerMap, text, mode, forwardOptionsState in
            self?.multiplePeersSelected?(peers, peerMap, text, mode, forwardOptionsState)
        }
        
        self.peerSelectionNode.requestSend = { [weak self] peers, peerMap, text, mode, forwardOptionsState in
            self?.multiplePeersSelected?(peers, peerMap, text, mode, forwardOptionsState)
        }
        
        self.peerSelectionNode.requestSend = { [weak self] peers, peerMap, text, mode, forwardOptionsState in
            self?.multiplePeersSelected?(peers, peerMap, text, mode, forwardOptionsState)
        }
        
        self.peerSelectionNode.requestSend = { [weak self] peers, peerMap, text, mode, forwardOptionsState in
            self?.multiplePeersSelected?(peers, peerMap, text, mode, forwardOptionsState)
        }
        
        self.peerSelectionNode.requestDeactivateSearch = { [weak self] in
            self?.deactivateSearch()
        }
        
        self.peerSelectionNode.requestActivateSearch = { [weak self] in
            self?.activateSearch()
        }
        
        self.peerSelectionNode.requestOpenPeer = { [weak self] peer in
            if let strongSelf = self, let peerSelected = strongSelf.peerSelected {
                peerSelected(peer)
            }
        }
        
        self.peerSelectionNode.requestOpenDisabledPeer = { [weak self] peer in
            if let strongSelf = self {
                strongSelf.attemptSelection?(peer)
            }
        }
        
        self.peerSelectionNode.requestOpenPeerFromSearch = { [weak self] peer in
            if let strongSelf = self {
                let storedPeer = strongSelf.context.account.postbox.transaction { transaction -> Void in
                    if transaction.getPeer(peer.id) == nil {
                        updatePeers(transaction: transaction, peers: [peer], update: { previousPeer, updatedPeer in
                            return updatedPeer
                        })
                    }
                }
                strongSelf.openMessageFromSearchDisposable.set((storedPeer |> deliverOnMainQueue).start(completed: { [weak strongSelf] in
                    if let strongSelf = strongSelf, let peerSelected = strongSelf.peerSelected {
                        peerSelected(peer)
                    }
                }))
            }
        }
        
        var isProcessingContentOffsetChanged = false
        self.peerSelectionNode.contentOffsetChanged = { [weak self] offset in
            if isProcessingContentOffsetChanged {
                return
            }
            isProcessingContentOffsetChanged = true
            if let strongSelf = self, let searchContentNode = strongSelf.searchContentNode {
                searchContentNode.updateListVisibleContentOffset(offset)
                isProcessingContentOffsetChanged = false
            }
        }
        
        self.peerSelectionNode.contentScrollingEnded = { [weak self] listView in
            if let strongSelf = self, let searchContentNode = strongSelf.searchContentNode {
                return fixNavigationSearchableListNodeScrolling(listView, searchNode: searchContentNode)
            } else {
                return false
            }
        }
        
        self.displayNodeDidLoad()
        
        self._ready.set(self.peerSelectionNode.ready)
    }
    
    override public func containerLayoutUpdated(_ layout: ContainerViewLayout, transition: ContainedViewLayoutTransition) {
        super.containerLayoutUpdated(layout, transition: transition)
        
        self.peerSelectionNode.containerLayoutUpdated(layout, navigationBarHeight: self.cleanNavigationHeight, actualNavigationBarHeight: self.navigationLayout(layout: layout).navigationFrame.maxY, transition: transition)
    }
    
    @objc private func beginSelection() {
        self.navigationItem.rightBarButtonItem = nil
        self.peerSelectionNode.beginSelection()
    }
    
    @objc func cancelPressed() {
        if let customDismiss = self.customDismiss {
            customDismiss()
        } else {
            self.dismiss()
        }
    }
    
    private func activateSearch() {
        if self.displayNavigationBar {
            if let scrollToTop = self.scrollToTop {
                scrollToTop()
            }
            if let searchContentNode = self.searchContentNode {
                self.peerSelectionNode.activateSearch(placeholderNode: searchContentNode.placeholderNode)
            }
            self.setDisplayNavigationBar(false, transition: .animated(duration: 0.5, curve: .spring))
        }
    }
    
    private func deactivateSearch() {
        if !self.displayNavigationBar {
            self.setDisplayNavigationBar(true, transition: .animated(duration: 0.5, curve: .spring))
            if let searchContentNode = self.searchContentNode {
                self.peerSelectionNode.deactivateSearch(placeholderNode: searchContentNode.placeholderNode)
            }
        }
    }
}
