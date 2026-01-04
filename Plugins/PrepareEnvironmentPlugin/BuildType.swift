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

    var extraConfigParams: String {
        switch self {
        case .debug, .release: ""
        case .releaseWithDebugInfo: "-Xswiftc -g -Xswiftc -debug-info-format=dwarf -Xcc -g"
        case .minimumSizeRelease: "-Xswiftc -Osize"
        }
    }

    var cmakeBuildType: String {
        self.rawValue
    }
}
