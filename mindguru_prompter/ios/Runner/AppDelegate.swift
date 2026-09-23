import AVFoundation
import AVKit
import CoreMedia
import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private var pip: TeleprompterPip?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)

    let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "MindGuruNative")!
    let messenger = registrar.messenger()

    let device = FlutterMethodChannel(name: "com.mindguru.prompter/device", binaryMessenger: messenger)
    device.setMethodCallHandler { call, result in
      switch call.method {
      case "getDeviceInfo": result(DeviceCapabilities.deviceInfo())
      case "getCameraCapabilities": result(DeviceCapabilities.cameras())
      default: result(FlutterMethodNotImplemented)
      }
    }

    let pipChannel = FlutterMethodChannel(name: "com.mindguru.prompter/pip", binaryMessenger: messenger)
    pipChannel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else { return }
      switch call.method {
      case "isSupported":
        result(AVPictureInPictureController.isPictureInPictureSupported())
      case "isActive":
        result(self.pip?.isActive ?? false)
      case "start":
        guard let args = call.arguments as? [String: Any] else {
          result(FlutterError(code: "BAD_ARGS", message: "Missing script", details: nil))
          return
        }
        if self.pip == nil { self.pip = TeleprompterPip() }
        self.pip?.start(args, result: result)
      case "control":
        self.pip?.control(call.arguments as? [String: Any] ?? [:])
        result(nil)
      case "stop":
        self.pip?.stop()
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }
}

// MARK: - Device capabilities (AVFoundation)

enum DeviceCapabilities {
  static func deviceInfo() -> [String: Any] {
    var systemInfo = utsname()
    uname(&systemInfo)
    let identifier = withUnsafePointer(to: &systemInfo.machine) {
      $0.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) }
    }
    return [
      "manufacturer": "Apple",
      "model": identifier,
      "marketName": UIDevice.current.model,
      "systemVersion": UIDevice.current.systemVersion,
    ]
  }

  private static let targets: [(Int32, Int32)] = [
    (1280, 720), (1920, 1080), (2560, 1440), (3840, 2160), (7680, 4320),
  ]

  static func cameras() -> [[String: Any]] {
    let session = AVCaptureDevice.DiscoverySession(
      deviceTypes: [.builtInWideAngleCamera, .builtInTrueDepthCamera],
      mediaType: .video,
      position: .unspecified
    )
    return session.devices.map { device in
      var sizes: [String: Int] = [:]
      var hdr10Bit = false
      var stabilization = false
      for format in device.formats {
        let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
        let maxFps = Int(format.videoSupportedFrameRateRanges.map { $0.maxFrameRate }.max() ?? 30)
        if targets.contains(where: { $0.0 == dims.width && $0.1 == dims.height }) {
          let key = "\(dims.width)x\(dims.height)"
          sizes[key] = max(sizes[key] ?? 0, maxFps)
        }
        if format.supportedColorSpaces.contains(.HLG_BT2020) { hdr10Bit = true }
        if format.isVideoStabilizationModeSupported(.cinematic) { stabilization = true }
      }
      let videoSizes: [[String: Int]] = sizes.map { key, fps in
        let parts = key.split(separator: "x").compactMap { Int($0) }
        return ["width": parts[0], "height": parts[1], "maxFps": fps]
      }
      return [
        "id": device.uniqueID,
        "facing": device.position == .front ? "front" : "back",
        "videoSizes": videoSizes,
        // iOS reaches 120/240fps with a normal active format.
        "highSpeedSizes": videoSizes.filter { ($0["maxFps"] ?? 0) >= 120 },
        "videoStabilization": stabilization,
        "opticalStabilization": device.position == .back,
        "hdr10Bit": hdr10Bit,
      ]
    }
  }
}

// MARK: - Picture-in-Picture prompter

/// iOS can't draw over other apps, so the script is rendered into video
/// frames and shown in a Picture-in-Picture window that floats above
/// Instagram, TikTok, etc.
final class TeleprompterPip: NSObject, AVPictureInPictureControllerDelegate,
  AVPictureInPictureSampleBufferPlaybackDelegate
{
  private let renderSize = CGSize(width: 800, height: 400)
  private let displayLayer = AVSampleBufferDisplayLayer()
  private var hostView: UIView?
  private var controller: AVPictureInPictureController?
  private var possibleObservation: NSKeyValueObservation?
  private var displayLink: CADisplayLink?
  private var pendingResult: FlutterResult?

  private let textStorage = NSTextStorage()
  private let layoutManager = NSLayoutManager()
  private let textContainer = NSTextContainer()

  private var wordCount = 1
  private var wpm: Double = 140
  private var mirror = false
  private var playing = true
  private var offset: CGFloat = 0
  private var contentHeight: CGFloat = 1
  private var lastTick: CFTimeInterval = 0
  private var pixelBufferPool: CVPixelBufferPool?

  var isActive: Bool { controller?.isPictureInPictureActive ?? false }

  override init() {
    super.init()
    textContainer.lineFragmentPadding = 0
    layoutManager.addTextContainer(textContainer)
    textStorage.addLayoutManager(layoutManager)
  }

  func start(_ args: [String: Any], result: @escaping FlutterResult) {
    guard AVPictureInPictureController.isPictureInPictureSupported() else {
      result(false)
      return
    }
    load(args)

    // PiP requires an active playback audio session.
    try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback, options: [.mixWithOthers])
    try? AVAudioSession.sharedInstance().setActive(true)

    if controller == nil {
      guard let window = UIApplication.shared.connectedScenes
        .compactMap({ ($0 as? UIWindowScene)?.keyWindow }).first
      else {
        result(false)
        return
      }
      // The layer must live in the view hierarchy; keep it tiny and invisible.
      let host = UIView(frame: CGRect(x: 0, y: 0, width: 2, height: 1))
      host.alpha = 0.01
      host.isUserInteractionEnabled = false
      displayLayer.frame = host.bounds
      displayLayer.videoGravity = .resizeAspect
      host.layer.addSublayer(displayLayer)
      window.addSubview(host)
      hostView = host

      let source = AVPictureInPictureController.ContentSource(
        sampleBufferDisplayLayer: displayLayer,
        playbackDelegate: self
      )
      let pipController = AVPictureInPictureController(contentSource: source)
      pipController.delegate = self
      pipController.canStartPictureInPictureAutomaticallyFromInline = true
      controller = pipController
    }

    startRendering()
    pendingResult = result

    if controller?.isPictureInPicturePossible == true {
      controller?.startPictureInPicture()
    } else {
      possibleObservation = controller?.observe(\.isPictureInPicturePossible, options: [.new]) {
        [weak self] pip, change in
        if change.newValue == true {
          pip.startPictureInPicture()
          self?.possibleObservation = nil
        }
      }
    }
  }

  func control(_ message: [String: Any]) {
    let value = message["value"]
    switch message["action"] as? String {
    case "play": playing = true
    case "pause": playing = false
    case "speed": if let v = value as? NSNumber { wpm = v.doubleValue }
    case "mirror": mirror = (value as? Bool) ?? false
    case "seek": if let v = value as? NSNumber { offset = CGFloat(v.doubleValue) * contentHeight }
    default: break
    }
    controller?.invalidatePlaybackState()
  }

  func stop() {
    controller?.stopPictureInPicture()
    teardown()
  }

  private func load(_ args: [String: Any]) {
    let content = args["content"] as? String ?? ""
    let fontSize = CGFloat((args["fontSize"] as? NSNumber)?.doubleValue ?? 34) * 1.1
    wpm = (args["wpm"] as? NSNumber)?.doubleValue ?? 140
    mirror = args["mirror"] as? Bool ?? false
    wordCount = max(1, content.split(whereSeparator: { $0.isWhitespace }).count)

    let paragraph = NSMutableParagraphStyle()
    paragraph.lineSpacing = fontSize * 0.3
    textStorage.setAttributedString(NSAttributedString(
      string: content,
      attributes: [
        .font: UIFont.systemFont(ofSize: fontSize, weight: .semibold),
        .foregroundColor: UIColor.white,
        .paragraphStyle: paragraph,
      ]
    ))
    textContainer.size = CGSize(width: renderSize.width - 48, height: .greatestFiniteMagnitude)
    layoutManager.ensureLayout(for: textContainer)
    contentHeight = max(1, layoutManager.usedRect(for: textContainer).height)
    offset = CGFloat((args["progress"] as? NSNumber)?.doubleValue ?? 0) * contentHeight
    playing = true
  }

  private func startRendering() {
    displayLink?.invalidate()
    lastTick = CACurrentMediaTime()
    let link = CADisplayLink(target: self, selector: #selector(tick))
    link.preferredFramesPerSecond = 30
    link.add(to: .main, forMode: .common)
    displayLink = link
    renderFrame()
  }

  @objc private func tick() {
    let now = CACurrentMediaTime()
    let dt = now - lastTick
    lastTick = now
    if playing {
      // Words per second → points per second through the laid-out text.
      let pointsPerWord = contentHeight / CGFloat(wordCount)
      offset = min(contentHeight, offset + CGFloat(wpm / 60.0 * dt) * pointsPerWord)
      if offset >= contentHeight {
        playing = false
        controller?.invalidatePlaybackState()
      }
    }
    renderFrame()
  }

  private func renderFrame() {
    guard let buffer = makePixelBuffer() else { return }
    CVPixelBufferLockBaseAddress(buffer, [])
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

    guard let context = CGContext(
      data: CVPixelBufferGetBaseAddress(buffer),
      width: Int(renderSize.width),
      height: Int(renderSize.height),
      bitsPerComponent: 8,
      bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
    ) else { return }

    // UIKit coordinates (origin top-left).
    context.translateBy(x: 0, y: renderSize.height)
    context.scaleBy(x: 1, y: -1)
    if mirror {
      context.translateBy(x: renderSize.width, y: 0)
      context.scaleBy(x: -1, y: 1)
    }

    context.setFillColor(UIColor.black.cgColor)
    context.fill(CGRect(origin: .zero, size: renderSize))

    let readingLine = renderSize.height * 0.3
    UIGraphicsPushContext(context)
    let origin = CGPoint(x: 24, y: readingLine - offset)
    let visible = CGRect(x: 0, y: offset - readingLine, width: textContainer.size.width, height: renderSize.height)
    let glyphs = layoutManager.glyphRange(forBoundingRect: visible, in: textContainer)
    layoutManager.drawGlyphs(forGlyphRange: glyphs, at: origin)
    UIGraphicsPopContext()

    // Lime reading marker.
    context.setFillColor(UIColor(red: 0.655, green: 0.941, blue: 0.314, alpha: 1).cgColor)
    context.fill(CGRect(x: 6, y: readingLine, width: 6, height: 36))

    enqueue(buffer)
  }

  private func makePixelBuffer() -> CVPixelBuffer? {
    if pixelBufferPool == nil {
      let attributes: [String: Any] = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey as String: Int(renderSize.width),
        kCVPixelBufferHeightKey as String: Int(renderSize.height),
        kCVPixelBufferIOSurfacePropertiesKey as String: [:],
      ]
      CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &pixelBufferPool)
    }
    guard let pool = pixelBufferPool else { return nil }
    var buffer: CVPixelBuffer?
    CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
    return buffer
  }

  private func enqueue(_ buffer: CVPixelBuffer) {
    var format: CMVideoFormatDescription?
    CMVideoFormatDescriptionCreateForImageBuffer(
      allocator: nil, imageBuffer: buffer, formatDescriptionOut: &format)
    guard let formatDescription = format else { return }

    var timing = CMSampleTimingInfo(
      duration: CMTime(value: 1, timescale: 30),
      presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
      decodeTimeStamp: .invalid
    )
    var sample: CMSampleBuffer?
    CMSampleBufferCreateReadyWithImageBuffer(
      allocator: nil,
      imageBuffer: buffer,
      formatDescription: formatDescription,
      sampleTiming: &timing,
      sampleBufferOut: &sample
    )
    guard let sampleBuffer = sample else { return }
    if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: true),
      CFArrayGetCount(attachments) > 0
    {
      let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
      CFDictionarySetValue(
        dict,
        Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
        Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
      )
    }
    if displayLayer.status == .failed { displayLayer.flush() }
    displayLayer.enqueue(sampleBuffer)
  }

  private func teardown() {
    displayLink?.invalidate()
    displayLink = nil
    possibleObservation = nil
    displayLayer.flushAndRemoveImage()
  }

  // MARK: AVPictureInPictureSampleBufferPlaybackDelegate

  func pictureInPictureController(
    _ pictureInPictureController: AVPictureInPictureController, setPlaying playing: Bool
  ) {
    self.playing = playing
    pictureInPictureController.invalidatePlaybackState()
  }

  func pictureInPictureControllerTimeRangeForPlayback(
    _ pictureInPictureController: AVPictureInPictureController
  ) -> CMTimeRange {
    // Live content: no scrubber.
    CMTimeRange(start: .negativeInfinity, duration: .positiveInfinity)
  }

  func pictureInPictureControllerIsPlaybackPaused(
    _ pictureInPictureController: AVPictureInPictureController
  ) -> Bool {
    !playing
  }

  func pictureInPictureController(
    _ pictureInPictureController: AVPictureInPictureController,
    didTransitionToRenderSize newRenderSize: CMVideoDimensions
  ) {}

  func pictureInPictureController(
    _ pictureInPictureController: AVPictureInPictureController,
    skipByInterval skipInterval: CMTime,
    completion completionHandler: @escaping () -> Void
  ) {
    // Skip buttons jump by the words spoken in that interval.
    let seconds = CGFloat(CMTimeGetSeconds(skipInterval))
    let pointsPerWord = contentHeight / CGFloat(wordCount)
    offset = min(max(0, offset + seconds * CGFloat(wpm / 60.0) * pointsPerWord), contentHeight)
    renderFrame()
    completionHandler()
  }

  // MARK: AVPictureInPictureControllerDelegate

  func pictureInPictureControllerDidStartPictureInPicture(
    _ pictureInPictureController: AVPictureInPictureController
  ) {
    pendingResult?(true)
    pendingResult = nil
  }

  func pictureInPictureController(
    _ pictureInPictureController: AVPictureInPictureController,
    failedToStartPictureInPictureWithError error: Error
  ) {
    pendingResult?(FlutterError(code: "PIP_FAILED", message: error.localizedDescription, details: nil))
    pendingResult = nil
    teardown()
  }

  func pictureInPictureControllerDidStopPictureInPicture(
    _ pictureInPictureController: AVPictureInPictureController
  ) {
    teardown()
  }
}
