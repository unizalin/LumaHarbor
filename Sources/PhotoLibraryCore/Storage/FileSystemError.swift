import Foundation

enum FileSystemError {
    static func isNoSuchFile(_ error: Error) -> Bool {
        isNoSuchFile(error as NSError, remainingUnderlyingDepth: 4)
    }

    private static func isNoSuchFile(
        _ error: NSError,
        remainingUnderlyingDepth: Int
    ) -> Bool {
        if error.domain == NSCocoaErrorDomain {
            switch CocoaError.Code(rawValue: error.code) {
            case .fileNoSuchFile, .fileReadNoSuchFile:
                return true
            default:
                break
            }
        }

        if error.domain == NSPOSIXErrorDomain, error.code == Int(ENOENT) {
            return true
        }

        guard remainingUnderlyingDepth > 0,
              let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError else {
            return false
        }
        return isNoSuchFile(
            underlying,
            remainingUnderlyingDepth: remainingUnderlyingDepth - 1
        )
    }
}
