// Written by AI on 2026.11.18 by model Claude Opus 5.5.
//
// The layout above iOS's buttons when a request's notification is touched
// and held (Paper, "The request", "After you touch and hold it").

import AgentKeyringApprovalUI
import SwiftUI
import UIKit
import UserNotifications
import UserNotificationsUI

final class NotificationViewController: UIViewController, UNNotificationContentExtension {
    private var host: UIHostingController<AnyView>?

    func didReceive(_ notification: UNNotification) {
        guard let request = PhoneNotification.decode(notification.request.content.userInfo) else { return }
        host?.view.removeFromSuperview(); host?.removeFromParent()
        let hosting = UIHostingController(rootView: AnyView(PhoneNotificationCard(request: request)))
        hosting.sizingOptions = .preferredContentSize
        hosting.view.backgroundColor = .clear
        addChild(hosting)
        view.addSubview(hosting.view)
        hosting.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            hosting.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            hosting.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            hosting.view.topAnchor.constraint(equalTo: view.topAnchor),
            hosting.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        hosting.didMove(toParent: self)
        host = hosting
        let width = view.bounds.width > 0 ? view.bounds.width : 386
        let size = hosting.sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude))
        preferredContentSize = CGSize(width: width, height: size.height)
    }
}
