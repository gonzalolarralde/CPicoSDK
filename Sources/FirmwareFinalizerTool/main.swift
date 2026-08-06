import FirmwareFinalizerCore
import Foundation
#if os(macOS)
import Darwin
#elseif os(Linux)
import Glibc
#endif

@main
struct FirmwareFinalizerTool {
    enum Error: Swift.Error, CustomStringConvertible {
        case invalidArguments

        var description: String {
            switch self {
            case .invalidArguments:
                return "usage: FirmwareFinalizerTool --request <request.json>"
            }
        }
    }

    static func main() async throws {
        #if os(macOS) || os(Linux)
        setbuf(stdout, nil)
        setbuf(stderr, nil)
        #endif

        let arguments = Array(CommandLine.arguments.dropFirst())
        guard arguments.count == 2, arguments[0] == "--request" else {
            throw Error.invalidArguments
        }

        let requestData = try Data(contentsOf: URL(fileURLWithPath: arguments[1]))
        let request = try JSONDecoder().decode(
            FirmwareFinalizationRequest.self,
            from: requestData
        )
        try await FirmwareFinalizer(request: request).run()
    }
}
