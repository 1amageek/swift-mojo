import Foundation

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

enum RuntimeWorkerAcceptancePOSIX {
    struct FileState: Equatable, Sendable {
        enum Kind: Equatable, Sendable {
            case directory
            case regular
            case symbolicLink
            case other
        }

        let kind: Kind
        let device: UInt64
        let inode: UInt64
        let mode: UInt32
        let byteCount: Int64
        let modificationSeconds: Int64
        let modificationNanoseconds: Int64
        let statusChangeSeconds: Int64
        let statusChangeNanoseconds: Int64
    }

    static func withRepositoryRoot<Result>(
        at repositoryRoot: URL,
        _ body: (Int32, FileState) throws -> Result
    ) throws -> Result {
        let path = repositoryRoot.standardizedFileURL.path
        let descriptor = path.withCString {
            open(
                $0,
                O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
            )
        }
        guard descriptor >= 0 else {
            let failure = currentFailure()
            if failure.code == ELOOP
                || (failure.code == ENOTDIR
                    && isSymbolicLinkAtAbsolutePath(path))
            {
                throw RuntimeWorkerAcceptanceSourceIdentityError.symbolicLink(
                    path
                )
            }
            throw RuntimeWorkerAcceptanceSourceIdentityError.invalidRoot(path)
        }

        return try withOwnedDescriptor(descriptor, path: path) { descriptor in
            let initial = try state(of: descriptor, path: path)
            guard initial.kind == .directory else {
                throw RuntimeWorkerAcceptanceSourceIdentityError.invalidRoot(
                    path
                )
            }
            let result = try body(descriptor, initial)
            let final = try state(of: descriptor, path: path)
            let current = try stateAtAbsolutePath(path)
            guard initial == final, initial == current else {
                throw
                    RuntimeWorkerAcceptanceSourceIdentityError
                    .changedDuringRead(path)
            }
            return result
        }
    }

    static func withDirectory<Result>(
        at relativePath: String,
        from rootDescriptor: Int32,
        _ body: (Int32, FileState) throws -> Result
    ) throws -> Result {
        let components = relativePath.split(separator: "/").map(String.init)
        return try withDirectory(
            components: components[...],
            displayPath: "",
            parentDescriptor: rootDescriptor,
            body
        )
    }

    static func withChildDirectory<Result>(
        named name: String,
        displayPath: String,
        from parentDescriptor: Int32,
        _ body: (Int32, FileState) throws -> Result
    ) throws -> Result {
        let initial = try stateAt(
            name,
            displayPath: displayPath,
            parentDescriptor: parentDescriptor
        )
        switch initial.kind {
        case .directory:
            break
        case .symbolicLink:
            throw RuntimeWorkerAcceptanceSourceIdentityError.symbolicLink(
                displayPath
            )
        case .regular, .other:
            throw RuntimeWorkerAcceptanceSourceIdentityError.nonRegularEntry(
                displayPath
            )
        }

        let descriptor = name.withCString {
            openat(
                parentDescriptor,
                $0,
                O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
            )
        }
        guard descriptor >= 0 else {
            let failure = currentFailure()
            if failure.code == ELOOP {
                throw RuntimeWorkerAcceptanceSourceIdentityError.symbolicLink(
                    displayPath
                )
            }
            throw RuntimeWorkerAcceptanceSourceIdentityError.changedDuringRead(
                displayPath
            )
        }

        return try withOwnedDescriptor(
            descriptor,
            path: displayPath
        ) { descriptor in
            let opened = try state(of: descriptor, path: displayPath)
            guard initial == opened else {
                throw
                    RuntimeWorkerAcceptanceSourceIdentityError
                    .changedDuringRead(displayPath)
            }
            let result = try body(descriptor, opened)
            let final = try state(of: descriptor, path: displayPath)
            let current = try stateAt(
                name,
                displayPath: displayPath,
                parentDescriptor: parentDescriptor
            )
            guard initial == final, initial == current else {
                throw
                    RuntimeWorkerAcceptanceSourceIdentityError
                    .changedDuringRead(displayPath)
            }
            return result
        }
    }

    static func withRegularFile<Result>(
        at relativePath: String,
        from rootDescriptor: Int32,
        _ body: (Int32, FileState) throws -> Result
    ) throws -> Result {
        let components = relativePath.split(separator: "/").map(String.init)
        guard let name = components.last else {
            throw RuntimeWorkerAcceptanceSourceIdentityError.invalidPath(
                relativePath
            )
        }
        return try withDirectory(
            components: components.dropLast()[...],
            displayPath: "",
            parentDescriptor: rootDescriptor
        ) { parentDescriptor, _ in
            try withRegularFile(
                named: name,
                displayPath: relativePath,
                from: parentDescriptor,
                body
            )
        }
    }

    static func withRegularFile<Result>(
        named name: String,
        displayPath: String,
        from parentDescriptor: Int32,
        _ body: (Int32, FileState) throws -> Result
    ) throws -> Result {
        let initial = try stateAt(
            name,
            displayPath: displayPath,
            parentDescriptor: parentDescriptor
        )
        switch initial.kind {
        case .regular:
            break
        case .symbolicLink:
            throw RuntimeWorkerAcceptanceSourceIdentityError.symbolicLink(
                displayPath
            )
        case .directory, .other:
            throw RuntimeWorkerAcceptanceSourceIdentityError.nonRegularEntry(
                displayPath
            )
        }

        let descriptor = name.withCString {
            openat(parentDescriptor, $0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard descriptor >= 0 else {
            let failure = currentFailure()
            if failure.code == ELOOP {
                throw RuntimeWorkerAcceptanceSourceIdentityError.symbolicLink(
                    displayPath
                )
            }
            throw RuntimeWorkerAcceptanceSourceIdentityError.changedDuringRead(
                displayPath
            )
        }

        return try withOwnedDescriptor(
            descriptor,
            path: displayPath
        ) { descriptor in
            let opened = try state(of: descriptor, path: displayPath)
            guard initial == opened, opened.kind == .regular else {
                throw
                    RuntimeWorkerAcceptanceSourceIdentityError
                    .changedDuringRead(displayPath)
            }
            let result = try body(descriptor, opened)
            let final = try state(of: descriptor, path: displayPath)
            let current = try stateAt(
                name,
                displayPath: displayPath,
                parentDescriptor: parentDescriptor
            )
            guard initial == final, initial == current else {
                throw
                    RuntimeWorkerAcceptanceSourceIdentityError
                    .changedDuringRead(displayPath)
            }
            return result
        }
    }

    static func directoryEntryNames(
        descriptor: Int32,
        path: String
    ) throws -> [String] {
        let duplicate = fcntl(descriptor, F_DUPFD_CLOEXEC, 0)
        guard duplicate >= 0 else {
            throw RuntimeWorkerAcceptanceSourceIdentityError.unreadableFile(
                path: path,
                detail: currentFailure().description
            )
        }

        guard let stream = fdopendir(duplicate) else {
            let openFailure = currentFailure()
            let closeResult = close(duplicate)
            if closeResult != 0 {
                let closeFailure = currentFailure()
                throw RuntimeWorkerAcceptanceSourceIdentityError.closeFailed(
                    path: path,
                    detail: openFailure.description
                        + "; close: " + closeFailure.description
                )
            }
            throw RuntimeWorkerAcceptanceSourceIdentityError.unreadableFile(
                path: path,
                detail: openFailure.description
            )
        }

        var names: [String] = []
        var operationFailure: Error?
        while operationFailure == nil {
            errno = 0
            guard let entry = readdir(stream) else {
                if errno != 0 {
                    operationFailure =
                        RuntimeWorkerAcceptanceSourceIdentityError
                        .unreadableFile(
                            path: path,
                            detail: currentFailure().description
                        )
                }
                break
            }
            let nameBytes = withUnsafePointer(to: entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(
                    to: UInt8.self,
                    capacity: MemoryLayout.size(ofValue: entry.pointee.d_name)
                ) {
                    let bytes = UnsafeBufferPointer(
                        start: $0,
                        count: MemoryLayout.size(ofValue: entry.pointee.d_name)
                    )
                    return Array(bytes.prefix { $0 != 0 })
                }
            }
            guard !nameBytes.isEmpty,
                nameBytes.allSatisfy({ $0 < 128 }),
                let name = String(bytes: nameBytes, encoding: .utf8)
            else {
                operationFailure =
                    RuntimeWorkerAcceptanceSourceIdentityError.invalidPath(
                        path + "/<non-ASCII-entry>"
                    )
                continue
            }
            if name != ".", name != ".." {
                names.append(name)
            }
        }

        let closeResult = closedir(stream)
        if closeResult != 0 {
            let closeFailure = currentFailure()
            if let operationFailure {
                throw RuntimeWorkerAcceptanceSourceIdentityError.closeFailed(
                    path: path,
                    detail: String(describing: operationFailure)
                        + "; closedir: " + closeFailure.description
                )
            }
            throw RuntimeWorkerAcceptanceSourceIdentityError.closeFailed(
                path: path,
                detail: closeFailure.description
            )
        }
        if let operationFailure {
            throw operationFailure
        }
        return names
    }

    static func stateAt(
        _ name: String,
        displayPath: String,
        parentDescriptor: Int32
    ) throws -> FileState {
        var value = stat()
        let result = name.withCString {
            fstatat(
                parentDescriptor,
                $0,
                &value,
                AT_SYMLINK_NOFOLLOW
            )
        }
        guard result == 0 else {
            let failure = currentFailure()
            if failure.code == ENOENT || failure.code == ENOTDIR {
                throw RuntimeWorkerAcceptanceSourceIdentityError.missingEntry(
                    displayPath
                )
            }
            throw RuntimeWorkerAcceptanceSourceIdentityError.unreadableFile(
                path: displayPath,
                detail: failure.description
            )
        }
        return fileState(value)
    }

    static func rewind(descriptor: Int32, path: String) throws {
        guard lseek(descriptor, 0, SEEK_SET) == 0 else {
            throw RuntimeWorkerAcceptanceSourceIdentityError.unreadableFile(
                path: path,
                detail: currentFailure().description
            )
        }
    }

    static func read(
        descriptor: Int32,
        into buffer: UnsafeMutableRawBufferPointer,
        path: String
    ) throws -> Int {
        while true {
            let result = darwinOrGlibcRead(
                descriptor,
                buffer.baseAddress,
                buffer.count
            )
            if result >= 0 {
                return result
            }
            if errno == EINTR {
                continue
            }
            throw RuntimeWorkerAcceptanceSourceIdentityError.unreadableFile(
                path: path,
                detail: currentFailure().description
            )
        }
    }

    private static func withDirectory<Result>(
        components: ArraySlice<String>,
        displayPath: String,
        parentDescriptor: Int32,
        _ body: (Int32, FileState) throws -> Result
    ) throws -> Result {
        guard let component = components.first else {
            return try body(
                parentDescriptor,
                try state(of: parentDescriptor, path: displayPath)
            )
        }
        let childPath =
            displayPath.isEmpty
            ? component
            : displayPath + "/" + component
        return try withChildDirectory(
            named: component,
            displayPath: childPath,
            from: parentDescriptor
        ) { childDescriptor, _ in
            try withDirectory(
                components: components.dropFirst(),
                displayPath: childPath,
                parentDescriptor: childDescriptor,
                body
            )
        }
    }

    private static func state(
        of descriptor: Int32,
        path: String
    ) throws -> FileState {
        var value = stat()
        guard fstat(descriptor, &value) == 0 else {
            throw RuntimeWorkerAcceptanceSourceIdentityError.unreadableFile(
                path: path,
                detail: currentFailure().description
            )
        }
        return fileState(value)
    }

    private static func stateAtAbsolutePath(_ path: String) throws -> FileState {
        var value = stat()
        let result = path.withCString { lstat($0, &value) }
        guard result == 0 else {
            throw RuntimeWorkerAcceptanceSourceIdentityError.changedDuringRead(
                path
            )
        }
        return fileState(value)
    }

    private static func isSymbolicLinkAtAbsolutePath(_ path: String) -> Bool {
        var value = stat()
        let result = path.withCString { lstat($0, &value) }
        guard result == 0 else { return false }
        return fileState(value).kind == .symbolicLink
    }

    private static func fileState(_ value: stat) -> FileState {
        let mode = UInt32(value.st_mode)
        let kind: FileState.Kind
        switch mode & UInt32(S_IFMT) {
        case UInt32(S_IFDIR):
            kind = .directory
        case UInt32(S_IFREG):
            kind = .regular
        case UInt32(S_IFLNK):
            kind = .symbolicLink
        default:
            kind = .other
        }
        #if canImport(Darwin)
            let modificationSeconds = Int64(value.st_mtimespec.tv_sec)
            let modificationNanoseconds = Int64(value.st_mtimespec.tv_nsec)
            let statusChangeSeconds = Int64(value.st_ctimespec.tv_sec)
            let statusChangeNanoseconds = Int64(value.st_ctimespec.tv_nsec)
        #elseif canImport(Glibc)
            let modificationSeconds = Int64(value.st_mtim.tv_sec)
            let modificationNanoseconds = Int64(value.st_mtim.tv_nsec)
            let statusChangeSeconds = Int64(value.st_ctim.tv_sec)
            let statusChangeNanoseconds = Int64(value.st_ctim.tv_nsec)
        #endif
        return FileState(
            kind: kind,
            device: UInt64(truncatingIfNeeded: value.st_dev),
            inode: UInt64(truncatingIfNeeded: value.st_ino),
            mode: mode,
            byteCount: Int64(value.st_size),
            modificationSeconds: modificationSeconds,
            modificationNanoseconds: modificationNanoseconds,
            statusChangeSeconds: statusChangeSeconds,
            statusChangeNanoseconds: statusChangeNanoseconds
        )
    }

    private static func withOwnedDescriptor<Output>(
        _ descriptor: Int32,
        path: String,
        _ body: (Int32) throws -> Output
    ) throws -> Output {
        let result: Swift.Result<Output, Error>
        do {
            result = .success(try body(descriptor))
        } catch {
            result = .failure(error)
        }

        let closeResult = close(descriptor)
        if closeResult != 0 {
            let failure = currentFailure()
            switch result {
            case .success:
                throw RuntimeWorkerAcceptanceSourceIdentityError.closeFailed(
                    path: path,
                    detail: failure.description
                )
            case .failure(let operationError):
                throw RuntimeWorkerAcceptanceSourceIdentityError.closeFailed(
                    path: path,
                    detail: String(describing: operationError)
                        + "; close: " + failure.description
                )
            }
        }
        return try result.get()
    }

    private struct POSIXFailure {
        let code: Int32
        let message: String

        var description: String {
            "errno=\(code) \(message)"
        }
    }

    private static func currentFailure() -> POSIXFailure {
        let code = errno
        return POSIXFailure(code: code, message: String(cString: strerror(code)))
    }
}

@inline(__always)
private func darwinOrGlibcRead(
    _ descriptor: Int32,
    _ buffer: UnsafeMutableRawPointer?,
    _ count: Int
) -> Int {
    #if canImport(Darwin)
        Darwin.read(descriptor, buffer, count)
    #elseif canImport(Glibc)
        Glibc.read(descriptor, buffer, count)
    #endif
}
