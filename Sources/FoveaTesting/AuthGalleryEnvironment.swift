import Foundation

enum AuthGalleryEnvironment {
    static var platform: String {
        #if os(iOS) && targetEnvironment(simulator)
            return "iOS-Simulator"
        #elseif os(iOS)
            return "iOS-Device"
        #elseif os(macOS)
            return "macOS"
        #else
            return "Apple-Unknown"
        #endif
    }

    static var architecture: String {
        #if arch(arm64)
            return "arm64"
        #elseif arch(x86_64)
            return "x86_64"
        #else
            return "unknown"
        #endif
    }
}
