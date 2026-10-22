import MessageUI
import SwiftUI
import UIKit

/// What the app says about itself in the feedback it sends.
enum AppInfo {
    /// Where Send Feedback writes to.
    static let feedbackAddress = "info@consultin.ai"

    /// The version people see ("0.2.0"), from the app's Info.plist.
    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    }

    /// The build number ("4"), from the app's Info.plist.
    static var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
    }

    /// The device's model identifier ("iPhone17,1"): the machine `uname` reports, or, in the simulator,
    /// the model it simulates (its machine is the Mac's, "arm64").
    static var deviceModel: String {
        #if targetEnvironment(simulator)
        if let simulated = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"], !simulated.isEmpty {
            return simulated
        }
        #endif
        var system = utsname()
        guard uname(&system) == 0 else { return "" }
        return withUnsafeBytes(of: &system.machine) { bytes in
            String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
        }
    }
}

/// The email Send Feedback prefills: to `AppInfo.feedbackAddress`, its subject naming the app's version
/// and build, its body room to write in, then a short block about the device (the app's version and
/// build, the system, the device model). Nothing of any document: no name, no contents, no path. The
/// reader adds what they want in Mail.
struct FeedbackMail: Equatable {
    let recipient: String
    let subject: String
    let body: String

    init(recipient: String, subject: String, body: String) {
        self.recipient = recipient
        self.subject = subject
        self.body = body
    }

    /// The mail for app version `appVersion` (build `build`), on `system` ("iOS 27.0") and device `model`.
    init(appVersion: String, build: String, system: String, model: String) {
        recipient = AppInfo.feedbackAddress
        subject = Strings.feedbackSubject(version: appVersion, build: build)
        let about = [
            Strings.feedbackAboutThisDevice,
            Strings.feedbackAppLine(version: appVersion, build: build),
            Strings.feedbackSystemLine(system),
            Strings.feedbackDeviceLine(model),
        ]
        body = "\n\n\n" + about.joined(separator: "\n")
    }

    /// The mail for this app on this device.
    @MainActor
    static func current() -> FeedbackMail {
        let device = UIDevice.current
        return FeedbackMail(appVersion: AppInfo.version, build: AppInfo.build,
                            system: "\(device.systemName) \(device.systemVersion)", model: AppInfo.deviceModel)
    }

    /// The same mail as a `mailto:` link (RFC 6068), for when Mail cannot compose it here: the subject and
    /// the body percent-encoded, everything but ASCII letters, digits and `-._~`, line breaks as CRLF.
    var mailtoURL: URL? {
        let fields = [("subject", subject), ("body", body.replacingOccurrences(of: "\n", with: "\r\n"))]
        let query = fields.compactMap { name, value in
            value.addingPercentEncoding(withAllowedCharacters: Self.unreserved).map { "\(name)=\($0)" }
        }
        guard query.count == fields.count,
              let address = recipient.addingPercentEncoding(withAllowedCharacters: Self.address) else { return nil }
        return URL(string: "mailto:\(address)?" + query.joined(separator: "&"))
    }

    /// RFC 3986's unreserved characters: what a field's value keeps as it is.
    private static let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
    /// What the address keeps as it is: the unreserved characters and "@".
    private static let address = unreserved.union(CharacterSet(charactersIn: "@"))
}

extension View {
    /// Sends feedback when `isRequested` turns true (and turns it back): Mail's composer, prefilled
    /// (`FeedbackMail`), when the device can send mail; otherwise the same mail as a `mailto:` link,
    /// for whichever mail app the reader has; and when that opens nothing either, an alert with the
    /// address and a button that copies it (on this device only). The app sends nothing itself.
    func feedbackSender(isRequested: Binding<Bool>) -> some View {
        modifier(FeedbackSender(isRequested: isRequested))
    }
}

/// `View.feedbackSender`.
private struct FeedbackSender: ViewModifier {
    @Binding var isRequested: Bool
    /// The mail Mail's composer is up for.
    @State private var composing: FeedbackMail?
    /// Whether the alert with the address is up.
    @State private var showsAddress = false
    @Environment(\.openURL) private var openURL

    func body(content: Content) -> some View {
        content
            .onChange(of: isRequested) {
                guard isRequested else { return }
                isRequested = false
                send()
            }
            .sheet(isPresented: Binding(get: { composing != nil }, set: { if !$0 { composing = nil } })) {
                if let composing {
                    MailComposer(mail: composing) { self.composing = nil }
                        .ignoresSafeArea()
                }
            }
            .alert(Strings.feedbackNoMailTitle, isPresented: $showsAddress) {
                Button(Strings.copyAddress) {
                    DocumentModel.keepLocally(AppInfo.feedbackAddress, on: UIPasteboard.general)
                }
                .accessibilityIdentifier("copyFeedbackAddressButton")
                Button(Strings.ok, role: .cancel) {}
            } message: {
                Text(Strings.feedbackNoMailMessage(address: AppInfo.feedbackAddress))
            }
    }

    private func send() {
        let mail = FeedbackMail.current()
        if MFMailComposeViewController.canSendMail() {
            composing = mail
            return
        }
        guard let link = mail.mailtoURL else {
            showsAddress = true
            return
        }
        openURL(link) { opened in
            if !opened { showsAddress = true }
        }
    }
}

/// Mail's composer, prefilled with `mail`; `finished` is called when it is done (sent, saved or
/// cancelled), to put it away.
private struct MailComposer: UIViewControllerRepresentable {
    let mail: FeedbackMail
    let finished: @MainActor () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(finished: finished)
    }

    func makeUIViewController(context: Context) -> MFMailComposeViewController {
        let composer = MFMailComposeViewController()
        composer.mailComposeDelegate = context.coordinator
        composer.setToRecipients([mail.recipient])
        composer.setSubject(mail.subject)
        composer.setMessageBody(mail.body, isHTML: false)
        return composer
    }

    func updateUIViewController(_ composer: MFMailComposeViewController, context: Context) {}

    // MessageUI calls its delegate on the main thread; `@preconcurrency` checks that it does.
    @MainActor
    final class Coordinator: NSObject, @preconcurrency MFMailComposeViewControllerDelegate {
        let finished: @MainActor () -> Void

        init(finished: @escaping @MainActor () -> Void) {
            self.finished = finished
        }

        func mailComposeController(_ controller: MFMailComposeViewController,
                                   didFinishWith result: MFMailComposeResult, error: Error?) {
            finished()
        }
    }
}
