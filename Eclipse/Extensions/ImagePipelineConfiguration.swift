import Foundation
#if canImport(Kingfisher)
import Kingfisher
enum KingfisherImageCacheConfigurator {
    private static var didConfigure = false
    private static let memoryCostLimit = 96 * 1024 * 1024
    private static let memoryCountLimit = 192

    static func configureIfNeeded() {
        guard !didConfigure else { return }
        didConfigure = true

#if os(macOS)
        if let directory = FileManager.default.eclipseCachesDirectories.first {
            do {
                KingfisherManager.shared.cache = try ImageCache(name: "EclipseImages", cacheDirectoryURL: directory)
            } catch {
                KingfisherManager.shared.defaultOptions.append(.cacheMemoryOnly)
            }
            let shared = URLCache.shared
            URLCache.shared = URLCache(memoryCapacity: shared.memoryCapacity, diskCapacity: shared.diskCapacity,
                directory: directory.appendingPathComponent("Network", isDirectory: true))
        }
        let cache = KingfisherManager.shared.cache
#else
        let cache = ImageCache.default
#endif
        var memoryConfig = cache.memoryStorage.config
        memoryConfig.totalCostLimit = memoryCostLimit
        memoryConfig.countLimit = memoryCountLimit
        cache.memoryStorage.config = memoryConfig
    }
}
#endif

#if canImport(Nuke)
import Nuke
enum ReaderImagePipelineConfigurator {
    private static var didConfigure = false

    static func configureIfNeeded() {
        guard !didConfigure else { return }
        didConfigure = true

        DataLoader.sharedUrlCache.diskCapacity = 0
        DataLoader.sharedUrlCache.memoryCapacity = 0

        let pipeline = ImagePipeline {
            let configuration = URLSessionConfiguration.default
            configuration.urlCache = nil
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            configuration.httpShouldSetCookies = false
            configuration.httpCookieStorage = nil

#if os(macOS)
            let dataCache = FileManager.default.eclipseCachesDirectories.first.flatMap {
                try? DataCache(path: $0.appendingPathComponent("ReaderImages", isDirectory: true))
            }
#else
            let dataCache = try? DataCache(name: "app.eclipse.soupy.reader.datacache")
#endif
            dataCache?.sizeLimit = 500 * 1024 * 1024

            let imageCache = Nuke.ImageCache()
            imageCache.costLimit = 100 * 1024 * 1024

            $0.dataCache = dataCache
            $0.imageCache = imageCache
            $0.dataLoader = DataLoader(configuration: configuration)
            $0.dataCachePolicy = .storeOriginalData
            $0.isStoringPreviewsInMemoryCache = false
        }

        ImagePipeline.shared = pipeline
        ReaderLogger.shared.log("Configured reader image pipeline cache data=500MB image=100MB", type: "ReaderPerf")
    }
}
#endif
