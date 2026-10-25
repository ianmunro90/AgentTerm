import UIKit

enum Device {
    /// iPhone: one column at a time, a narrow terminal.
    static let isPhone = UIDevice.current.userInterfaceIdiom == .phone
}
