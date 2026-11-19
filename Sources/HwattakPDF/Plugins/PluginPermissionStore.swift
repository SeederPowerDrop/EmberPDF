// SPDX-License-Identifier: MPL-2.0

import Foundation

/// Host-owned approvals, separate from a package's self-declared capabilities.
/// Approval belongs to the reviewed manifest bytes. A later disk refresh never
/// upgrades it, and explicit user denials survive reviewed package updates.
@MainActor
final class PluginPermissionStore {
    static let defaultsKey = "plugins.permissionApprovals.v1"
    private static let maximumBytes = 128 * 1_024

    private struct Record: Codable {
        let manifestDigest: String
        var granted: Set<PluginCapability>
        var denied: Set<PluginCapability>
    }

    private struct Archive: Codable {
        let schemaVersion: Int
        var records: [String: Record]
    }

    let needsLegacyMigration: Bool
    private let defaults: UserDefaults
    private var records: [String: Record]

    init(defaults: UserDefaults) {
        self.defaults = defaults
        // Missing and malformed are deliberately different: corrupt approval
        // data must fail closed, not silently become a new legacy migration.
        needsLegacyMigration = defaults.object(forKey: Self.defaultsKey) == nil
        if let data = defaults.data(forKey: Self.defaultsKey),
           data.count <= Self.maximumBytes,
           let archive = try? JSONDecoder().decode(Archive.self, from: data),
           archive.schemaVersion == 1,
           archive.records.count <= HwattakPluginLimits.maximumInstalledPluginCount,
           archive.records.values.allSatisfy({ record in
               record.manifestDigest.count == 64
                   && record.manifestDigest.allSatisfy { $0.isASCII && $0.isHexDigit }
                   && record.granted.isDisjoint(with: record.denied)
           }) {
            records = archive.records
        } else {
            records = [:]
        }
    }

    func migrateExistingInstallations(_ plugins: [InstalledPlugin]) {
        guard needsLegacyMigration else { return }
        for plugin in plugins.prefix(HwattakPluginLimits.maximumInstalledPluginCount) {
            // Only formats supported before granular approvals existed can
            // inherit legacy consent. A package planted on disk must not gain
            // newly introduced host panels or executable code on first launch.
            guard (1...3).contains(plugin.manifest.schemaVersion) else { continue }
            approveReviewedManifest(plugin.manifest, digest: plugin.manifestDigest, persist: false)
        }
        persist()
    }

    func hasReviewedManifest(identifier: String, digest: String) -> Bool {
        records[identifier]?.manifestDigest == digest
    }

    func isGranted(_ capability: PluginCapability, identifier: String, digest: String) -> Bool {
        guard let record = records[identifier], record.manifestDigest == digest else { return false }
        return record.granted.contains(capability) && !record.denied.contains(capability)
    }

    func approveReviewedManifest(_ manifest: PluginManifest, digest: String, persist: Bool = true) {
        let denied = records[manifest.identifier]?.denied ?? []
        records[manifest.identifier] = Record(
            manifestDigest: digest,
            granted: Set(manifest.capabilities).subtracting(denied),
            denied: denied
        )
        if persist { self.persist() }
    }

    func setGranted(_ capability: PluginCapability, granted: Bool, identifier: String, digest: String) throws {
        guard var record = records[identifier], record.manifestDigest == digest else {
            throw PluginSystemError.actionUnavailable(L10n.string(
                "plugins.permissions.review_required",
                defaultValue: "설치 파일이 변경되었습니다. 패키지를 다시 검토하고 설치해 주세요."
            ))
        }
        if granted {
            record.denied.remove(capability)
            record.granted.insert(capability)
        } else {
            record.granted.remove(capability)
            record.denied.insert(capability)
        }
        records[identifier] = record
        persist()
    }

    func remove(identifier: String) {
        records.removeValue(forKey: identifier)
        persist()
    }

    func discardApprovals(where shouldDiscard: (String) -> Bool) {
        records = records.filter { !shouldDiscard($0.key) }
    }

    private func persist() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(Archive(schemaVersion: 1, records: records)),
              data.count <= Self.maximumBytes else { return }
        // Persist the empty archive too. Absence would re-enable migration on
        // next launch and could turn a revoked/unknown install into approval.
        defaults.set(data, forKey: Self.defaultsKey)
    }
}
