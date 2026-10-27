import Foundation

/// Serializes writes into a project package with whoever else owns it.
///
/// While the app has a package open as a document, NSDocument's save swaps the whole package
/// directory for a new one built from a listing taken a moment before. A file renamed into
/// `originals/` or `thumbs/` between that listing and the swap is deleted by the swap: for an
/// original that is real data loss (the package copy is the only one once the photo leaves Photos).
/// The app therefore gives its `ProjectPackage` a coordinator (NSDocument file access plus
/// NSFileCoordinator), so each such write waits for a running save and a save waits for the write.
///
/// `ProjectPackage` calls `coordinateWriting` once per stored original or thumbnail with the
/// DESTINATION file URL. The bytes are already staged in a temporary file outside the package when
/// it is called, so `write` is quick (a rename): implementations may block in it but must run it at
/// most once, pass it the URL to write to (a coordinator may hand out a different one) and
/// propagate its errors. `write` is escaping because the system APIs an implementation hands it to
/// (NSFileCoordinator, NSDocument file access) keep their blocks beyond the call.
///
/// `save` (album.json) is never coordinated through this: the open document owns album.json, and
/// nothing may call `ProjectPackage.save` while a document is open.
public protocol PackageWriteCoordinator: Sendable {
    func coordinateWriting(at url: URL, _ write: @escaping @Sendable (URL) throws -> Void) throws
}

/// No coordination: writes straight away. The default for the CLI, tests and packages that no
/// document has open.
public struct DirectPackageWrites: PackageWriteCoordinator {
    public init() {}

    public func coordinateWriting(at url: URL, _ write: @escaping @Sendable (URL) throws -> Void) throws {
        try write(url)
    }
}
