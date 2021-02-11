import AVFoundation
import Combine
import ThumbnailSlider
import UIKit

protocol EditorViewControllerDelegate: class {
    func controller(_ controller: EditorViewController, handleSlideToPopGesture gesture: UIPanGestureRecognizer)
}

class EditorViewController: UIViewController {
    
    weak var delegate: EditorViewControllerDelegate?

    let videoController: VideoController
    let playbackController: PlaybackController
    var toolbarController: EditorToolbarController!
    let settings: UserDefaults
    
    init?(
        videoController: VideoController,
        playbackController: PlaybackController = .init(),
        settings: UserDefaults = .standard,
        delegate: EditorViewControllerDelegate? = nil,
        coder: NSCoder
    ) {
        self.videoController = videoController
        self.playbackController = playbackController
        self.settings = settings
        self.delegate = delegate
        super.init(coder: coder)
    }
    
    required init?(coder: NSCoder) {
        fatalError("Dependencies must be injected")
    }
    
    @IBOutlet private var zoomingPlayerView: ZoomingPlayerView!
    @IBOutlet private var progressView: ProgressView!
    private lazy var activityFeedbackGenerator = UINotificationFeedbackGenerator()
    private lazy var bindings = Set<AnyCancellable>()

    // MARK: Life Cycle

    override func viewDidLoad() {
        super.viewDidLoad()
        configureViews()
        loadPreviewImage()
        loadVideo()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        configureNavigationBar()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        videoController.cancelFrameExport()
    }
    
    @IBSegueAction func makeToolbarController(_ coder: NSCoder) -> EditorToolbarController? {
        self.toolbarController = EditorToolbarController(
            playbackController: playbackController,
            delegate: self,
            coder: coder
        )
        return toolbarController
    }

    override func prepare(for segue: UIStoryboardSegue, sender: Any?) {
        playbackController.pause()
        
        if let destination = segue.destination as? UINavigationController,
            let controller = destination.topViewController as? MetadataViewController {

            prepareForMetadataSegue(with: controller)
        }
        
        else if let destination = segue.destination as? UINavigationController,
           let controller = destination.topViewController as? ExportSettingsViewController {
         
            prepareForExportSettingsSegue(with: controller)
        }
    }

    private func prepareForMetadataSegue(with controller: MetadataViewController) {
        guard let video = videoController.video else { return }
        // TODO: Inject view model somewhere else.
        controller.viewModel = MetadataViewModel(video: video, source: videoController.source)
    }
    
    private func prepareForExportSettingsSegue(with controller: ExportSettingsViewController) {
        controller.delegate = self
    }
}

// MARK: - Configuring

private extension EditorViewController {

    func configureViews() {
        zoomingPlayerView.clipsToBounds = false
        zoomingPlayerView.player = playbackController.player
        zoomingPlayerView.posterImage = videoController.previewImage

        if #available(iOS 14.0, *) {
            navigationItem.rightBarButtonItem?.menu = EditorMoreMenu.menu { [weak self] selection in
                self?.performSegue(withIdentifier: selection.rawValue, sender: nil)
            }
        } else {
            navigationItem.rightBarButtonItem?.target = self
            navigationItem.rightBarButtonItem?.action = #selector(showMoreMenuAsAlertSheet)
        }

        configureNavigationBar()
        configureGestures()
        configureBindings()
    }

    func configureNavigationBar() {
        navigationController?.navigationBar.shadowImage = UIImage()
        navigationController?.navigationBar.applyToolbarShadow()
        toolbarController.toolbar.applyToolbarShadow()
    }

    func configureGestures() {
        let slideToPopRecognizer = UIPanGestureRecognizer(target: self, action: #selector(handleSlideToPopPan))
        zoomingPlayerView.addGestureRecognizer(slideToPopRecognizer)

        if let defaultPopRecognizer = navigationController?.interactivePopGestureRecognizer {
            slideToPopRecognizer.require(toFail: defaultPopRecognizer)
        }
    }

    @objc func handleSlideToPopPan(_ gesture: UIPanGestureRecognizer) {
        let canSlide = zoomingPlayerView.playerView.bounds.size != .zero

        guard !toolbarController.isScrubbing,
              canSlide else { return }

        delegate?.controller(self, handleSlideToPopGesture: gesture)
    }

    func presentOnTop(_ viewController: UIViewController, animated: Bool = true) {
        let presenter = navigationController ?? presentedViewController ?? self
        presenter.present(viewController, animated: animated)
    }

    func configureBindings() {
        playbackController
            .$status
            .filter { $0 == .failed }
            .removeDuplicates()
            .sink { [weak self] _ in
                self?.presentOnTop(UIAlertController.playbackFailed())
            }
            .store(in: &bindings)
    }
    
    @objc func showMoreMenuAsAlertSheet() {
        let alertController = EditorMoreMenu.alertController { [weak self] selection in
            self?.performSegue(withIdentifier: selection.rawValue, sender: nil)
        }
        
        alertController.popoverPresentationController?.barButtonItem = navigationItem.rightBarButtonItem
        presentOnTop(alertController)
    }

    // MARK: Loading Videos

    func loadPreviewImage() {
        let size = zoomingPlayerView.bounds.size.scaledToScreen

        videoController.loadPreviewImage(with: size) { [weak self] image in
            guard let image = image else { return }
            self?.zoomingPlayerView.posterImage = image
        }
    }

    func loadVideo() {
        showProgress(true, forActivity: .load, value: .determinate(0))

        videoController.loadVideo(progressHandler: { [weak self] progress in
            self?.progressView.setProgress(.determinate(Float(progress)), animated: true)
        }, completionHandler: { [weak self] result in
            self?.showProgress(false, forActivity: .load, value: .determinate(1))
            self?.handleVideoLoadingResult(result)
        })
    }

    func handleVideoLoadingResult(_ result: VideoController.VideoResult) {
        switch result {

        case .failure(let error):
            guard !error.isCocoaCancelledError else { return }
            presentOnTop(UIAlertController.videoLoadingFailed())

        case .success(let video):
            playbackController.asset = video
            startPlaying(from: videoController.source)
        }
    }
    
    // TODO: Fix this hack. This shouldn't be the the editor's responsibility.
    //
    // When the camera is dismissed, it disables all active video playback after a delay for some
    // reason :( However, we don't want to open the editor only after the camera is dismissed, we
    // want it to be ready right away. Just delay the playback for now.
    func startPlaying(from source: VideoSource) {
        if case .camera = videoController.source {
            let delay = 0.5
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                self.playbackController.play()
            }
        } else {
            playbackController.play()
        }
    }

    // MARK: Generating Images

    func generateFramesAndShare(for times: [CMTime]) {
        let activity = Activity(exportAction: settings.exportAction)
        showProgress(true, forActivity: activity, value: .indeterminate)

        videoController.generateAndExportFrames(for: times) { [weak self] status in
            self?.showProgress(false, forActivity: activity) {
                self?.handleFrameGenerationResult(status)
            }
        }
    }

    func handleFrameGenerationResult(_ status: FrameExport.Status) {
        switch status {
        
        case .progressed:
            break
            
        case .cancelled:
            activityFeedbackGenerator.notificationOccurred(.warning)
            
        case .failed:
            activityFeedbackGenerator.notificationOccurred(.error)
            presentOnTop(UIAlertController.frameExportFailed())
            
        case .succeeded(let urls):
            share(urls: urls, using: settings.exportAction)
        }
    }

    // todo: clean this up.
    func share(urls: [URL], using action: ExportAction) {
        switch action {
                
        case .showShareSheet:
            activityFeedbackGenerator.notificationOccurred(.success)
            
            let shareController = UIActivityViewController(activityItems: urls, applicationActivities: nil)
            let shareButton = toolbarController.toolbar.shareButton
            shareController.popoverPresentationController?.sourceView = shareButton

            shareController.completionWithItemsHandler = { [weak self] activity, completed, _, _ in
                guard self?.shouldDeleteFrames(after: activity, completed: completed) == true  else { return }
                try? self?.videoController.deleteExportedFrames()
            }

            presentOnTop(shareController)

        case .saveToPhotos:
            SaveToPhotosAction().save(urls.map { .image($0) }, addingToAlbums: [.appAlbum]) {
                [weak self] ok, _ in
                if ok {
                    self?.activityFeedbackGenerator.notificationOccurred(.success)
                } else {
                    self?.activityFeedbackGenerator.notificationOccurred(.error)
                    self?.presentOnTop(UIAlertController.savingToPhotosFailed())
                }
                
                try? self?.videoController.deleteExportedFrames()
            }
        }
    }

    func shouldDeleteFrames(after shareActivity: UIActivity.ActivityType?, completed: Bool) -> Bool {
        let wasDismissed = (shareActivity == nil) && !completed
        let didFinish = (shareActivity != nil) && completed
        return wasDismissed || didFinish
    }

    // MARK: Showing Progress

    enum Activity {
        case load
        case exportToShareSheet
        case exportToPhotos
        
        init(exportAction: ExportAction) {
            switch exportAction {
            case .saveToPhotos: self = .exportToPhotos
            case .showShareSheet: self = .exportToShareSheet
            }
        }

        var title: String {
            switch self {
            case .load: return UserText.editorVideoLoadProgress
            case .exportToShareSheet: return UserText.editorExportShareSheetProgress
            case .exportToPhotos: return UserText.editorExportToPhotosProgress
            }
        }

        var delay: TimeInterval {
            switch self {
            case .load: return 0.25
            case .exportToShareSheet, .exportToPhotos: return 0.05
            }
        }
    }

    func showProgress(_ show: Bool, forActivity activity: Activity, value: ProgressView.Progress? = nil, animated: Bool = true, completion: (() -> ())? = nil) {
        view.isUserInteractionEnabled = !show 

        progressView.showDelay = activity.delay
        progressView.titleLabel.text = activity.title
        
        if show {
            progressView.show(in: zoomingPlayerView, animated: animated, completion: completion)
        } else {
            progressView.hide(animated: animated, completion: completion)
        }

        if let value = value {
            progressView.setProgress(value, animated: animated)
        }
    }
}

// MARK: ExportSettingsViewControllerDelegate

extension EditorViewController: ExportSettingsViewControllerDelegate {
    
    func controller(_ controller: ExportSettingsViewController, didChangeExportAction action: ExportAction) {
        toolbar.shareButton.setImage(action.icon, for: .normal)
    }
    
    func controller(_ controller: ExportSettingsViewController, didChangeTimeFormat: TimeFormat) {
        let time = playbackController.currentSampleTime ?? playbackController.currentPlaybackTime
        updateTimeLabel(withTime: time)
    }
}

// MARK: - ZoomTransitionDelegate

extension EditorViewController: ZoomTransitionDelegate {

    func zoomTransitionWillBegin(_ transition: ZoomTransition) {
        switch transition.type {
        case .push: animatePush(transition)
        case .pop: animatePop(transition)
        default: break
        }
    }
    
    private func animatePush(_ transition: ZoomTransition) {
        let toolbar = toolbarController.toolbar!
        let yOffset = toolbar.bounds.height * 0.5
        toolbar.transform = CGAffineTransform.identity.translatedBy(x: 0, y: yOffset)

        transition.animate(alongsideTransition: { _ in
            toolbar.transform = .identity
        }, completion:nil)
    }
    
    private func animatePop(_ transition: ZoomTransition) {
        let backgroundColor = view.backgroundColor
        let toolbar = toolbarController.toolbar!

        transition.animate(alongsideTransition: { [weak self] _ in
            guard let self = self else { return }
            self.view.backgroundColor = .clear
            self.progressView.alpha = 0
            
            let yOffset = toolbar.bounds.height * 1.0
            toolbar.transform = CGAffineTransform.identity.translatedBy(x: 0, y: yOffset)
            toolbar.alpha = 0
        }, completion: { [weak self] _ in
            self?.view.backgroundColor = backgroundColor
        })
    }

    func zoomTransitionView(_ transition: ZoomTransition) -> UIView? {
        zoomingPlayerView.playerView
    }
}
