import Foundation
import SwiftData

/// Versioned schema (BackendSchema › Migrations). Add `AzurePimSchemaV2` + a migration stage for changes.
public enum AzurePimSchemaV1: VersionedSchema {
    public static let versionIdentifier = Schema.Version(1, 0, 0)
    public static var models: [any PersistentModel.Type] {
        [Account.self, EligibleRole.self, ActiveAssignment.self, Favorite.self, ActivationRecord.self, AppSettings.self]
    }
}

public enum AzurePimMigrationPlan: SchemaMigrationPlan {
    public static var schemas: [any VersionedSchema.Type] { [AzurePimSchemaV1.self] }
    public static var stages: [MigrationStage] { [] }
}

public enum AzurePimStore {
    /// Default on-disk location: ~/Library/Application Support/AzurePim/AzurePim.store
    public static var defaultURL: URL {
        URL.applicationSupportDirectory.appending(path: "AzurePim", directoryHint: .isDirectory)
            .appending(path: "AzurePim.store")
    }

    public static func makeContainer(inMemory: Bool = false, url: URL = defaultURL) throws -> ModelContainer {
        let schema = Schema(versionedSchema: AzurePimSchemaV1.self)
        let config: ModelConfiguration
        if inMemory {
            config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        } else {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            config = ModelConfiguration(schema: schema, url: url)
        }
        return try ModelContainer(for: schema, migrationPlan: AzurePimMigrationPlan.self, configurations: config)
    }

    /// Seed: one AppSettings row (BackendSchema › Seed data). Returns the existing or new row.
    @discardableResult
    public static func settings(in context: ModelContext) throws -> AppSettings {
        if let existing = try context.fetch(FetchDescriptor<AppSettings>()).first { return existing }
        let settings = AppSettings()
        context.insert(settings)
        try context.save()
        return settings
    }
}
