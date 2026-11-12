import Foundation

/// The two halves of the connection between the kernel and one module. Payloads are JSON so the
/// same messages can later cross to modules that are not Swift.
///
/// The names are fixed with `@objc(...)`: both sides are separate binaries and must agree on them.

/// Exported by the kernel. A module can only reach the Mac through `request`, and the kernel
/// answers according to `CapabilityPolicy` and the module's own manifest.
@objc(TMKernelXPC) public protocol KernelXPC {
    func request(_ capability: String, payload: Data, reply: @escaping @Sendable (Data?, String?) -> Void)
}

/// Exported by a module.
@objc(TMModuleXPC) public protocol ModuleXPC {
    /// The manifest interface the module was built for; the kernel refuses a module it cannot read.
    func interface(reply: @escaping @Sendable (Int) -> Void)
    /// Runs one of the manifest's commands. `arguments` is a JSON object keyed by parameter name.
    func run(_ command: String, arguments: Data, reply: @escaping @Sendable (Data?, String?) -> Void)
}

public enum ModuleXPCInterfaces {
    public static var kernel: NSXPCInterface { NSXPCInterface(with: KernelXPC.self) }
    public static var module: NSXPCInterface { NSXPCInterface(with: ModuleXPC.self) }
}
