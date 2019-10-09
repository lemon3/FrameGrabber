import AVKit
import Photos

class VideoManager {

    let asset: PHAsset

    private let imageManager: PHImageManager
    private(set) var imageRequest: PHImageManager.Request?
    private(set) var videoRequest: PHImageManager.Request?

    init(asset: PHAsset, imageManager: PHImageManager = .default()) {
        self.asset = asset
        self.imageManager = imageManager
    }

    deinit {
        cancelAllRequests()
    }

    func cancelAllRequests() {
        imageRequest = nil
        videoRequest = nil
    }

    // MARK: Poster Image/Video Generation

    /// Pending requests of this type are cancelled.
    /// The result handler is called asynchronously on the main thread.
    func posterImage(with size: CGSize, resultHandler: @escaping (UIImage?, PHImageManager.Info) -> ()) {
        let options = PHImageManager.ImageOptions(size: size, mode: .aspectFit, requestOptions: .default())
        imageRequest = imageManager.requestImage(for: asset, options: options, resultHandler: resultHandler)
    }

    /// Pending requests of this type are cancelled.
    /// If available, the item is served directly, otherwise downloaded from iCloud.
    /// Handlers are called asynchronously on the main thread.
    func downloadingPlayerItem(withOptions options: PHVideoRequestOptions? = .default(), progressHandler: @escaping (Double) -> (), resultHandler: @escaping (AVPlayerItem?, PHImageManager.Info) -> ()) {
        videoRequest = imageManager.requestAVAsset(for: asset, options: options, progressHandler: progressHandler) { asset, _, info in
            resultHandler(asset.flatMap(AVPlayerItem.init), info)
        }
    }
}
