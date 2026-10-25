import SwiftUI
import UIKit

/// Entry point of the "AgentTerm" share sheet action: uploads the shared files to a host.
@objc(ShareViewController)
final class ShareViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        SharedStore.migrateFromStandardDefaults()
        guard let context = extensionContext else { return }
        let providers = (context.inputItems as? [NSExtensionItem] ?? []).flatMap { $0.attachments ?? [] }
        let root = ShareView(providers: providers) { [weak context] in
            context?.completeRequest(returningItems: nil)
        } onCancel: { [weak context] in
            context?.cancelRequest(withError: CocoaError(.userCancelled))
        }
        let host = UIHostingController(rootView: root.environmentObject(HostStore()))
        addChild(host)
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(host.view)
        host.didMove(toParent: self)
    }
}
