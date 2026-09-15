import CoreData
import XCTest
@testable import EclipseMac

final class MacSourcePersistenceTests: XCTestCase {
    @MainActor
    func testBundledModelDurablyStoresEverySourceEntity() throws {
        let bundle = Bundle(for: EclipseMacApp.self)
        let modelURL = try XCTUnwrap(bundle.url(forResource: "ServiceModels", withExtension: "momd"))
        let model = try XCTUnwrap(NSManagedObjectModel(contentsOf: modelURL))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("Sources.sqlite")
        let coordinator = NSPersistentStoreCoordinator(managedObjectModel: model)
        let store = try coordinator.addPersistentStore(ofType: NSSQLiteStoreType, configurationName: nil, at: url)
        let context = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
        context.persistentStoreCoordinator = coordinator
        let service = NSEntityDescription.insertNewObject(forEntityName: "ServiceEntity", into: context)
        service.setValue(UUID(), forKey: "id")
        service.setValue("Fixture Service", forKey: "jsonMetadata")
        service.setValue("function search() { return []; }", forKey: "jsScript")
        let addon = NSEntityDescription.insertNewObject(forEntityName: "StremioAddonEntity", into: context)
        addon.setValue(UUID(), forKey: "id")
        addon.setValue("https://fixture.example/manifest.json", forKey: "configuredURL")
        let sky = NSEntityDescription.insertNewObject(forEntityName: "SkyStreamStateEntity", into: context)
        sky.setValue("state-v1", forKey: "id")
        sky.setValue("{\"fixture\":true}", forKey: "jsonState")
        try context.save()
        context.reset()
        try coordinator.remove(store)
        let reopened = try coordinator.addPersistentStore(ofType: NSSQLiteStoreType, configurationName: nil, at: url)
        defer { try? coordinator.remove(reopened) }
        for entity in ["ServiceEntity", "StremioAddonEntity", "SkyStreamStateEntity"] {
            XCTAssertEqual(try context.count(for: NSFetchRequest<NSFetchRequestResult>(entityName: entity)), 1)
        }
        let request = NSFetchRequest<NSManagedObject>(entityName: "ServiceEntity")
        XCTAssertEqual(try context.fetch(request).first?.value(forKey: "jsScript") as? String,
            "function search() { return []; }")
    }
}
