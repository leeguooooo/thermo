import AgentCore
import CleanKit
import Darwin
import Foundation

/// Frozen selections are one-shot and time limited. Applying reuses the reviewed identities,
/// never performs another discovery scan, and still runs the cleaner's live ownership checks.
struct CleanPlan: Codable {
    var schema = 1
    let id: UUID
    let expires: Date
    let selectors: [String]
    let report: ScanReport
    let items: [CleanItem]
    let mode: String
}
struct CleanPlanStore {
    let directory: URL
    init(home: String? = nil) {
        let root: String
        if let home { root = home }
        else if let pointer = realpath(NSHomeDirectory(),nil) { root = String(cString:pointer); free(pointer) }
        else { root = NSHomeDirectory() }
        directory = URL(fileURLWithPath:root + "/Library/Application Support/Thermo/CleanPlans")
    }
    private func folder() throws {
        let components = directory.path.split(separator: "/")
        var path = ""
        for component in components {
            path += "/" + component
            var st = stat()
            if lstat(path, &st) == 0 {
                guard st.st_mode & S_IFMT == S_IFDIR else { throw CLIError("Clean plan path contains a link or unsupported directory.") }
            } else {
                guard errno == ENOENT, mkdir(path, 0o700) == 0 else { throw CLIError("Cannot create clean plan directory.") }
            }
        }
        var st = stat()
        guard lstat(directory.path, &st) == 0, st.st_uid == getuid(), st.st_mode & 0o077 == 0 else { throw CLIError("Clean plan directory must be private and owned by this user.") }
    }
    func save(report: ScanReport, selectors: [String], items: [CleanItem], mode: RemovalMode, now: Date = Date()) throws -> CleanPlan {
        guard !report.cancelled, !items.isEmpty else { throw CLIError("A complete scan and nonempty selection are required to save a plan.") }
        try folder()
        let plan = CleanPlan(id: UUID(), expires: now.addingTimeInterval(900), selectors: selectors, report: report, items: items, mode: mode.rawValue)
        let data = try JSONEncoder().encode(plan)
        guard data.count <= 32 * 1024 * 1024 else { throw CLIError("Clean plan exceeds 32 MiB.") }
        let url = directory.appendingPathComponent(plan.id.uuidString + ".json")
        let fd = open(url.path, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw CLIError("Cannot save clean plan.") }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        do { try handle.write(contentsOf: data); try handle.synchronize(); try handle.close() }
        catch { try? handle.close(); unlink(url.path); throw error }
        return plan
    }
    func load(_ text: String, consume: Bool, now: Date = Date(), expected: CleanPlan? = nil) throws -> CleanPlan {
        guard let id = UUID(uuidString: text) else { throw CLIError("A plan UUID is required.") }
        try folder()
        let path = directory.appendingPathComponent(id.uuidString + ".json").path
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw CLIError("Clean plan is unavailable, already consumed or invalid. Create a new plan; do not retry uncertain execution.") }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0, st.st_mode & S_IFMT == S_IFREG, st.st_uid == getuid(), st.st_nlink == 1, st.st_mode & 0o077 == 0, st.st_size > 0, st.st_size <= 32 * 1024 * 1024 else { throw CLIError("Unsupported plan file.") }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw CLIError("Clean plan is being used by another process.") }
        defer { flock(fd, LOCK_UN) }
        let data = try FileHandle(fileDescriptor: fd, closeOnDealloc: false).readToEnd() ?? Data()
        let plan = try JSONDecoder().decode(CleanPlan.self, from: data)
        guard plan.schema == 1, plan.id == id, plan.expires > now, plan.expires.timeIntervalSince(now) <= 900,
              !plan.report.cancelled, RemovalMode(rawValue: plan.mode) != nil else { throw CLIError("Clean plan expired or is unsupported; create a new plan.") }
        var named = stat()
        guard lstat(path, &named) == 0, named.st_ino == st.st_ino, named.st_dev == st.st_dev else { throw CLIError("Clean plan changed while reading.") }
        if let expected {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            guard try encoder.encode(expected) == encoder.encode(plan) else { throw CLIError("Clean plan changed after review; nothing executed.") }
        }
        if consume {
            // An exclusive hard-link marker claims delivery before any mutation. A crash retains
            // the marker; later calls cannot unknowingly replay a partially completed cleanup.
            let used = directory.appendingPathComponent(id.uuidString + ".used").path
            guard link(path, used) == 0 else { throw CLIError("Clean plan was already submitted; inspect history before creating a new plan.") }
            guard unlink(path) == 0 else { throw CLIError("Plan was claimed but could not be retired. No cleanup started.") }
        }
        return plan
    }
}

extension CleanCommand {
    func savePlan(_ requested: [String]) throws {
        let selectors = Self.normalizedSelectors(requested)
        guard !selectors.isEmpty else { throw CLIError("usage: thermo clean plan safe_or_ID… [--trash|--permanent] [--json]") }
        guard !(args.has("trash") && args.has("permanent")) else { throw CLIError("Choose --trash or --permanent.") }
        let report: ScanReport
        if let cached = try reusableReport(for: selectors) { report = cached.report }
        else { report = try scan(Self.cleanupCategories(for: selectors), onlyIDs: Self.itemIDs(in: selectors)) }
        let picked = report.select(selectors)
        let missing = selectors.filter { report.select([$0]).isEmpty }
        guard missing.isEmpty else { throw CLIError("Selectors not found: " + missing.joined(separator: ", ")) }
        let mode: RemovalMode = args.has("permanent") ? .permanent : args.has("trash") ? .trash : .auto
        let plan = try CleanPlanStore().save(report: report, selectors: selectors, items: picked, mode: mode)
        if args.has("json") { print(Export.json(plan)) }
        else { print("Plan " + plan.id.uuidString + " · expires " + plan.expires.ISO8601Format() + "\nthermo clean apply " + plan.id.uuidString + " --dry-run\n" + picked.map { $0.id + " · " + ByteFormat.string($0.bytes) }.joined(separator: "\n")) }
    }
    func applyPlan(_ rest: [String]) throws {
        guard rest.count == 1, args.options["root"] == nil, args.options["older-than"] == nil,
              args.options["budget"] == nil, args.options["timeout"] == nil, !args.has("trash"), !args.has("permanent"), !args.has("rescan") else {
            throw CLIError("clean apply takes a plan UUID, --dry-run, --yes and --json. Scope and removal mode are frozen in the plan.")
        }
        let store = CleanPlanStore()
        let review = try store.load(rest[0], consume: false)
        guard let mode = RemovalMode(rawValue: review.mode) else { throw CLIError("Unsupported removal mode.") }
        if args.has("dry-run") { try execute(report: review.report, picked: review.items, mode: mode); return }
        try app.approveAction("Apply frozen cleanup plan \(review.id), mode \(review.mode), \(review.items.count) items? This plan is consumed once; uncertain executions cannot be retried.")
        let plan = try store.load(rest[0], consume: true, expected: review)
        // Approval has already been collected, so execute must not ask a second time.
        var confirmed = args; confirmed.flags.insert("yes")
        try CleanCommand(app: App(args: confirmed)).execute(report: plan.report, picked: plan.items, mode: mode)
    }
}
