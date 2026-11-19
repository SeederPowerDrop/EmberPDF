// SPDX-License-Identifier: MPL-2.0

import CryptoKit
import Darwin
import Foundation

struct PluginPackageValidator {
    static let manifestFileName = "manifest.json"
    static let installationRecordFileName = "installation.json"
    static let maximumInstallationRecordBytes = 32 * 1_024
    static let allowedSourceFiles: Set<String> = [
        manifestFileName,
        "README.md",
        "LICENSE",
        "LICENSE.md",
        "icon.png",
        "main.js"
    ]

    private let fileManager: FileManager
    private let manifestValidator: PluginManifestValidator

    init(
        fileManager: FileManager = .default,
        hostVersion: String = PluginHost.currentVersion
    ) {
        self.fileManager = fileManager
        manifestValidator = PluginManifestValidator(hostVersion: hostVersion)
    }

    func inspectSourcePackage(at sourceURL: URL) throws -> PluginPackageInspection {
        try inspectPackage(at: sourceURL, isInstalledPackage: false)
    }

    func inspectInstalledPackage(at packageURL: URL) throws -> InstalledPackageInspection {
        let inspection = try inspectPackage(at: packageURL, isInstalledPackage: true)
        guard let recordData = inspection.filePayloads[Self.installationRecordFileName] else {
            throw PluginSystemError.invalidPackage("installation record is missing")
        }
        let record: PluginInstallationRecord
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            record = try decoder.decode(PluginInstallationRecord.self, from: recordData)
        } catch {
            throw PluginSystemError.invalidPackage("installation record is invalid")
        }
        guard
            record.schemaVersion == HwattakPluginLimits.installationRecordSchemaVersion,
            record.manifestSHA256 == inspection.manifestDigest,
            packageURL.deletingPathExtension().lastPathComponent == inspection.manifest.identifier
        else {
            throw PluginSystemError.invalidPackage("installed manifest integrity check failed")
        }
        return InstalledPackageInspection(package: inspection, record: record)
    }

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func inspectPackage(
        at sourceURL: URL,
        isInstalledPackage: Bool
    ) throws -> PluginPackageInspection {
        guard sourceURL.pathExtension.lowercased() == "hwattakplugin" else {
            throw PluginSystemError.invalidPackage("package name must end in .hwattakplugin")
        }
        let rootValues: URLResourceValues
        do {
            rootValues = try sourceURL.resourceValues(
                forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey]
            )
        } catch {
            throw PluginSystemError.invalidPackage("package cannot be inspected")
        }
        guard rootValues.isDirectory == true, rootValues.isSymbolicLink != true else {
            throw PluginSystemError.invalidPackage("package must be a real directory, not a link")
        }
        // Pin the inspected package directory. Later leaf reads use openat so
        // renaming/replacing the pathname cannot redirect them into another
        // directory. O_NOFOLLOW also closes a root-link replacement race.
        let directoryDescriptor = sourceURL.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard directoryDescriptor >= 0 else {
            throw PluginSystemError.invalidPackage("package directory cannot be opened safely")
        }
        defer { close(directoryDescriptor) }

        let maximumFiles = HwattakPluginLimits.maximumPackageFileCount
            + (isInstalledPackage ? 1 : 0)
        let resourceKeys: [URLResourceKey] = [
            .isRegularFileKey,
            .isDirectoryKey,
            .isSymbolicLinkKey,
            .fileSizeKey
        ]
        var enumerationFailed = false
        guard let enumerator = fileManager.enumerator(
            at: sourceURL,
            includingPropertiesForKeys: resourceKeys,
            options: [.skipsSubdirectoryDescendants],
            errorHandler: { _, _ in
                enumerationFailed = true
                return false
            }
        ) else {
            throw PluginSystemError.invalidPackage("package contents cannot be read")
        }
        var entries: [URL] = []
        for case let entry as URL in enumerator {
            entries.append(entry)
            guard entries.count <= maximumFiles else {
                throw PluginSystemError.invalidPackage("package contains too many files")
            }
        }
        guard !enumerationFailed else {
            throw PluginSystemError.invalidPackage("package contents cannot be read")
        }
        guard !entries.isEmpty else {
            throw PluginSystemError.invalidPackage("package contains too many files")
        }
        let allowedFiles = Self.allowedSourceFiles.union(
            isInstalledPackage ? [Self.installationRecordFileName] : []
        )

        var totalBytes = 0
        var payloads: [String: Data] = [:]
        for entry in entries {
            let name = entry.lastPathComponent
            guard
                allowedFiles.contains(name),
                !name.hasPrefix("."),
                name == name.precomposedStringWithCanonicalMapping
            else {
                throw PluginSystemError.invalidPackage("unsupported package entry: \(name)")
            }
            let values: URLResourceValues
            do {
                values = try entry.resourceValues(
                    forKeys: [
                        .isRegularFileKey,
                        .isDirectoryKey,
                        .isSymbolicLinkKey,
                        .fileSizeKey
                    ]
                )
            } catch {
                throw PluginSystemError.invalidPackage("package entry cannot be inspected: \(name)")
            }
            guard
                values.isRegularFile == true,
                values.isDirectory != true,
                values.isSymbolicLink != true,
                let fileSize = values.fileSize,
                fileSize >= 0
            else {
                throw PluginSystemError.invalidPackage("package entries must be regular files")
            }
            let perFileLimit: Int
            switch name {
            case Self.manifestFileName:
                perFileLimit = HwattakPluginLimits.maximumManifestBytes
            case "main.js":
                perFileLimit = 128 * 1_024
            case Self.installationRecordFileName:
                perFileLimit = Self.maximumInstallationRecordBytes
            default:
                perFileLimit = HwattakPluginLimits.maximumAuxiliaryFileBytes
            }
            guard fileSize <= perFileLimit else {
                throw PluginSystemError.invalidPackage("\(name) exceeds its size limit")
            }

            let capturedData: Data?
            if !isInstalledPackage || name == Self.manifestFileName || name == Self.installationRecordFileName || name == "main.js" {
                let data = try Self.boundedRegularFileData(
                    directoryDescriptor: directoryDescriptor,
                    filename: name,
                    maximumBytes: perFileLimit,
                    label: name
                )
                // Reconcile the preflight metadata with the exact bytes used
                // for review and installation. A package being rewritten
                // concurrently must be selected again instead of bypassing the
                // aggregate limit with stale `fileSize` values.
                guard data.count == fileSize else {
                    throw PluginSystemError.invalidPackage(
                        "\(name) changed while it was being read"
                    )
                }
                capturedData = data
            } else {
                capturedData = nil
            }

            // installation.json is small host-owned integrity metadata, not a
            // source-package payload. Keeping its separate 32 KiB ceiling lets
            // a valid source package use the advertised full 2 MiB budget.
            let measuredPackageBytes = name == Self.installationRecordFileName
                ? 0
                : (capturedData?.count ?? fileSize)
            let (newTotal, overflow) = totalBytes.addingReportingOverflow(
                measuredPackageBytes
            )
            guard
                !overflow,
                newTotal <= HwattakPluginLimits.maximumPackageBytes
            else {
                throw PluginSystemError.invalidPackage("package exceeds its total size limit")
            }
            totalBytes = newTotal

            // Installed auxiliary files never affect behavior and need not be
            // retained. Capture manifest + record through the same pinned
            // directory; source installation captures every allowed byte.
            if let capturedData {
                payloads[name] = capturedData
            }
        }

        guard let manifestData = payloads[Self.manifestFileName] else {
            throw PluginSystemError.invalidPackage("manifest.json is missing")
        }
        if let icon = payloads["icon.png"] {
            let pngSignature = Data([137, 80, 78, 71, 13, 10, 26, 10])
            guard icon.starts(with: pngSignature) else {
                throw PluginSystemError.invalidPackage("icon.png is not a PNG file")
            }
        }
        let manifest = try manifestValidator.decodeAndValidate(manifestData)
        let scripts = manifest.actions.filter { $0.output == .scriptPanel }
        if !scripts.isEmpty || manifest.runtime != nil {
            guard let source = payloads["main.js"], !source.isEmpty,
                  source.count <= 128 * 1_024, String(data: source, encoding: .utf8) != nil,
                  scripts.allSatisfy({ $0.scriptSHA256 == Self.sha256Hex(source) }),
                  manifest.runtime.map({ $0.sha256 == Self.sha256Hex(source) }) ?? true else {
                throw PluginSystemError.invalidPackage("main.js does not match its reviewed digest or size/encoding limit")
            }
        } else if payloads["main.js"] != nil {
            throw PluginSystemError.invalidPackage("main.js requires a schema 5 scriptPanel action or schema 6 runtime")
        }
        return PluginPackageInspection(
            sourceURL: sourceURL,
            manifest: manifest,
            manifestDigest: Self.sha256Hex(manifestData),
            fileCount: entries.count,
            totalBytes: totalBytes,
            filePayloads: payloads
        )
    }

    static func boundedRegularFileData(
        directoryDescriptor: Int32,
        filename: String,
        maximumBytes: Int,
        label: String
    ) throws -> Data {
        guard !filename.isEmpty, filename != ".", filename != "..",
              !filename.contains("/"), !filename.contains("\0"), maximumBytes >= 0 else {
            throw PluginSystemError.invalidPackage("invalid package file name")
        }
        // Nonblocking opens prevent a regular-file-to-FIFO swap from hanging
        // the UI; fstat examines the opened object, not stale URL metadata.
        let descriptor = openat(directoryDescriptor, filename, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw PluginSystemError.invalidPackage("\(label) cannot be read")
        }
        defer { close(descriptor) }
        var before = stat()
        guard fstat(descriptor, &before) == 0,
              (before.st_mode & S_IFMT) == S_IFREG,
              before.st_size >= 0, before.st_size <= maximumBytes else {
            throw PluginSystemError.invalidPackage("\(label) must be a bounded regular file")
        }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else { throw PluginSystemError.invalidPackage("\(label) cannot be read") }
            if count == 0 { break }
            guard count <= maximumBytes - data.count else {
                throw PluginSystemError.invalidPackage("\(label) changed while it was being read")
            }
            data.append(contentsOf: buffer.prefix(count))
        }
        var after = stat()
        guard fstat(descriptor, &after) == 0,
              before.st_dev == after.st_dev, before.st_ino == after.st_ino,
              before.st_size == after.st_size, after.st_size == data.count,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
              before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec else {
            throw PluginSystemError.invalidPackage("\(label) changed while it was being read")
        }
        return data
    }
}

struct InstalledPackageInspection {
    let package: PluginPackageInspection
    let record: PluginInstallationRecord
}
