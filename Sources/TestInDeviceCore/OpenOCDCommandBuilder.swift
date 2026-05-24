import Foundation

public struct OpenOCDPaths: Equatable {
    public var executable: URL
    public var scriptsDirectory: URL
    public var helpersScript: URL?

    public init(executable: URL, scriptsDirectory: URL, helpersScript: URL?) {
        self.executable = executable
        self.scriptsDirectory = scriptsDirectory
        self.helpersScript = helpersScript
    }
}

public struct OpenOCDPorts: Equatable {
    public var gdb: Int
    public var tcl: Int
    public var telnet: Int
    public var rtt: Int

    public init(gdb: Int = 50000, tcl: Int = 50001, telnet: Int = 50002, rtt: Int = 50003) {
        self.gdb = gdb
        self.tcl = tcl
        self.telnet = telnet
        self.rtt = rtt
    }
}

public enum OpenOCDCommandBuilder {
    public static func arguments(
        paths: OpenOCDPaths,
        elfURL: URL,
        ports: OpenOCDPorts = OpenOCDPorts(),
        adapterSpeed: Int = 5_000,
        target: DeviceTestTarget = .rp2350
    ) -> [String] {
        var args = [
            "-c", "gdb_port \(ports.gdb)",
            "-c", "tcl_port \(ports.tcl)",
            "-c", "telnet_port \(ports.telnet)",
            "-s", paths.scriptsDirectory.path,
        ]
        if let helpersScript = paths.helpersScript {
            args += ["-f", helpersScript.path]
        }
        args += [
            "-f", "interface/cmsis-dap.cfg",
            "-f", target.openOCDTargetConfig,
            "-c", "adapter speed \(adapterSpeed)",
            "-c", "init",
            "-c", "program \(elfURL.path) verify",
            "-c", #"rtt setup 0x20000000 \#(String(format: "0x%X", target.rttMemorySize)) "SEGGER RTT""#,
            "-c", "reset run",
            "-c", "sleep 500",
            "-c", "rtt start",
            "-c", "rtt server start \(ports.rtt) 0",
        ]
        return args
    }
}
