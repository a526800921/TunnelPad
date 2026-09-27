import Foundation
import NIOHTTP1

/// Separate from the Rust-owned tunnel configuration. Opt-in LAN access only.
public struct TunnelAPIConfiguration: Decodable, Sendable, Equatable {
    public let host: String
    public let allowedClientIPs: [String]

    public init(host: String = "127.0.0.1", allowedClientIPs: [String] = []) {
        self.host = host
        self.allowedClientIPs = allowedClientIPs
    }

    public static func load(from url: URL) throws -> Self {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch CocoaError.fileReadNoSuchFile {
            return Self()
        }
        guard data.count <= 65_536,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == Set(["host", "allowedClientIPs"]) else {
            throw ConfigurationError.invalidConfiguration
        }
        let configuration = try JSONDecoder().decode(Self.self, from: data)
        try configuration.validate()
        return configuration
    }

    func validate() throws {
        guard host == "127.0.0.1" || Self.isPrivateIPv4(host),
              allowedClientIPs.allSatisfy(Self.isPrivateIPv4),
              host == "127.0.0.1" || !allowedClientIPs.isEmpty else {
            throw ConfigurationError.invalidConfiguration
        }
    }

    private static func isPrivateIPv4(_ value: String) -> Bool {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        var octets: [UInt8] = []
        for part in parts {
            guard let octet = UInt8(part), String(octet) == part else { return false }
            octets.append(octet)
        }
        return octets[0] == 10 || (octets[0] == 172 && (16...31).contains(octets[1]))
            || (octets[0] == 192 && octets[1] == 168)
    }

    enum ConfigurationError: Error {
        case invalidConfiguration
    }
}

/// Socket address is authoritative; forwarded headers are deliberately ignored.
struct TunnelAPIAccessPolicy: Sendable {
    let configuration: TunnelAPIConfiguration

    func permits(peerIP: String?, headers: HTTPHeaders, port: Int) -> Bool {
        guard let peerIP,
              peerIP == "127.0.0.1" || configuration.allowedClientIPs.contains(peerIP),
              headers["origin"].isEmpty,
              !headers["sec-fetch-site"].contains(where: { $0.lowercased() == "cross-site" }) else {
            return false
        }
        let hosts = headers["host"]
        guard hosts.count == 1 else { return false }
        let permittedHosts = [configuration.host, "127.0.0.1", "localhost"]
        return permittedHosts.contains { hosts[0].lowercased() == "\($0):\(port)" }
    }
}
