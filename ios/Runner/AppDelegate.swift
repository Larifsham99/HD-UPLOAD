import AVFoundation
import CoreImage
import Flutter
import Photos
import PhotosUI
import UIKit
import UniformTypeIdentifiers
import VideoToolbox

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "HDCleanEngine") {
      HDCleanEngine.shared.attach(messenger: registrar.messenger())
    }
  }
}

// MARK: - Errors

struct EngineError: Error {
  let code: String
  let message: String
}

// MARK: - Channel bridge

final class HDCleanEngine: NSObject, FlutterStreamHandler, PHPickerViewControllerDelegate {
  static let shared = HDCleanEngine()

  private var events: FlutterEventSink?
  private var pendingPick: FlutterResult?
  private var jobs: [String: ExportJob] = [:]
  private let work = DispatchQueue(label: "hdclean.work", qos: .userInitiated, attributes: .concurrent)

  func attach(messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: "hdclean/engine", binaryMessenger: messenger)
    channel.setMethodCallHandler { [weak self] call, result in self?.handle(call, result) }
    FlutterEventChannel(name: "hdclean/progress", binaryMessenger: messenger).setStreamHandler(self)
  }

  func onListen(withArguments arguments: Any?, eventSink: @escaping FlutterEventSink) -> FlutterError? {
    events = eventSink
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    events = nil
    return nil
  }

  func emit(_ jobId: String, _ stage: String, _ percent: Double) {
    DispatchQueue.main.async { self.events?(["jobId": jobId, "stage": stage, "percent": percent]) }
  }

  private func onMain(_ result: @escaping FlutterResult, _ value: Any?) {
    DispatchQueue.main.async { result(value) }
  }

  private func fail(_ result: @escaping FlutterResult, _ e: Error) {
    let err = e as? EngineError ?? EngineError(code: "error", message: e.localizedDescription)
    DispatchQueue.main.async { result(FlutterError(code: err.code, message: err.message, details: nil)) }
  }

  private func background(_ result: @escaping FlutterResult, _ block: @escaping () throws -> Any?) {
    work.async {
      do { self.onMain(result, try block()) } catch { self.fail(result, error) }
    }
  }

  private func handle(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]
    switch call.method {
    case "pickVideo":
      pick(result)
    case "probe":
      background(result) { try VideoProbe.probe(args["uri"] as! String) }
    case "frame":
      background(result) {
        let data = try VideoProbe.frame(
          args["uri"] as! String,
          timeMs: (args["timeMs"] as? NSNumber)?.int64Value ?? 0,
          maxSize: (args["maxSize"] as? NSNumber)?.intValue ?? 512,
          exact: args["exact"] as? Bool ?? false)
        return FlutterStandardTypedData(bytes: data)
      }
    case "export":
      let req = ExportRequest(args)
      let job = ExportJob(req: req, engine: self) { [weak self] outcome in
        DispatchQueue.main.async {
          self?.jobs[req.jobId] = nil
          switch outcome {
          case .success(let map): result(map)
          case .failure(let e):
            let err = e as? EngineError ?? EngineError(code: "error", message: e.localizedDescription)
            result(FlutterError(code: err.code, message: err.message, details: nil))
          }
        }
      }
      jobs[req.jobId] = job
      job.start()
    case "cancel":
      jobs[args["jobId"] as? String ?? ""]?.cancel()
      result(nil)
    case "freeSpace":
      let url = URL(fileURLWithPath: NSHomeDirectory())
      let v = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
      result(NSNumber(value: v?.volumeAvailableCapacityForImportantUsage ?? -1))
    case "saveToGallery":
      saveToPhotos(args["path"] as! String, result)
    case "share":
      share(args["path"] as! String, result)
    case "contentUri":
      result(args["path"] as? String)
    case "copyToFiles":
      // Makes the file visible in Files → On My iPhone → HD CLEAN, so a web
      // upload page can pick the untouched file via "Choose File".
      background(result) {
        let src = URL(fileURLWithPath: args["path"] as! String)
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dest = docs.appendingPathComponent(src.lastPathComponent.components(separatedBy: "_").count > 1 && src.path.contains("/picked/")
          ? src.lastPathComponent.components(separatedBy: "_").dropFirst().joined(separator: "_") : src.lastPathComponent)
        if FileManager.default.fileExists(atPath: dest.path) { try FileManager.default.removeItem(at: dest) }
        try FileManager.default.copyItem(at: src, to: dest)
        return dest.path
      }
    case "openExternal":
      if let u = URL(string: args["url"] as? String ?? "") { UIApplication.shared.open(u) }
      result(nil)
    case "keepAwake":
      UIApplication.shared.isIdleTimerDisabled = args["on"] as? Bool ?? false
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  // MARK: Picker

  private func topController() -> UIViewController? {
    let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
      .first { $0.activationState == .foregroundActive } ?? UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
    var vc = scene?.windows.first { $0.isKeyWindow }?.rootViewController ?? scene?.windows.first?.rootViewController
    while let p = vc?.presentedViewController { vc = p }
    return vc
  }

  private func pick(_ result: @escaping FlutterResult) {
    guard pendingPick == nil else {
      result(FlutterError(code: "busy", message: "The picker is already open.", details: nil))
      return
    }
    var config = PHPickerConfiguration()
    config.filter = .videos
    config.selectionLimit = 1
    // .current delivers the original file. The default (.automatic) may
    // transcode HEVC/HDR to a lower-quality compatible version.
    config.preferredAssetRepresentationMode = .current
    let picker = PHPickerViewController(configuration: config)
    picker.delegate = self
    guard let top = topController() else {
      result(FlutterError(code: "picker_failed", message: "Could not open the video picker.", details: nil))
      return
    }
    pendingPick = result
    top.present(picker, animated: true)
  }

  func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
    picker.dismiss(animated: true)
    guard let r = pendingPick else { return }
    pendingPick = nil
    guard let provider = results.first?.itemProvider else {
      r(nil)
      return
    }
    let type = provider.registeredTypeIdentifiers.first { UTType($0)?.conforms(to: .movie) == true } ?? UTType.movie.identifier
    provider.loadFileRepresentation(forTypeIdentifier: type) { url, error in
      guard let url = url else {
        self.fail(r, EngineError(code: "picker_failed", message: error?.localizedDescription ?? "The video could not be loaded."))
        return
      }
      // The provided file is deleted after this callback: copy it into the
      // app's cache (the Photos original itself is never modified).
      do {
        let fm = FileManager.default
        let dir = fm.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("picked", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        Self.prunePicked(dir)
        let dest = dir.appendingPathComponent("\(UUID().uuidString)_\(url.lastPathComponent)")
        try fm.copyItem(at: url, to: dest)
        self.onMain(r, dest.path)
      } catch {
        let full = (error as NSError).code == NSFileWriteOutOfSpaceError
        self.fail(r, EngineError(code: full ? "no_space" : "picker_failed",
                                 message: full ? "Not enough storage to open this video. Free some space and try again." : error.localizedDescription))
      }
    }
  }

  /// Removes picked copies older than 7 days.
  private static func prunePicked(_ dir: URL) {
    let fm = FileManager.default
    guard let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.creationDateKey]) else { return }
    let cutoff = Date().addingTimeInterval(-7 * 24 * 3600)
    for u in items {
      if let d = try? u.resourceValues(forKeys: [.creationDateKey]).creationDate, d < cutoff { try? fm.removeItem(at: u) }
    }
  }

  // MARK: Save & share

  private func saveToPhotos(_ path: String, _ result: @escaping FlutterResult) {
    let url = URL(fileURLWithPath: path)
    guard FileManager.default.fileExists(atPath: path) else {
      result(FlutterError(code: "missing", message: "The optimized file no longer exists.", details: nil))
      return
    }
    PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
      guard status == .authorized || status == .limited else {
        self.fail(result, EngineError(code: "permission_denied",
                                      message: "Allow HD CLEAN to add videos in Settings → Privacy → Photos to save to your gallery."))
        return
      }
      PHPhotoLibrary.shared().performChanges({
        let req = PHAssetCreationRequest.forAsset()
        req.addResource(with: .video, fileURL: url, options: nil)
      }) { ok, error in
        if ok { self.onMain(result, nil) } else {
          self.fail(result, EngineError(code: "save_failed", message: error?.localizedDescription ?? "Could not save to Photos."))
        }
      }
    }
  }

  private func share(_ path: String, _ result: @escaping FlutterResult) {
    let url = URL(fileURLWithPath: path)
    guard FileManager.default.fileExists(atPath: path), let top = topController() else {
      result(FlutterError(code: "missing", message: "The optimized file no longer exists.", details: nil))
      return
    }
    // iOS has no public API to hand a file straight to TikTok/Instagram/
    // WhatsApp without their SDKs; the system share sheet lists them.
    let vc = UIActivityViewController(activityItems: [url], applicationActivities: nil)
    if let pop = vc.popoverPresentationController {
      pop.sourceView = top.view
      pop.sourceRect = CGRect(x: top.view.bounds.midX, y: top.view.bounds.maxY - 80, width: 1, height: 1)
    }
    top.present(vc, animated: true)
    result(nil)
  }
}

// MARK: - Probe

enum VideoProbe {
  static func url(_ s: String) -> URL { s.hasPrefix("file://") ? URL(string: s)! : URL(fileURLWithPath: s) }

  static func fourCC(_ code: FourCharCode) -> String {
    let bytes = [24, 16, 8, 0].map { UInt8((code >> $0) & 0xff) }
    return String(bytes: bytes, encoding: .ascii)?.trimmingCharacters(in: .whitespaces) ?? "????"
  }

  static func probe(_ uri: String) throws -> [String: Any] {
    let u = url(uri)
    guard FileManager.default.fileExists(atPath: u.path) else {
      throw EngineError(code: "no_access", message: "This video is no longer available. Please select it again.")
    }
    let asset = AVURLAsset(url: u, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
    guard let v = asset.tracks(withMediaType: .video).first else {
      throw EngineError(code: "probe_failed", message: "This file has no video track.")
    }
    var out: [String: Any?] = [:]
    let attrs = try? FileManager.default.attributesOfItem(atPath: u.path)
    out["uri"] = uri
    out["name"] = u.lastPathComponent.components(separatedBy: "_").dropFirst().joined(separator: "_").nilIfEmpty ?? u.lastPathComponent
    out["sizeBytes"] = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
    let durationMs = Int64(CMTimeGetSeconds(asset.duration) * 1000)
    out["durationMs"] = durationMs
    out["width"] = Int(abs(v.naturalSize.width))
    out["height"] = Int(abs(v.naturalSize.height))
    let t = v.preferredTransform
    var deg = Int((atan2(t.b, t.a) * 180 / .pi).rounded())
    deg = ((deg % 360) + 360) % 360
    out["rotation"] = deg
    out["fps"] = Double(v.nominalFrameRate)
    out["videoBitrate"] = Int(v.estimatedDataRate)

    var hdr: String? = nil
    var bitDepth = 8
    if let fd = (v.formatDescriptions as? [CMFormatDescription])?.first {
      let sub = fourCC(CMFormatDescriptionGetMediaSubType(fd))
      out["videoCodec"] = sub
      if sub.hasPrefix("dv") { hdr = "Dolby Vision" }
      let ext = CMFormatDescriptionGetExtensions(fd) as? [String: Any] ?? [:]
      if let tf = ext[kCMFormatDescriptionExtension_TransferFunction as String] as? String {
        if tf == (kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG as String) { hdr = hdr ?? "HLG" }
        if tf == (kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ as String) { hdr = hdr ?? "HDR10" }
      }
      if let bpc = ext[kCMFormatDescriptionExtension_BitsPerComponent as String] as? NSNumber { bitDepth = bpc.intValue }
      if let atoms = ext[kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms as String] as? [String: Any] {
        if let avcC = atoms["avcC"] as? Data, avcC.count > 3 {
          out["videoProfile"] = [66: "Baseline", 77: "Main", 100: "High", 110: "High 10"][Int(avcC[1])] ?? nil
          if avcC[1] == 110 { bitDepth = 10 }
        }
        if let hvcC = atoms["hvcC"] as? Data, hvcC.count > 2 {
          let p = Int(hvcC[1] & 0x1f)
          out["videoProfile"] = [1: "Main", 2: "Main 10"][p] ?? nil
          if p == 2 { bitDepth = max(bitDepth, 10) }
        }
      }
    }
    if hdr == nil, v.hasMediaCharacteristic(.containsHDRVideo) { hdr = "HDR" }
    if hdr != nil { bitDepth = max(bitDepth, 10) }
    out["hdr"] = hdr
    out["bitDepth"] = bitDepth

    if let a = asset.tracks(withMediaType: .audio).first {
      out["hasAudio"] = true
      out["audioBitrate"] = Int(a.estimatedDataRate)
      if let fd = (a.formatDescriptions as? [CMFormatDescription])?.first,
         let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fd)?.pointee {
        out["audioSampleRate"] = Int(asbd.mSampleRate)
        out["audioChannels"] = Int(asbd.mChannelsPerFrame)
        out["audioCodec"] = asbd.mFormatID == kAudioFormatMPEG4AAC || asbd.mFormatID == kAudioFormatMPEG4AAC_HE ? "aac"
          : asbd.mFormatID == kAudioFormatLinearPCM ? "pcm" : fourCC(asbd.mFormatID)
      }
    } else {
      out["hasAudio"] = false
    }
    try analyseTiming(asset, v, durationMs, &out)
    return out.compactMapValues { $0 }
  }

  /// Reads presentation timestamps of ~600 compressed samples to detect
  /// variable frame rate (no decoding).
  static func analyseTiming(_ asset: AVAsset, _ track: AVAssetTrack, _ durationMs: Int64, _ out: inout [String: Any?]) throws {
    var deltas: [Double] = []
    func window(_ start: Double) {
      guard let reader = try? AVAssetReader(asset: asset) else { return }
      let o = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
      o.alwaysCopiesSampleData = false
      guard reader.canAdd(o) else { return }
      reader.add(o)
      reader.timeRange = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600), duration: .positiveInfinity)
      guard reader.startReading() else { return }
      var times: [Double] = []
      while times.count < 300, let sb = o.copyNextSampleBuffer() {
        if CMSampleBufferGetNumSamples(sb) > 0 { times.append(CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sb))) }
      }
      reader.cancelReading()
      times.sort()
      for i in 1..<max(1, times.count) where times[i] - times[i - 1] > 0 { deltas.append(times[i] - times[i - 1]) }
    }
    window(0)
    if durationMs > 20_000 { window(Double(durationMs) / 2000) }
    guard deltas.count >= 10 else { return }
    let sorted = deltas.sorted()
    let median = sorted[sorted.count / 2]
    let p5 = sorted[Int(Double(sorted.count) * 0.05)]
    let p95 = sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))]
    let irregular = deltas.filter { abs($0 - median) > median * 0.25 }.count
    let avg = deltas.reduce(0, +) / Double(deltas.count)
    if (out["fps"] as? Double ?? 0) <= 0 { out["fps"] = 1 / avg }
    out["minFps"] = 1 / p95
    out["maxFps"] = 1 / p5
    out["isVfr"] = Double(irregular) > Double(deltas.count) * 0.05 || (p95 - p5) > median * 0.3
  }

  static func frame(_ uri: String, timeMs: Int64, maxSize: Int, exact: Bool) throws -> Data {
    let asset = AVURLAsset(url: url(uri))
    let gen = AVAssetImageGenerator(asset: asset)
    gen.appliesPreferredTrackTransform = true
    gen.maximumSize = CGSize(width: maxSize, height: maxSize)
    if exact {
      gen.requestedTimeToleranceBefore = .zero
      gen.requestedTimeToleranceAfter = .zero
    }
    let cg = try gen.copyCGImage(at: CMTime(value: timeMs, timescale: 1000), actualTime: nil)
    guard let data = UIImage(cgImage: cg).jpegData(compressionQuality: 0.92) else {
      throw EngineError(code: "frame_failed", message: "Could not read a frame from this video.")
    }
    return data
  }
}

extension String {
  var nilIfEmpty: String? { isEmpty ? nil : self }
}

// MARK: - Export

struct ExportRequest {
  let jobId: String, input: String, output: String
  let width: Int, height: Int, frameMode: String
  let fps: Double, convertToCfr: Bool
  let videoCodec: String, videoBitrate: Int, keyframeIntervalSec: Double
  let toneMapHdr: Bool
  let audioMode: String, audioBitrate: Int, audioSampleRate: Int
  let remuxOnly: Bool
  let startMs: Int64?, endMs: Int64?
  let sourceChannels: Int?
  let denoise: Double, shadowLift: Double

  init(_ a: [String: Any]) {
    jobId = a["jobId"] as! String
    input = a["input"] as! String
    output = a["output"] as! String
    width = (a["width"] as! NSNumber).intValue
    height = (a["height"] as! NSNumber).intValue
    frameMode = a["frameMode"] as? String ?? "keep"
    fps = (a["fps"] as! NSNumber).doubleValue
    convertToCfr = a["convertToCfr"] as? Bool ?? false
    videoCodec = a["videoCodec"] as? String ?? "h264"
    videoBitrate = (a["videoBitrate"] as! NSNumber).intValue
    keyframeIntervalSec = (a["keyframeIntervalSec"] as? NSNumber)?.doubleValue ?? 1
    toneMapHdr = a["toneMapHdr"] as? Bool ?? false
    audioMode = a["audioMode"] as? String ?? "transcode"
    audioBitrate = (a["audioBitrate"] as? NSNumber)?.intValue ?? 256_000
    audioSampleRate = (a["audioSampleRate"] as? NSNumber)?.intValue ?? 48_000
    remuxOnly = a["remuxOnly"] as? Bool ?? false
    startMs = (a["startMs"] as? NSNumber)?.int64Value
    endMs = (a["endMs"] as? NSNumber)?.int64Value
    sourceChannels = (a["sourceChannels"] as? NSNumber)?.intValue
    denoise = (a["denoise"] as? NSNumber)?.doubleValue ?? 0
    shadowLift = (a["shadowLift"] as? NSNumber)?.doubleValue ?? 0
  }
}

final class ExportJob {
  let req: ExportRequest
  weak var engine: HDCleanEngine?
  let completion: (Result<[String: Any], Error>) -> Void

  private let queue = DispatchQueue(label: "hdclean.export")
  private var reader: AVAssetReader?
  private var writer: AVAssetWriter?
  private var session: AVAssetExportSession?
  private var cancelled = false
  private var finished = false
  private var bgTask: UIBackgroundTaskIdentifier = .invalid
  private var lastEmit = Date.distantPast

  init(req: ExportRequest, engine: HDCleanEngine, completion: @escaping (Result<[String: Any], Error>) -> Void) {
    self.req = req
    self.engine = engine
    self.completion = completion
  }

  private var outURL: URL { URL(fileURLWithPath: req.output) }

  func start() {
    bgTask = UIApplication.shared.beginBackgroundTask(withName: "HDCLEAN export") { [weak self] in
      // System is about to suspend us: stop cleanly instead of being killed mid-write.
      self?.fail(EngineError(code: "interrupted", message: "Processing stopped because HD CLEAN was in the background too long. Keep the app open while optimizing."))
    }
    engine?.emit(req.jobId, "preparing", -1)
    queue.async {
      do {
        try? FileManager.default.removeItem(at: self.outURL)
        try FileManager.default.createDirectory(at: self.outURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if self.req.remuxOnly { try self.remux() } else { try self.transcode() }
      } catch {
        self.fail(error)
      }
    }
  }

  func cancel() {
    queue.async {
      guard !self.finished else { return }
      self.cancelled = true
      self.session?.cancelExport()
      self.reader?.cancelReading()
      self.writer?.cancelWriting()
      self.fail(EngineError(code: "cancelled", message: "Cancelled"))
    }
  }

  private func fail(_ e: Error) {
    guard !finished else { return }
    finished = true
    reader?.cancelReading()
    if writer?.status == .writing { writer?.cancelWriting() }
    try? FileManager.default.removeItem(at: outURL)
    endBackground()
    completion(.failure(e))
  }

  private func succeed(transmuxed: Bool) {
    guard !finished else { return }
    finished = true
    let attrs = try? FileManager.default.attributesOfItem(atPath: req.output)
    let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
    endBackground()
    completion(.success(["path": req.output, "sizeBytes": NSNumber(value: size), "transmuxed": transmuxed]))
  }

  private func endBackground() {
    if bgTask != .invalid {
      let t = bgTask
      bgTask = .invalid
      DispatchQueue.main.async { UIApplication.shared.endBackgroundTask(t) }
    }
  }

  private func timeRange(_ asset: AVAsset) -> CMTimeRange {
    let start = CMTime(value: req.startMs ?? 0, timescale: 1000)
    let end = req.endMs.map { CMTime(value: $0, timescale: 1000) } ?? asset.duration
    return CMTimeRange(start: start, end: CMTimeMinimum(end, asset.duration))
  }

  private func progress(_ fraction: Double, stage: String = "encoding") {
    let now = Date()
    guard now.timeIntervalSince(lastEmit) > 0.25 else { return }
    lastEmit = now
    engine?.emit(req.jobId, stage, max(0, min(100, fraction * 100)))
  }

  // Already-optimal source: re-wrap into fast-start MP4, no re-encode.
  private func remux() throws {
    let asset = AVURLAsset(url: VideoProbe.url(req.input))
    guard let s = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
      throw EngineError(code: "setup_failed", message: "Could not prepare the video.")
    }
    s.outputURL = outURL
    s.outputFileType = .mp4
    s.shouldOptimizeForNetworkUse = true
    s.timeRange = timeRange(asset)
    session = s
    let timer = DispatchSource.makeTimerSource(queue: queue)
    timer.schedule(deadline: .now(), repeating: 0.25)
    timer.setEventHandler { [weak self, weak s] in if let s = s { self?.progress(Double(s.progress)) } }
    timer.resume()
    s.exportAsynchronously { [weak self] in
      timer.cancel()
      guard let self = self else { return }
      self.queue.async {
        switch s.status {
        case .completed: self.succeed(transmuxed: true)
        case .cancelled: self.fail(EngineError(code: "cancelled", message: "Cancelled"))
        default: self.fail(EngineError(code: "export_failed", message: s.error?.localizedDescription ?? "Export failed."))
        }
      }
    }
  }

  private func frameDuration() -> CMTime {
    let f = req.fps
    for (std, d) in [(23.976, CMTime(value: 1001, timescale: 24000)), (29.97, CMTime(value: 1001, timescale: 30000)), (59.94, CMTime(value: 1001, timescale: 60000))]
      where abs(f - std) < 0.01 { return d }
    if abs(f - f.rounded()) < 0.001 { return CMTime(value: 1, timescale: CMTimeScale(f.rounded())) }
    return CMTime(value: 1000, timescale: CMTimeScale((f * 1000).rounded()))
  }

  private func transcode() throws {
    let asset = AVURLAsset(url: VideoProbe.url(req.input), options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
    guard let vTrack = asset.tracks(withMediaType: .video).first else {
      throw EngineError(code: "probe_failed", message: "This file has no video track.")
    }
    let aTrack = req.audioMode == "none" ? nil : asset.tracks(withMediaType: .audio).first
    let range = timeRange(asset)
    let reader = try AVAssetReader(asset: asset)
    reader.timeRange = range
    let writer = try AVAssetWriter(outputURL: outURL, fileType: .mp4)
    writer.shouldOptimizeForNetworkUse = true // fast start (moov before mdat)
    self.reader = reader
    self.writer = writer

    // --- Video: one composition does rotation, scaling, framing, constant
    // frame rate and (via BT.709 output) HDR → SDR tone mapping.
    let W = CGFloat(req.width), H = CGFloat(req.height)
    let comp = AVMutableVideoComposition()
    comp.renderSize = CGSize(width: W, height: H)
    comp.frameDuration = frameDuration()
    comp.colorPrimaries = AVVideoColorPrimaries_ITU_R_709_2
    comp.colorTransferFunction = AVVideoTransferFunction_ITU_R_709_2
    comp.colorYCbCrMatrix = AVVideoYCbCrMatrix_ITU_R_709_2
    let display = CGRect(origin: .zero, size: vTrack.naturalSize).applying(vTrack.preferredTransform)
    let dw = abs(display.width), dh = abs(display.height)
    let s = req.frameMode == "fill" ? max(W / dw, H / dh) : min(W / dw, H / dh)
    let transform = vTrack.preferredTransform
      .concatenating(CGAffineTransform(translationX: -display.minX, y: -display.minY))
      .concatenating(CGAffineTransform(scaleX: s, y: s))
      .concatenating(CGAffineTransform(translationX: (W - dw * s) / 2, y: (H - dh * s) / 2))
    let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: vTrack)
    layer.setTransform(transform, at: .zero)
    let instruction = AVMutableVideoCompositionInstruction()
    instruction.timeRange = CMTimeRange(start: .zero, duration: asset.duration)
    instruction.backgroundColor = UIColor.black.cgColor
    instruction.layerInstructions = [layer]
    comp.instructions = [instruction]

    let vOut = AVAssetReaderVideoCompositionOutput(videoTracks: [vTrack], videoSettings: [
      kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
      kCVPixelBufferIOSurfacePropertiesKey as String: [:],
    ])
    vOut.videoComposition = comp
    vOut.alwaysCopiesSampleData = false
    guard reader.canAdd(vOut) else { throw EngineError(code: "setup_failed", message: "This video cannot be decoded on this device.") }
    reader.add(vOut)

    let hevc = req.videoCodec == "hevc"
    var compression: [String: Any] = [
      AVVideoAverageBitRateKey: req.videoBitrate,
      AVVideoExpectedSourceFrameRateKey: Int(req.fps.rounded()),
      AVVideoMaxKeyFrameIntervalKey: max(1, Int((req.fps * req.keyframeIntervalSec).rounded())),
      AVVideoMaxKeyFrameIntervalDurationKey: req.keyframeIntervalSec,
      AVVideoAllowFrameReorderingKey: true,
      AVVideoProfileLevelKey: hevc ? (kVTProfileLevel_HEVC_Main_AutoLevel as String) : AVVideoProfileLevelH264HighAutoLevel,
    ]
    if !hevc { compression[AVVideoH264EntropyModeKey] = AVVideoH264EntropyModeCABAC }
    let vIn = AVAssetWriterInput(mediaType: .video, outputSettings: [
      AVVideoCodecKey: hevc ? AVVideoCodecType.hevc : AVVideoCodecType.h264,
      AVVideoWidthKey: req.width,
      AVVideoHeightKey: req.height,
      AVVideoColorPropertiesKey: [
        AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
        AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
        AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
      ],
      AVVideoCompressionPropertiesKey: compression,
    ])
    vIn.expectsMediaDataInRealTime = false
    guard writer.canAdd(vIn) else { throw EngineError(code: "setup_failed", message: "This device's encoder does not support \(req.width)×\(req.height).") }
    writer.add(vIn)

    // TikTok Survival Mode: GPU pre-conditioning through Core Image.
    let survival = req.denoise > 0 || req.shadowLift > 0
    let adaptor: AVAssetWriterInputPixelBufferAdaptor? = survival
      ? AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: vIn, sourcePixelBufferAttributes: [
          kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
          kCVPixelBufferWidthKey as String: req.width,
          kCVPixelBufferHeightKey as String: req.height,
          kCVPixelBufferIOSurfacePropertiesKey as String: [:],
        ])
      : nil
    let ciContext = survival ? CIContext(options: [.cacheIntermediates: false]) : nil
    let rec709 = CGColorSpace(name: CGColorSpace.itur_709)!
    let denoise = req.denoise, lift = req.shadowLift
    func condition(_ sb: CMSampleBuffer) -> Bool {
      guard let a = adaptor, let ctx = ciContext, let src = CMSampleBufferGetImageBuffer(sb),
            let pool = a.pixelBufferPool else { return false }
      var out: CVPixelBuffer?
      guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &out) == kCVReturnSuccess, let dst = out else { return false }
      var img = CIImage(cvPixelBuffer: src)
      if denoise > 0, let f = CIFilter(name: "CINoiseReduction") {
        f.setValue(img, forKey: kCIInputImageKey)
        f.setValue(0.01 + 0.04 * denoise, forKey: "inputNoiseLevel")
        f.setValue(0.0, forKey: "inputSharpness") // never sharpen
        img = f.outputImage ?? img
      }
      if lift > 0, let f = CIFilter(name: "CIHighlightShadowAdjust") {
        f.setValue(img, forKey: kCIInputImageKey)
        f.setValue(lift * 0.6, forKey: "inputShadowAmount")
        f.setValue(1.0, forKey: "inputHighlightAmount")
        img = f.outputImage ?? img
      }
      CVBufferPropagateAttachments(src, dst)
      ctx.render(img.cropped(to: CGRect(x: 0, y: 0, width: req.width, height: req.height)), to: dst,
                 bounds: CGRect(x: 0, y: 0, width: req.width, height: req.height), colorSpace: rec709)
      return a.append(dst, withPresentationTime: CMSampleBufferGetPresentationTimeStamp(sb))
    }

    // --- Audio
    var aOut: AVAssetReaderTrackOutput?
    var aIn: AVAssetWriterInput?
    if let a = aTrack {
      if req.audioMode == "copy" {
        let o = AVAssetReaderTrackOutput(track: a, outputSettings: nil)
        let hint = (a.formatDescriptions as? [CMFormatDescription])?.first
        let i = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: hint)
        aOut = o
        aIn = i
      } else {
        let ch = min(max(req.sourceChannels ?? 2, 1), 2)
        var layout = AudioChannelLayout()
        layout.mChannelLayoutTag = ch == 1 ? kAudioChannelLayoutTag_Mono : kAudioChannelLayoutTag_Stereo
        let layoutData = Data(bytes: &layout, count: MemoryLayout<AudioChannelLayout>.size)
        aOut = AVAssetReaderTrackOutput(track: a, outputSettings: [
          AVFormatIDKey: kAudioFormatLinearPCM,
          AVSampleRateKey: req.audioSampleRate,
          AVNumberOfChannelsKey: ch,
          AVChannelLayoutKey: layoutData,
          AVLinearPCMBitDepthKey: 32,
          AVLinearPCMIsFloatKey: true,
          AVLinearPCMIsNonInterleaved: false,
          AVLinearPCMIsBigEndianKey: false,
        ])
        aIn = AVAssetWriterInput(mediaType: .audio, outputSettings: [
          AVFormatIDKey: kAudioFormatMPEG4AAC,
          AVSampleRateKey: req.audioSampleRate,
          AVNumberOfChannelsKey: ch,
          AVChannelLayoutKey: layoutData,
          AVEncoderBitRateKey: min(req.audioBitrate, ch == 1 ? 160_000 : 320_000),
        ])
      }
      aOut!.alwaysCopiesSampleData = false
      aIn!.expectsMediaDataInRealTime = false
      if reader.canAdd(aOut!) && writer.canAdd(aIn!) {
        reader.add(aOut!)
        writer.add(aIn!)
      } else {
        aOut = nil
        aIn = nil
      }
    }

    guard reader.startReading() else {
      throw EngineError(code: "decode_failed", message: reader.error?.localizedDescription ?? "Could not read the video.")
    }
    guard writer.startWriting() else {
      throw EngineError(code: "encode_failed", message: writer.error?.localizedDescription ?? "Could not start the encoder.")
    }
    writer.startSession(atSourceTime: range.start)

    let group = DispatchGroup()
    let total = max(0.001, CMTimeGetSeconds(range.duration))
    let startSec = CMTimeGetSeconds(range.start)

    group.enter()
    let vQueue = DispatchQueue(label: "hdclean.video")
    var vDone = false
    vIn.requestMediaDataWhenReady(on: vQueue) { [weak self] in
      guard let self = self else { return }
      while vIn.isReadyForMoreMediaData && !vDone {
        if self.cancelled || reader.status != .reading {
          vDone = true; vIn.markAsFinished(); group.leave(); return
        }
        let ok: Bool = autoreleasepool {
          guard let sb = vOut.copyNextSampleBuffer() else { return false }
          let t = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sb))
          self.progress((t - startSec) / total)
          return survival ? condition(sb) : vIn.append(sb)
        }
        if !ok {
          vDone = true; vIn.markAsFinished(); group.leave(); return
        }
      }
    }

    if let aOut = aOut, let aIn = aIn {
      group.enter()
      let aQueue = DispatchQueue(label: "hdclean.audio")
      var aDone = false
      aIn.requestMediaDataWhenReady(on: aQueue) { [weak self] in
        guard let self = self else { return }
        while aIn.isReadyForMoreMediaData && !aDone {
          if self.cancelled || reader.status != .reading {
            aDone = true; aIn.markAsFinished(); group.leave(); return
          }
          let ok: Bool = autoreleasepool {
            guard let sb = aOut.copyNextSampleBuffer() else { return false }
            return aIn.append(sb)
          }
          if !ok {
            aDone = true; aIn.markAsFinished(); group.leave(); return
          }
        }
      }
    }

    group.notify(queue: queue) { [weak self] in
      guard let self = self, !self.finished else { return }
      if self.cancelled { return }
      if reader.status == .failed {
        let bg = UIApplication.shared.applicationState == .background
        self.fail(EngineError(code: "decode_failed", message: bg
          ? "Processing stopped because HD CLEAN went to the background. Keep the app open while optimizing."
          : "Reading the video failed: \(reader.error?.localizedDescription ?? "unknown error")"))
        return
      }
      if writer.status == .failed {
        let full = (writer.error as NSError?)?.code == AVError.diskFull.rawValue
        self.fail(EngineError(code: full ? "no_space" : "encode_failed", message: full
          ? "Storage is full. Free some space and try again."
          : "Encoding failed: \(writer.error?.localizedDescription ?? "unknown error")"))
        return
      }
      self.engine?.emit(self.req.jobId, "finalizing", 100)
      writer.finishWriting {
        self.queue.async {
          if writer.status == .completed { self.succeed(transmuxed: false) } else {
            self.fail(EngineError(code: "encode_failed", message: writer.error?.localizedDescription ?? "Finalizing the MP4 failed."))
          }
        }
      }
    }
  }
}
