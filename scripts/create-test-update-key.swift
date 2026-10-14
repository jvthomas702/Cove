import CryptoKit
import Foundation
let file = URL(fileURLWithPath: CommandLine.arguments[1])
let key = Curve25519.Signing.PrivateKey()
try Data((key.rawRepresentation.base64EncodedString()+"\n").utf8).write(to: file, options: .atomic)
try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
print(key.publicKey.rawRepresentation.base64EncodedString())
