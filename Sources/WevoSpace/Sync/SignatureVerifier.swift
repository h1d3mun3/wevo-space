import Crypto
import Foundation

protocol SignatureVerifier: Sendable {
    func verify(signature: String, message: String, publicKey: String) -> Bool
}

struct P256SignatureVerifier: SignatureVerifier {
    func verify(signature: String, message: String, publicKey: String) -> Bool {
        guard let jsonData = publicKey.data(using: .utf8),
              let jwk = try? JSONDecoder().decode(JWKPublicKey.self, from: jsonData),
              let xData = Data(base64URLEncoded: jwk.x),
              let yData = Data(base64URLEncoded: jwk.y) else { return false }

        var x963 = Data([0x04])
        x963.append(contentsOf: xData)
        x963.append(contentsOf: yData)

        guard let sigData = Data(base64Encoded: signature),
              let msgData = message.data(using: .utf8),
              let key = try? P256.Signing.PublicKey(x963Representation: x963),
              let sig = try? P256.Signing.ECDSASignature(derRepresentation: sigData) else { return false }

        return key.isValidSignature(sig, for: msgData)
    }
}

struct JWKPublicKey: Decodable {
    let x: String
    let y: String
}

extension Data {
    init?(base64URLEncoded string: String) {
        var s = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = s.count % 4
        if remainder > 0 { s += String(repeating: "=", count: 4 - remainder) }
        self.init(base64Encoded: s)
    }
}
