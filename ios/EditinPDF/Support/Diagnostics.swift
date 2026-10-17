import Foundation
import os

/// Where the app's logs and signposts go: one subsystem, the app's bundle identifier, with a category
/// for each part of the app ("tiles", "thumbnails", "selection", "open", "fixtures"). In Instruments
/// and the Console, filter by the subsystem to see all of them.
enum Diagnostics {
    /// The app's bundle identifier. The literal is only for a process that has none, and is the
    /// identifier the app ships with (Config/Base.xcconfig).
    static let subsystem = Bundle.main.bundleIdentifier ?? "app.editinpdf.ios"
}
