enum BuildType: String {
    case debug = "Debug"
    case release = "Release"
    case releaseWithDebugInfo = "RelWithDebInfo"
    case minimumSizeRelease = "MinSizeRel"

    var swiftBuildType: String {
        switch self {
        case .debug: "debug"
        case .release, .releaseWithDebugInfo, .minimumSizeRelease: "release"
        }
    }

}
