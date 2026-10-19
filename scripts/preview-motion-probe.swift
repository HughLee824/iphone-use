// Offline, ordinary iOS app fixture. No input endpoint or network access.
// Each 20-second wall-clock slot cycles: 60 Hz motion, UIKit transition, AVPlayer.
import UIKit
import AVFoundation

// Repeatable list scrolling for preview A/B runs. Runs only with the explicit
// --preview-scroll-probe launch argument; no recording or network activity.
final class PreviewScrollProbeController: UITableViewController {
    private var link: CADisplayLink?
    private var started: CFTimeInterval?
    private var previousIdleTimerDisabled = false
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .portrait }

    override func viewDidLoad() {
        super.viewDidLoad()
        tableView.rowHeight = 100
        tableView.allowsSelection = false
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "row")
        tableView.accessibilityLabel = "Offline preview scroll benchmark"
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        previousIdleTimerDisabled = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        started = nil
        let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 60, preferred: 60)
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        link?.invalidate(); link = nil
        UIApplication.shared.isIdleTimerDisabled = previousIdleTimerDisabled
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { 80 }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "row", for: indexPath)
        var content = cell.defaultContentConfiguration()
        content.text = String(format: "Preview row %02d · 流畅滚动", indexPath.row)
        content.secondaryText = "Offline UIKit list · 0123456789 · JPEG detail and color"
        content.image = UIImage(systemName: ["photo.fill", "leaf.fill", "sun.max.fill", "book.fill"][indexPath.row % 4])
        content.imageProperties.tintColor = [.systemBlue, .systemGreen, .systemOrange, .systemPurple][indexPath.row % 4]
        cell.contentConfiguration = content
        cell.backgroundColor = indexPath.row.isMultiple(of: 2) ? .secondarySystemBackground : .systemBackground
        return cell
    }

    @objc private func tick(_ link: CADisplayLink) {
        if started == nil { started = link.timestamp }
        guard !tableView.isDragging, !tableView.isDecelerating else { started = link.timestamp; return }
        let phase = (link.timestamp - started!) * 2 * .pi / 8
        let travel = min(2400, max(0, tableView.contentSize.height - tableView.bounds.height))
        let y = travel * (1 - cos(phase)) / 2 - tableView.adjustedContentInset.top
        tableView.setContentOffset(CGPoint(x: 0, y: y), animated: false)
    }
}

final class PreviewMotionProbeController: UIViewController {
    private let titleLabel = UILabel(), facts = UILabel(), motion = MotionView(), card = UILabel()
    private let video = UIView()
    private let controls = UIStackView()
    private var taps = 0
    private var orientationMask: UIInterfaceOrientationMask = .allButUpsideDown
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { orientationMask }
    private var link: CADisplayLink?
    private var player: AVQueuePlayer?, looper: AVPlayerLooper?, playerLayer: AVPlayerLayer?
    private var phase = -1, transition = -1, ticks = 0
    private var lastTick: Double?, largestTickGap = 0.0
    private var failure: String?
    private var fullVideo = false, paused = false
    private let videoControls = UIStackView(), videoTitle = UILabel()
    override var prefersStatusBarHidden: Bool { fullVideo }

    override func viewDidLoad() {
        super.viewDidLoad(); view.backgroundColor = .black
        titleLabel.font = .boldSystemFont(ofSize: 20); titleLabel.textColor = .white
        facts.font = .monospacedSystemFont(ofSize: 13, weight: .medium); facts.textColor = .white; facts.numberOfLines = 0
        card.textAlignment = .center; card.font = .boldSystemFont(ofSize: 40); card.textColor = .white
        controls.axis = .horizontal; controls.distribution = .fillEqually
        for (name, mask) in [("Portrait", UIInterfaceOrientationMask.portrait), ("Left", .landscapeLeft), ("Right", .landscapeRight)] {
            let button = UIButton(type: .system); button.setTitle(name, for: .normal)
            button.addAction(UIAction { [weak self] _ in
                guard let self else { return }; self.orientationMask = mask
                self.setNeedsUpdateOfSupportedInterfaceOrientations()
                self.view.window?.windowScene?.requestGeometryUpdate(.iOS(interfaceOrientations: mask)) { [weak self] in self?.failure = $0.localizedDescription }
            }, for: .touchUpInside); controls.addArrangedSubview(button)
        }
        let tap = UIButton(type: .system); tap.setTitle("Tap 0", for: .normal)
        tap.addAction(UIAction { [weak self, weak tap] _ in
            guard let self else { return }; self.taps += 1; tap?.setTitle("Tap \(self.taps)", for: .normal)
        }, for: .touchUpInside); controls.addArrangedSubview(tap)
        let full = UIButton(type: .system); full.setTitle("Full video", for: .normal)
        full.addAction(UIAction { [weak self] _ in self?.setFullVideo(true) }, for: .touchUpInside)
        controls.addArrangedSubview(full)
        videoControls.axis = .horizontal; videoControls.distribution = .equalSpacing
        for (label, symbol) in [("Back", "chevron.left"), ("Pause", "pause.fill"), ("Portrait", "iphone"), ("Left", "rotate.left"), ("Right", "rotate.right")] {
            let b = UIButton(type: .system); b.tintColor = .white; b.accessibilityLabel = label
            b.setImage(UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 24, weight: .bold)), for: .normal)
            b.addAction(UIAction { [weak self, weak b] _ in
                guard let self else { return }
                if label == "Back" { self.setFullVideo(false) }
                else if label == "Pause" {
                    self.paused.toggle()
                    if self.paused { self.player?.pause() } else { self.player?.play() }
                    b?.setImage(UIImage(systemName: self.paused ? "play.fill" : "pause.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 24, weight: .bold)), for: .normal)
                    b?.accessibilityLabel = self.paused ? "Play" : "Pause"
                } else {
                    self.orientationMask = label == "Portrait" ? .portrait : (label == "Left" ? .landscapeLeft : .landscapeRight)
                    self.setNeedsUpdateOfSupportedInterfaceOrientations()
                    self.view.window?.windowScene?.requestGeometryUpdate(.iOS(interfaceOrientations: self.orientationMask)) { [weak self] in self?.failure = $0.localizedDescription }
                }
            }, for: .touchUpInside)
            b.widthAnchor.constraint(equalToConstant: 44).isActive = true; videoControls.addArrangedSubview(b)
        }
        videoTitle.text = "OFFLINE VIDEO"; videoTitle.textColor = .white
        videoTitle.font = .boldSystemFont(ofSize: 18)
        for child in [titleLabel, controls, motion, card, video, facts, videoControls, videoTitle] { view.addSubview(child) }
        videoControls.isHidden = true; videoTitle.isHidden = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                let url = try Self.makeVideo()
                DispatchQueue.main.async { [weak self] in self?.loadVideo(url) }
            } catch { DispatchQueue.main.async { [weak self] in self?.failure = String(describing: error) } }
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 60, preferred: 60)
        link.add(to: .main, forMode: .common); self.link = link
    }
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated); link?.invalidate(); link = nil; player?.pause()
    }
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let area = view.safeAreaLayoutGuide.layoutFrame.insetBy(dx: 16, dy: 8)
        titleLabel.frame = CGRect(x: area.minX, y: area.minY, width: area.width, height: 36)
        controls.frame = CGRect(x: area.minX, y: area.minY + 36, width: area.width, height: 36)
        let stage = CGRect(x: area.minX, y: area.minY + 80, width: area.width, height: max(50, area.height - 190))
        motion.frame = stage; card.frame = stage; video.frame = stage; playerLayer?.frame = video.bounds
        facts.frame = CGRect(x: area.minX, y: stage.maxY + 8, width: area.width, height: 90)
        if fullVideo { video.frame = view.bounds; playerLayer?.frame = video.bounds; playerLayer?.videoGravity = .resizeAspectFill }
        else { playerLayer?.videoGravity = .resizeAspect }
        videoControls.frame = CGRect(x: area.minX, y: area.minY + 12, width: area.width, height: 44)
        videoTitle.frame = CGRect(x: area.minX + 8, y: area.maxY - 40, width: 200, height: 32)
    }
    private func setFullVideo(_ value: Bool) {
        fullVideo = value; paused = false; phase = -1
        videoControls.isHidden = !value; videoTitle.isHidden = !value
        titleLabel.isHidden = value; controls.isHidden = value; facts.isHidden = value
        setNeedsStatusBarAppearanceUpdate(); view.setNeedsLayout()
    }
    private func loadVideo(_ url: URL) {
        let player = AVQueuePlayer(); self.player = player
        looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(url: url))
        let layer = AVPlayerLayer(player: player); layer.videoGravity = .resizeAspect
        layer.frame = video.bounds; video.layer.addSublayer(layer); playerLayer = layer
        if phase == 2 { player.play() }
    }
    @objc private func tick(_ link: CADisplayLink) {
        if let lastTick { largestTickGap = max(largestTickGap, link.timestamp - lastTick) }
        lastTick = link.timestamp; ticks += 1
        let wall = Date().timeIntervalSince1970
        let next = fullVideo ? 2 : Int(wall / 20) % 3
        if next != phase {
            phase = next; transition = -1
            motion.isHidden = phase != 0; card.isHidden = phase != 1; video.isHidden = phase != 2
            titleLabel.text = ["60 Hz · Motion", "UIKit · Transition", "AVPlayer · 30 fps video"][phase]
            if phase == 2 { player?.play() } else { player?.pause() }
        }
        if phase == 0 { motion.time = wall; motion.setNeedsDisplay() }
        if phase == 1 {
            let nextCard = Int(wall / 1.5)
            if nextCard != transition {
                transition = nextCard
                UIView.transition(with: card, duration: 0.7, options: [.transitionFlipFromLeft, .allowAnimatedContent]) {
                    self.card.backgroundColor = nextCard.isMultiple(of: 2) ? .systemIndigo : .systemTeal
                    self.card.text = "CARD \(nextCard % 100)"
                }
            }
        }
        let videoTime = player?.currentTime().seconds ?? 0
        facts.text = String(format: "Phase %d · Tick %d\nDevice wall %.3f\nVideo %.2fs · max tick gap %.1fms\n%@", phase, ticks, wall, videoTime,
                            largestTickGap * 1000, failure ?? (player == nil ? "Preparing local video…" : "Offline · UIKit \(view.window?.windowScene?.interfaceOrientation.rawValue ?? 0) · 20s/phase"))
    }

    // A real H.264 MP4 played by AVPlayer, not a view pretending to be video.
    private static func makeVideo() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("preview-motion-v1.mp4")
        if FileManager.default.fileExists(atPath: url.path) { return url }
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: 640, AVVideoHeightKey: 360, AVVideoCompressionPropertiesKey: [AVVideoExpectedSourceFrameRateKey: 30]])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
            kCVPixelBufferWidthKey as String: 640, kCVPixelBufferHeightKey as String: 360,
            kCVPixelBufferCGImageCompatibilityKey as String: true, kCVPixelBufferCGBitmapContextCompatibilityKey as String: true])
        guard writer.canAdd(input) else { throw ProbeFailure("Cannot add video input") }
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? ProbeFailure("Cannot start video writer") }
        writer.startSession(atSourceTime: .zero)
        do {
            for frame in 0..<300 {
                let deadline = ProcessInfo.processInfo.systemUptime + 5
                while !input.isReadyForMoreMediaData, writer.status == .writing, ProcessInfo.processInfo.systemUptime < deadline { Thread.sleep(forTimeInterval: 0.002) }
                guard input.isReadyForMoreMediaData else { throw writer.error ?? ProbeFailure("Video writer stalled") }
                try autoreleasepool {
                    var buffer: CVPixelBuffer?
                    guard let pool = adaptor.pixelBufferPool, CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess,
                          let buffer else { throw ProbeFailure("Cannot allocate video frame") }
                    CVPixelBufferLockBaseAddress(buffer, []); defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
                    guard let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: 640, height: 360, bitsPerComponent: 8,
                        bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue) else { throw ProbeFailure("Cannot draw video frame") }
                    context.setFillColor(UIColor(hue: CGFloat(frame) / 300, saturation: 0.7, brightness: 0.6, alpha: 1).cgColor)
                    context.fill(CGRect(x: 0, y: 0, width: 640, height: 360))
                    for row in 0..<8 {
                        context.setFillColor((row.isMultiple(of: 2) ? UIColor.white : UIColor.black).withAlphaComponent(0.25).cgColor)
                        context.fill(CGRect(x: (frame * 5 + row * 40) % 640, y: row * 45, width: 80, height: 30))
                    }
                    context.translateBy(x: 0, y: 360); context.scaleBy(x: 1, y: -1)
                    UIGraphicsPushContext(context)
                    (String(format: "LOCAL VIDEO 30 fps\nFRAME %03d / 300", frame) as NSString).draw(in: CGRect(x: 40, y: 125, width: 560, height: 130), withAttributes: [.font: UIFont.monospacedSystemFont(ofSize: 38, weight: .bold), .foregroundColor: UIColor.white])
                    UIGraphicsPopContext()
                    guard adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(frame), timescale: 30)) else { throw writer.error ?? ProbeFailure("Cannot append video frame") }
                }
            }
            input.markAsFinished(); let done = DispatchSemaphore(value: 0)
            writer.finishWriting { done.signal() }
            guard done.wait(timeout: .now() + 10) == .success, writer.status == .completed else { throw writer.error ?? ProbeFailure("Video finalization failed") }
            return url
        } catch { writer.cancelWriting(); try? FileManager.default.removeItem(at: url); throw error }
    }
}

private struct ProbeFailure: Error { let message: String; init(_ message: String) { self.message = message } }
private final class MotionView: UIView {
    var time = 0.0
    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        UIColor.darkGray.setFill(); context.fill(bounds)
        for row in 0..<10 {
            let y = CGFloat(row) * bounds.height / 10
            UIColor(hue: CGFloat(row) / 10, saturation: 0.8, brightness: 0.9, alpha: 1).setFill()
            let x = (sin(time * 2.5 + Double(row) * 0.4) + 1) * Double(max(0, bounds.width - 50)) / 2
            context.fillEllipse(in: CGRect(x: x, y: y + 2, width: 40, height: 40))
        }
    }
}
