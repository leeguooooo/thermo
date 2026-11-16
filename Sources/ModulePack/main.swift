import CryptoKit
import Foundation
import ModuleKit

// The module pipeline's packing tool. Runs in the registry's CI with the private key from a secret;
// never inside the app.
//
//   ModulePack keygen <private-key-out>                       prints the key ID and public key (base64)
//   ModulePack pack <module.json> <module.wasm> <key-id> <out.thermomodule> < private-key
//   ModulePack verify <package> <key-id> <public-key-base64>
//   ModulePack listing <package> <https url of the package>   prints a registry entry (JSON)

func fail(_ message: String) -> Never { FileHandle.standardError.write(Data((message + "\n").utf8)); exit(1) }
func read(_ path: String) -> Data {
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { fail("cannot read \(path)") }
    return data
}
let args = Array(CommandLine.arguments.dropFirst())

switch args.first {
case "keygen" where args.count == 2:
    let key = Curve25519.Signing.PrivateKey()
    let out = URL(fileURLWithPath: args[1])
    guard FileManager.default.createFile(atPath: out.path, contents: Data(key.rawRepresentation.base64EncodedString().utf8),
                                         attributes: [.posixPermissions: 0o600]) else { fail("cannot write \(args[1])") }
    let pub = key.publicKey.rawRepresentation
    print("key-id: " + String(ModulePackage.fileHash(pub).prefix(16)))
    print("public-key: " + pub.base64EncodedString())
case "pack" where args.count == 5:
    let secret = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    guard let raw = Data(base64Encoded: secret), let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw) else { fail("no private key on stdin") }
    let package = try ModulePackage.sign(manifest: read(args[1]), wasm: read(args[2]), key: key, keyID: args[3])
    // The packer refuses what the app would refuse.
    do { _ = try package.verify(keys: [args[3]: key.publicKey.rawRepresentation]) } catch { fail("\(error)") }
    try package.encoded().write(to: URL(fileURLWithPath: args[4]), options: .atomic)
case "verify" where args.count == 4:
    guard let pub = Data(base64Encoded: args[3]) else { fail("bad public key") }
    do { let manifest = try ModulePackage.decode(read(args[1])).verify(keys: [args[2]: pub]); print("ok \(manifest.id) \(manifest.version)") }
    catch { fail("\(error)") }
case "listing" where args.count == 3:
    let data = read(args[1])
    guard let url = URL(string: args[2]), url.scheme == "https" else { fail("url must be https") }
    let package = try ModulePackage.decode(data)
    let manifest = try ModuleManifest.load(package.manifestData)
    let listing = ModuleRegistry.Listing(id: manifest.id, version: manifest.version, name: manifest.name, summary: manifest.summary,
                                         symbol: manifest.symbol, capabilities: manifest.capabilities, size: data.count,
                                         sha256: ModulePackage.fileHash(data), url: url)
    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    print(String(decoding: try encoder.encode(listing), as: UTF8.self))
default:
    fail("usage: ModulePack keygen|pack|verify|listing …")
}
