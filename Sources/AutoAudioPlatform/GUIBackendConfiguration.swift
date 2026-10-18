// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import AutoAudioCore
import Yams

/// One format and endpoint policy for discovery, Setup Review and launch.
struct GUIBackendConfiguration {
    private let node: Node

    init(data: Data) throws {
        guard let text = String(data: data, encoding: .utf8),
              let parsed = try? Yams.compose(yaml: text) else {
            throw GUIFailure.permanent("Cannot parse GUI backend configuration as YAML or JSON.")
        }
        try self.init(node: parsed)
    }

    init(node: Node) throws {
        guard let mapping = node.mapping else {
            throw GUIFailure.permanent("GUI backend configuration must be a YAML or JSON mapping.")
        }
        var keys = Set<String>()
        for pair in mapping {
            guard let key = pair.key.string, keys.insert(key).inserted else {
                throw GUIFailure.permanent("GUI backend configuration requires unique string keys.")
            }
        }
        self.node = node
    }

    private static func loopback(_ host: String?) -> Bool {
        ["127.0.0.1", "localhost", "::1", "[::1]"].contains(host ?? "")
    }
    private static func normalized(_ host: String?) -> String? {
        host == "localhost" ? "127.0.0.1" : host?.replacingOccurrences(of: "[", with: "").replacingOccurrences(of: "]", with: "")
    }
    private func absentOrNull(_ key: String) -> Bool {
        guard let value = node[key] else { return true }
        return value.tag == Tag(.null) && value.null != nil
    }
    private var withoutTLS: Bool { absentOrNull("ssl_certificate") && absentOrNull("ssl_private_key") }
    private func port(_ key: String) -> Int? {
        guard let value = node[key], value.tag == Tag(.int),
              let port = value.int, (1...65535).contains(port) else { return nil }
        return port
    }
    var hasBackendFields: Bool { node["bind_address"] != nil || node["camilla_host"] != nil }
    var loopbackURL: String? {
        guard let address = node["bind_address"]?.string, Self.loopback(address),
              let port = port("port"), withoutTLS else { return nil }
        var components = URLComponents()
        components.scheme = "http"; components.host = address; components.port = port
        return components.string
    }

    func validate(guiURL: String, dspURL: String) throws {
        guard let gui = URLComponents(string: guiURL), gui.scheme == "http",
              let dsp = URLComponents(string: dspURL), dsp.scheme == "ws",
              Self.loopback(gui.host), Self.loopback(dsp.host),
              gui.user == nil, gui.password == nil, gui.query == nil, gui.fragment == nil,
              dsp.user == nil, dsp.password == nil, dsp.query == nil, dsp.fragment == nil,
              ["", "/"].contains(dsp.path),
              Self.loopback(node["bind_address"]?.string), Self.loopback(node["camilla_host"]?.string),
              Self.normalized(node["bind_address"]?.string) == Self.normalized(gui.host),
              Self.normalized(node["camilla_host"]?.string) == Self.normalized(dsp.host),
              port("port") != nil, port("camilla_port") != nil,
              port("port") == gui.port, port("camilla_port") == dsp.port, withoutTLS else {
            throw GUIFailure.permanent("GUI backend bind address/HTTP port/DSP endpoint must match this loopback profile, without TLS.")
        }
    }
}
