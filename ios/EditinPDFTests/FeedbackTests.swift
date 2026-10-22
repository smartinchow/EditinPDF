import XCTest
@testable import EditinPDF

/// Send Feedback: the email it prefills (`FeedbackMail`), to `AppInfo.feedbackAddress`, with the app's
/// version, the system and the device model, and nothing of any document; and the `mailto:` link used
/// when Mail cannot compose it.
@MainActor
final class FeedbackTests: XCTestCase {
    let mail = FeedbackMail(appVersion: "0.2.0", build: "4", system: "iOS 27.0", model: "iPhone18,1")

    func testTheMailGoesToTheFeedbackAddressWithTheVersionInItsSubject() {
        XCTAssertEqual(AppInfo.feedbackAddress, "info@consultin.ai")
        XCTAssertEqual(mail.recipient, "info@consultin.ai")
        XCTAssertEqual(mail.subject, "EditinPDF feedback (0.2.0, build 4)")
    }

    /// Room to write first, then a short block about the device: the app's version and build, the system
    /// and the device model. Nothing else.
    func testTheBodyIsRoomToWriteThenAboutThisDevice() {
        XCTAssertEqual(mail.body, """



            About this device
            App: EditinPDF 0.2.0 (4)
            System: iOS 27.0
            Device: iPhone18,1
            """)
    }

    /// The mail made for this device names this build and this system, and carries no document: no file
    /// name, no path, no PDF.
    func testTheMailForThisDeviceCarriesNoDocument() {
        let current = FeedbackMail.current()
        let info = Bundle.main.infoDictionary ?? [:]
        XCTAssertEqual(current.subject, Strings.feedbackSubject(version: info["CFBundleShortVersionString"] as? String ?? "",
                                                                build: info["CFBundleVersion"] as? String ?? ""))
        XCTAssertTrue(current.body.contains(Strings.feedbackSystemLine("\(UIDevice.current.systemName) \(UIDevice.current.systemVersion)")))
        XCTAssertFalse(AppInfo.deviceModel.isEmpty)
        XCTAssertTrue(current.body.hasSuffix(Strings.feedbackDeviceLine(AppInfo.deviceModel)))
        XCTAssertEqual(current.body.split(separator: "\n").count, 4, "a heading and three lines, nothing else")
        for text in [current.subject, current.body] {
            XCTAssertFalse(text.contains("/"), "no path")
            XCTAssertFalse(text.localizedCaseInsensitiveContains(".pdf"), "no file name")
        }
    }

    /// The `mailto:` link: the address, then the subject and the body percent-encoded (everything but
    /// letters, digits and `-._~`), line breaks as CRLF, as RFC 6068 has them.
    func testTheMailtoLinkIsPercentEncoded() throws {
        let odd = FeedbackMail(recipient: "info@consultin.ai", subject: "A b&c=d+e", body: "x\ny?é#")
        XCTAssertEqual(odd.mailtoURL?.absoluteString,
                       "mailto:info@consultin.ai?subject=A%20b%26c%3Dd%2Be&body=x%0D%0Ay%3F%C3%A9%23")
        let link = try XCTUnwrap(mail.mailtoURL)
        XCTAssertEqual(link.scheme, "mailto")
        XCTAssertTrue(link.absoluteString.hasPrefix("mailto:info@consultin.ai?subject=EditinPDF%20feedback%20%280.2.0%2C%20build%204%29&body="))
        XCTAssertTrue(link.absoluteString.contains("About%20this%20device%0D%0AApp%3A%20EditinPDF%200.2.0%20%284%29"))
    }
}
