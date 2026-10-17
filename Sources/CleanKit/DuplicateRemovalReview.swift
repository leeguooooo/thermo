import Foundation
import Darwin

public struct DuplicateRemovalReview: Codable, Sendable {
    public let keeper: String
    public let paths: [String]
    public let hash: String
    public let identities: [String:String]
    public let sizes: [String:Int64]
    public let incompletePaths: Set<String>
}
extension Duplicates {
    /// Explicit files only: verifies every byte and retains a named keeper. Moving later binds
    /// both the selected files and keeper identities, matching the App's duplicate basket.
    public static func reviewRemoval(paths: [String], keeping keeper: String) throws -> DuplicateRemovalReview {
        struct Failure: LocalizedError { let message: String; var errorDescription: String? { message } }
        guard !paths.isEmpty, Set(paths).count == paths.count, !paths.contains(keeper) else { throw Failure(message:"Choose unique duplicate paths and a separate file to keep.") }
        var identities: [String:String] = [:], sizes: [String:Int64] = [:], unknown = Set<String>(), inodes = Set<String>()
        var hash: String?
        for path in [keeper] + paths {
            var st = stat()
            guard lstat(path, &st) == 0, st.st_mode & S_IFMT == S_IFREG, st.st_uid == getuid(),
                  inodes.insert("\(st.st_dev):\(st.st_ino)").inserted, let identity = ManualRemoval.reviewIdentity(path),
                  let value = fullHash(path, cancellation: ScanCancellation(), expected: identity, size: Int64(st.st_size)) else {
                throw Failure(message:"A duplicate is unavailable, changed or is a hard-link alias; no files moved.")
            }
            if let hash, hash != value { throw Failure(message:"Selected files have different contents; no files moved.") }
            hash = value; identities[path] = identity
            if path != keeper {
                if let why = ManualRemoval.refusal(path) { throw Failure(message:why) }
                if let bytes = BulkWalk.fileSize(path)?.privateSize, bytes >= 0 { sizes[path] = bytes }
                else { sizes[path] = 0; unknown.insert(path) }
                guard ManualRemoval.reviewIdentity(path) == identity else { throw Failure(message:"A duplicate changed during measurement; compare it again.") }
            }
        }
        return .init(keeper: keeper, paths: paths, hash: hash!, identities: identities, sizes: sizes, incompletePaths: unknown)
    }
    public static func removeReviewed(_ review: DuplicateRemovalReview) -> CleanResult {
        ManualRemoval.trash(review.paths, sizes: review.sizes, incompletePaths: review.incompletePaths,
                            reviewIdentities: review.identities, requiredIdentities: [review.keeper:review.identities[review.keeper] ?? "invalid"])
    }
}
