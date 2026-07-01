import AppKit
import ApplicationServices
import CoreAudio
import CoreGraphics
import Darwin
import Foundation
import IOKit
import SwiftUI

private enum DemoMetrics {
  static let fallbackScreenFrame = CGRect(x: 0, y: 0, width: 1512, height: 982)
  static let windowSize = CGSize(width: 540, height: 104)
  static let collapsedSize = CGSize(width: 214, height: 36)
  static let expandedSize = CGSize(width: 520, height: 86)
  static let hoverTriggerSize = CGSize(width: 168, height: 18)
  static let hoverRetentionSize = CGSize(width: 210, height: 28)
  static let expandedContentTopInset: CGFloat = 42
  static let expansionAnimation = Animation.spring(response: 0.44, dampingFraction: 0.92)
}

private enum AppIconAsset {
  static let image: NSImage? = {
    guard let url = Bundle.main.url(forResource: "NotchyIcon", withExtension: "png") else {
      return nil
    }

    return NSImage(contentsOf: url)
  }()

  @MainActor
  static func dockIcon() -> NSImage? {
    image
  }
}

private struct AudioOutputRoute: Equatable, Sendable {
  enum Kind: Equatable, Sendable {
    case systemSpeaker
    case bluetoothHeadphones
    case wiredHeadphones
    case external
    case unknown

    var label: String {
      switch self {
      case .systemSpeaker:
        return "System Speakers"
      case .bluetoothHeadphones:
        return "Bluetooth Headphones"
      case .wiredHeadphones:
        return "Wired Headphones"
      case .external:
        return "External Output"
      case .unknown:
        return "Audio Output"
      }
    }

    var symbolName: String {
      switch self {
      case .systemSpeaker:
        return "speaker.wave.2.fill"
      case .bluetoothHeadphones:
        return "airpodspro"
      case .wiredHeadphones:
        return "headphones"
      case .external:
        return "hifispeaker.2.fill"
      case .unknown:
        return "speaker.wave.2.fill"
      }
    }
  }

  let name: String
  let kind: Kind
  let batteryFraction: Double?

  static let unknown = AudioOutputRoute(name: "No output device", kind: .unknown, batteryFraction: nil)
}

private struct NowPlayingItem: Equatable, Sendable {
  var title: String
  var artist: String?
  var source: String
  var duration: TimeInterval
  var elapsedTime: TimeInterval
  var playbackRate: Double
  var timestamp: Date

  var isPlaying: Bool {
    playbackRate > 0.01
  }

  var hasTimedProgress: Bool {
    duration > 0
  }

  var subtitle: String {
    guard let artist, !artist.isEmpty else {
      return source
    }

    return "\(source) • \(artist)"
  }

  var effectiveElapsedTime: TimeInterval {
    effectiveElapsedTime(at: Date())
  }

  func effectiveElapsedTime(at date: Date) -> TimeInterval {
    let elapsed = isPlaying
      ? elapsedTime + date.timeIntervalSince(timestamp) * playbackRate
      : elapsedTime

    guard duration > 0 else {
      return max(0, elapsed)
    }

    return min(duration, max(0, elapsed))
  }

  var progressFraction: Double {
    progressFraction(at: Date())
  }

  func progressFraction(at date: Date) -> Double {
    guard duration > 0 else { return 0 }
    return min(1, max(0, effectiveElapsedTime(at: date) / duration))
  }

  var timeLabel: String {
    timeLabel(at: Date())
  }

  func timeLabel(at date: Date) -> String {
    guard duration > 0 else {
      return isPlaying ? "Playing" : "Paused"
    }

    return "\(Self.formatTime(effectiveElapsedTime(at: date))) / \(Self.formatTime(duration))"
  }

  func withSource(_ source: String?) -> NowPlayingItem {
    guard let source, !source.isEmpty else {
      return self
    }

    var item = self
    item.source = source
    return item
  }

  func preservesTiming(from previous: NowPlayingItem, at date: Date = Date()) -> NowPlayingItem {
    guard !hasTimedProgress, previous.hasTimedProgress, isSameMedia(as: previous) else {
      return self
    }

    var item = self
    item.duration = previous.duration
    item.elapsedTime = previous.effectiveElapsedTime(at: date)
    item.timestamp = date
    return item
  }

  func isSameMedia(as other: NowPlayingItem) -> Bool {
    let lhs = Self.normalizedIdentity(title)
    let rhs = Self.normalizedIdentity(other.title)

    guard lhs.count >= 8, rhs.count >= 8 else {
      return lhs == rhs
    }

    if lhs == rhs {
      return true
    }

    return lhs.count >= 16
      && rhs.count >= 16
      && (lhs.contains(rhs) || rhs.contains(lhs))
  }

  init(
    title: String,
    artist: String?,
    source: String,
    duration: TimeInterval,
    elapsedTime: TimeInterval,
    playbackRate: Double,
    timestamp: Date
  ) {
    self.title = title
    self.artist = artist
    self.source = source
    self.duration = duration
    self.elapsedTime = elapsedTime
    self.playbackRate = playbackRate
    self.timestamp = timestamp
  }

  init?(info: CFDictionary, source: String?, fallbackIsPlaying: Bool?) {
    let dictionary = info as NSDictionary

    guard let title = Self.stringValue(
      in: dictionary,
      keys: ["kMRMediaRemoteNowPlayingInfoTitle"]
    ) else {
      return nil
    }

    self.title = title
    self.artist = Self.stringValue(in: dictionary, keys: ["kMRMediaRemoteNowPlayingInfoArtist"])
    self.source = source
      ?? Self.stringValue(
        in: dictionary,
        keys: [
          "kMRMediaRemoteNowPlayingInfoApplicationDisplayName",
          "kMRMediaRemoteNowPlayingInfoClientDisplayName",
          "kMRMediaRemoteNowPlayingInfoSource"
        ]
      )
      ?? "Now Playing"
    self.duration = Self.doubleValue(in: dictionary, keys: ["kMRMediaRemoteNowPlayingInfoDuration"]) ?? 0
    self.elapsedTime = Self.doubleValue(in: dictionary, keys: ["kMRMediaRemoteNowPlayingInfoElapsedTime"]) ?? 0
    self.playbackRate = Self.doubleValue(in: dictionary, keys: ["kMRMediaRemoteNowPlayingInfoPlaybackRate"])
      ?? (fallbackIsPlaying == true ? 1 : 0)
    self.timestamp = Self.dateValue(in: dictionary, keys: ["kMRMediaRemoteNowPlayingInfoTimestamp"]) ?? Date()
  }

  private static func stringValue(in dictionary: NSDictionary, keys: [String]) -> String? {
    for key in keys {
      if let value = dictionary[key] as? String {
        let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)

        if !trimmedValue.isEmpty {
          return trimmedValue
        }
      }
    }

    return nil
  }

  private static func normalizedIdentity(_ value: String) -> String {
    value
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
      .replacingOccurrences(of: " - youtube", with: "")
      .components(separatedBy: CharacterSet.alphanumerics.inverted)
      .filter { !$0.isEmpty }
      .joined(separator: " ")
  }

  private static func doubleValue(in dictionary: NSDictionary, keys: [String]) -> Double? {
    for key in keys {
      if let value = dictionary[key] as? NSNumber {
        return value.doubleValue
      }

      if let value = dictionary[key] as? Double {
        return value
      }
    }

    return nil
  }

  private static func dateValue(in dictionary: NSDictionary, keys: [String]) -> Date? {
    for key in keys {
      if let value = dictionary[key] as? Date {
        return value
      }
    }

    return nil
  }

  private static func formatTime(_ seconds: TimeInterval) -> String {
    let totalSeconds = max(0, Int(seconds.rounded()))
    let hours = totalSeconds / 3600
    let minutes = totalSeconds / 60 % 60
    let seconds = totalSeconds % 60

    if hours > 0 {
      return String(format: "%d:%02d:%02d", hours, minutes, seconds)
    }

    return String(format: "%d:%02d", minutes, seconds)
  }
}

private struct NowPlayingCandidate: Sendable {
  let item: NowPlayingItem
  let priority: Int

  static func best(in candidates: [NowPlayingCandidate]) -> NowPlayingItem? {
    bestCandidate(in: candidates)?.item
  }

  static func bestCandidate(in candidates: [NowPlayingCandidate]) -> NowPlayingCandidate? {
    candidates.sorted { lhs, rhs in
      if lhs.priority != rhs.priority {
        return lhs.priority > rhs.priority
      }

      if lhs.item.isPlaying != rhs.item.isPlaying {
        return lhs.item.isPlaying
      }

      return lhs.item.timestamp > rhs.item.timestamp
    }.first
  }
}

private final class NowPlayingCandidateStore: @unchecked Sendable {
  private let lock = NSLock()
  private var candidates: [NowPlayingCandidate] = []
  private var didFinish = false

  func append(_ candidate: NowPlayingCandidate?) {
    guard let candidate else { return }

    lock.lock()
    candidates.append(candidate)
    lock.unlock()
  }

  func snapshot() -> [NowPlayingCandidate] {
    lock.lock()
    let snapshot = candidates
    lock.unlock()
    return snapshot
  }

  func finishSnapshot() -> [NowPlayingCandidate]? {
    lock.lock()

    guard !didFinish else {
      lock.unlock()
      return nil
    }

    didFinish = true
    let snapshot = candidates
    lock.unlock()
    return snapshot
  }
}

private enum AppleScriptRunner {
  static func run(_ source: String) -> String? {
    var error: NSDictionary?
    let result = NSAppleScript(source: source)?.executeAndReturnError(&error)

    if let error {
      debugLog("AppleScript error: \(error)")
      return nil
    }

    return result?.stringValue
  }

  static func debugLog(_ message: String) {
    guard ProcessInfo.processInfo.environment["NOTCHY_DEBUG_MEDIA"] == "1",
          let data = "\(message)\n".data(using: .utf8) else {
      return
    }

    FileHandle.standardError.write(data)
  }
}

private enum AutomationPermission {
  static func canAutomate(bundleIdentifier: String) -> Bool {
    status(bundleIdentifier: bundleIdentifier) == noErr
  }

  static func status(bundleIdentifier: String) -> OSStatus {
    determinePermission(bundleIdentifier: bundleIdentifier, askUserIfNeeded: false)
  }

  @discardableResult
  static func request(bundleIdentifier: String) -> OSStatus {
    determinePermission(bundleIdentifier: bundleIdentifier, askUserIfNeeded: true)
  }

  private static func determinePermission(
    bundleIdentifier: String,
    askUserIfNeeded: Bool
  ) -> OSStatus {
    var target = AEAddressDesc()
    let createStatus = bundleIdentifier.withCString { pointer in
      AECreateDesc(
        DescType(typeApplicationBundleID),
        pointer,
        bundleIdentifier.utf8.count,
        &target
      )
    }

    guard createStatus == noErr else {
      return OSStatus(createStatus)
    }

    defer {
      AEDisposeDesc(&target)
    }

    return AEDeterminePermissionToAutomateTarget(
      &target,
      AEEventClass(typeWildCard),
      AEEventID(typeWildCard),
      askUserIfNeeded
    )
  }
}

private func normalizedText(_ value: String, fallback: String) -> String {
  let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
  return text.isEmpty ? fallback : text
}

private func normalizedOptionalText(_ value: String) -> String? {
  let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
  return text.isEmpty ? nil : text
}

@MainActor
private final class NowPlayingMonitor: ObservableObject {
  @Published private(set) var item: NowPlayingItem?

  private let transientMissGraceInterval: TimeInterval = 30
  private var lastTimedItem: NowPlayingItem?
  private var lastTimedItemSeenAt: Date?
  private var timer: Timer?
  private var workspaceObservers: [NSObjectProtocol] = []
  private var isRefreshing = false

  init() {
    requestRefresh()
    timer = Timer.scheduledTimer(withTimeInterval: 2.5, repeats: true) { [weak self] _ in
      Task { @MainActor in
        self?.requestRefresh()
      }
    }

    let notificationCenter = NSWorkspace.shared.notificationCenter
    workspaceObservers.append(
      notificationCenter.addObserver(
        forName: NSWorkspace.didLaunchApplicationNotification,
        object: nil,
        queue: .main
      ) { [weak self] _ in
        Task { @MainActor in
          self?.requestRefresh()
        }
      }
    )
    workspaceObservers.append(
      notificationCenter.addObserver(
        forName: NSWorkspace.didActivateApplicationNotification,
        object: nil,
        queue: .main
      ) { [weak self] _ in
        Task { @MainActor in
          self?.requestRefresh()
        }
      }
    )
  }

  @MainActor
  deinit {
    timer?.invalidate()
    let notificationCenter = NSWorkspace.shared.notificationCenter
    workspaceObservers.forEach { notificationCenter.removeObserver($0) }
  }

  func requestRefresh() {
    guard !isRefreshing else {
      return
    }

    isRefreshing = true
    NowPlayingReader.currentItem { [weak self] item in
      Task { @MainActor in
        guard let self else {
          return
        }

        self.isRefreshing = false
        let stabilizedItem = self.stabilizedItem(item)
        if self.item != stabilizedItem {
          self.item = stabilizedItem
        }
      }
    }
  }

  private func stabilizedItem(_ nextItem: NowPlayingItem?) -> NowPlayingItem? {
    let now = Date()

    guard let nextItem else {
      guard let lastTimedItem,
            lastTimedItem.isPlaying,
            let lastTimedItemSeenAt,
            now.timeIntervalSince(lastTimedItemSeenAt) < transientMissGraceInterval else {
        return nil
      }

      return carriedTimedItem(from: lastTimedItem, at: now)
    }

    let stabilizedItem: NowPlayingItem
    if let lastTimedItem,
       nextItem.isPlaying,
       !nextItem.hasTimedProgress,
       nextItem.isSameMedia(as: lastTimedItem) {
      stabilizedItem = nextItem.preservesTiming(from: lastTimedItem, at: now)
    } else if let currentItem = item {
      stabilizedItem = nextItem.preservesTiming(from: currentItem, at: now)
    } else {
      stabilizedItem = nextItem
    }

    if stabilizedItem.hasTimedProgress {
      lastTimedItem = stabilizedItem
      lastTimedItemSeenAt = now
    }

    return stabilizedItem
  }

  private func carriedTimedItem(from item: NowPlayingItem, at date: Date) -> NowPlayingItem {
    var carriedItem = item
    carriedItem.elapsedTime = item.effectiveElapsedTime(at: date)
    carriedItem.timestamp = date
    lastTimedItem = carriedItem
    return carriedItem
  }
}

private enum NowPlayingReader {
  private static let callbackQueue = DispatchQueue.global(qos: .utility)

  static func currentItem(completion: @escaping @Sendable (NowPlayingItem?) -> Void) {
    currentCandidates { candidates in
      completion(NowPlayingCandidate.best(in: candidates))
    }
  }

  static func diagnosticReport(completion: @escaping @Sendable (String) -> Void) {
    currentCandidates { candidates in
      let sortedCandidates = candidates.sorted { lhs, rhs in
        lhs.priority > rhs.priority
      }
      let best = NowPlayingCandidate.bestCandidate(in: candidates)
      var lines = ["Notchy media diagnosis"]

      if let best {
        lines.append("best: \(Self.describe(best))")
      } else {
        lines.append("best: none")
      }

      if sortedCandidates.isEmpty {
        lines.append("candidates: none")
      } else {
        lines.append("candidates:")
        lines.append(contentsOf: sortedCandidates.map { "  - \(Self.describe($0))" })
      }

      completion(lines.joined(separator: "\n"))
    }
  }

  private static func currentCandidates(completion: @escaping @Sendable ([NowPlayingCandidate]) -> Void) {
    let group = DispatchGroup()
    let store = NowPlayingCandidateStore()

    group.enter()
    mediaRemoteCandidate { candidate in
      store.append(candidate)
      group.leave()
    }

    group.enter()
    BrowserNowPlayingReader.currentCandidate { candidate in
      store.append(candidate)
      group.leave()
    }

    group.enter()
    MusicNowPlayingReader.currentCandidate { candidate in
      store.append(candidate)
      group.leave()
    }

    group.enter()
    QuickTimeNowPlayingReader.currentCandidate { candidate in
      store.append(candidate)
      group.leave()
    }

    let finish: @Sendable () -> Void = {
      guard let snapshot = store.finishSnapshot() else {
        return
      }

      completion(snapshot)
    }

    group.notify(queue: callbackQueue) {
      finish()
    }

    callbackQueue.asyncAfter(deadline: .now() + 2.8) {
      finish()
    }
  }

  private static func mediaRemoteCandidate(completion: @escaping @Sendable (NowPlayingCandidate?) -> Void) {
    let bridge = MediaRemoteBridge.shared

    guard let getNowPlayingInfo = bridge.getNowPlayingInfo else {
      completion(nil)
      return
    }

    currentIsPlaying(using: bridge) { isPlaying in
      getNowPlayingInfo(callbackQueue) { info in
        guard let info else {
          completion(nil)
          return
        }

        guard let item = NowPlayingItem(info: info, source: nil, fallbackIsPlaying: isPlaying) else {
          completion(nil)
          return
        }

        currentSource(using: bridge) { source in
          let item = item.withSource(source)
          let priority = item.isPlaying
            ? (item.duration > 0 ? 118 : 86)
            : (item.duration > 0 ? 62 : 42)
          completion(NowPlayingCandidate(item: item, priority: priority))
        }
      }
    }
  }

  private static func currentIsPlaying(
    using bridge: MediaRemoteBridge,
    completion: @escaping @Sendable (Bool?) -> Void
  ) {
    guard let getApplicationIsPlaying = bridge.getApplicationIsPlaying else {
      completion(nil)
      return
    }

    getApplicationIsPlaying(callbackQueue) { isPlaying in
      completion(isPlaying)
    }
  }

  private static func currentSource(
    using bridge: MediaRemoteBridge,
    completion: @escaping @Sendable (String?) -> Void
  ) {
    if let getNowPlayingClient = bridge.getNowPlayingClient {
      getNowPlayingClient(callbackQueue) { client in
        if let client, let source = sourceName(from: client, using: bridge) {
          completion(source)
          return
        }

        currentApplicationDisplayName(using: bridge, completion: completion)
      }
      return
    }

    currentApplicationDisplayName(using: bridge, completion: completion)
  }

  private static func currentApplicationDisplayName(
    using bridge: MediaRemoteBridge,
    completion: @escaping @Sendable (String?) -> Void
  ) {
    guard let getApplicationDisplayID = bridge.getApplicationDisplayID else {
      completion(nil)
      return
    }

    getApplicationDisplayID(callbackQueue) { displayID in
      guard let displayID else {
        completion(nil)
        return
      }

      let bundleIdentifier = displayID as String
      completion(appName(forBundleIdentifier: bundleIdentifier) ?? bundleIdentifier)
    }
  }

  private static func sourceName(
    from client: UnsafeRawPointer,
    using bridge: MediaRemoteBridge
  ) -> String? {
    if let displayName = bridge.clientDisplayName?(client)?.takeUnretainedValue() as String?,
       !displayName.isEmpty {
      return displayName
    }

    if let bundleIdentifier = bridge.clientBundleIdentifier?(client)?.takeUnretainedValue() as String?,
       !bundleIdentifier.isEmpty {
      return appName(forBundleIdentifier: bundleIdentifier) ?? bundleIdentifier
    }

    return nil
  }

  private static func appName(forBundleIdentifier bundleIdentifier: String) -> String? {
    if let runningName = NSRunningApplication
      .runningApplications(withBundleIdentifier: bundleIdentifier)
      .first?
      .localizedName {
      return runningName
    }

    guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier),
          let bundle = Bundle(url: appURL) else {
      return nil
    }

    return bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
      ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
  }

  private static func describe(_ candidate: NowPlayingCandidate) -> String {
    let item = candidate.item
    let elapsed = Int(item.effectiveElapsedTime.rounded())
    let duration = Int(item.duration.rounded())
    return "priority=\(candidate.priority) source=\(item.source) playing=\(item.isPlaying) elapsed=\(elapsed) duration=\(duration) title=\"\(item.title)\" subtitle=\"\(item.subtitle)\""
  }
}

private enum MusicNowPlayingReader {
  private static let bundleIdentifier = "com.apple.Music"
  private static let fieldSeparator = "__NOTCHY_FIELD__"

  static func currentCandidate(completion: @escaping @Sendable (NowPlayingCandidate?) -> Void) {
    DispatchQueue.global(qos: .utility).async {
      completion(readCandidate())
    }
  }

  private static func readCandidate() -> NowPlayingCandidate? {
    guard isRunning else {
      return nil
    }

    let script = """
      tell application id "\(bundleIdentifier)"
        try
          if player state is stopped then return ""
          set trackName to name of current track
          set trackArtist to artist of current track
          set trackDuration to duration of current track
          set trackPosition to player position
          set stateText to player state as text
          return trackName & "\(fieldSeparator)" & trackArtist & "\(fieldSeparator)" & trackDuration & "\(fieldSeparator)" & trackPosition & "\(fieldSeparator)" & stateText
        on error
          return ""
        end try
      end tell
      """

    guard let output = AppleScriptRunner.run(script), !output.isEmpty else {
      return nil
    }

    let parts = output.components(separatedBy: fieldSeparator)

    guard parts.count >= 5,
          let duration = Double(parts[2]),
          let elapsedTime = Double(parts[3]),
          duration.isFinite,
          elapsedTime.isFinite else {
      return nil
    }

    let state = parts[4].lowercased()
    let isPlaying = state == "playing"
    let item = NowPlayingItem(
      title: normalizedText(parts[0], fallback: "Apple Music"),
      artist: normalizedOptionalText(parts[1]),
      source: "Apple Music",
      duration: max(0, duration),
      elapsedTime: max(0, elapsedTime),
      playbackRate: isPlaying ? 1 : 0,
      timestamp: Date()
    )

    return NowPlayingCandidate(item: item, priority: isPlaying ? 130 : 56)
  }

  private static var isRunning: Bool {
    !NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).isEmpty
  }
}

private enum QuickTimeNowPlayingReader {
  private static let bundleIdentifier = "com.apple.QuickTimePlayerX"
  private static let fieldSeparator = "__NOTCHY_FIELD__"
  private static let permissionLock = NSLock()
  private nonisolated(unsafe) static var didRequestAutomationPermission = false

  static func currentCandidate(completion: @escaping @Sendable (NowPlayingCandidate?) -> Void) {
    DispatchQueue.global(qos: .utility).async {
      completion(readCandidate())
    }
  }

  private static func readCandidate() -> NowPlayingCandidate? {
    guard isRunning else {
      return nil
    }

    let automationStatus = AutomationPermission.status(bundleIdentifier: bundleIdentifier)
    guard automationStatus == noErr else {
      AppleScriptRunner.debugLog("QuickTime automation permission status=\(automationStatus)")
      requestAutomationPermissionIfNeeded()
      return nil
    }

    let script = """
      tell application id "\(bundleIdentifier)"
        if not (exists document 1) then return ""
        set movieDocument to document 1
        set docName to name of movieDocument
        set docDuration to duration of movieDocument
        set docPosition to current time of movieDocument
        set docRate to rate of movieDocument
        set isPlaying to playing of movieDocument
        return docName & "\(fieldSeparator)" & docDuration & "\(fieldSeparator)" & docPosition & "\(fieldSeparator)" & docRate & "\(fieldSeparator)" & isPlaying
      end tell
      """

    guard let output = AppleScriptRunner.run(script), !output.isEmpty else {
      return nil
    }

    let parts = output.components(separatedBy: fieldSeparator)

    guard parts.count >= 5,
          let duration = Double(parts[1]),
          let elapsedTime = Double(parts[2]),
          let rate = Double(parts[3]),
          duration.isFinite,
          elapsedTime.isFinite,
          rate.isFinite else {
      return nil
    }

    let isPlaying = parts[4].lowercased() == "true"
    let item = NowPlayingItem(
      title: normalizedText(parts[0], fallback: "QuickTime Player"),
      artist: nil,
      source: "QuickTime Player",
      duration: max(0, duration),
      elapsedTime: max(0, elapsedTime),
      playbackRate: isPlaying ? max(1, rate) : 0,
      timestamp: Date()
    )

    return NowPlayingCandidate(item: item, priority: isPlaying ? 130 : 56)
  }

  private static var isRunning: Bool {
    !NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).isEmpty
  }

  @MainActor
  static func requestAutomationPermissionFromUser() {
    permissionLock.lock()
    didRequestAutomationPermission = true
    permissionLock.unlock()

    NSApp.activate(ignoringOtherApps: true)
    let status = AutomationPermission.request(bundleIdentifier: bundleIdentifier)
    AppleScriptRunner.debugLog("QuickTime automation permission request status=\(status)")
  }

  private static func requestAutomationPermissionIfNeeded() {
    guard !CommandLine.arguments.contains("--diagnose-media") else {
      return
    }

    permissionLock.lock()
    let shouldRequest = !didRequestAutomationPermission
    didRequestAutomationPermission = true
    permissionLock.unlock()

    guard shouldRequest else {
      return
    }

    DispatchQueue.main.async {
      requestAutomationPermissionFromUser()
    }
  }
}

private enum BrowserNowPlayingReader {
  private struct Browser: Sendable {
    let bundleIdentifier: String
    let appPath: String
    let displayName: String
    let titleProperty: String
    let supportsJavaScriptProgress: Bool
  }

  private struct BrowserPlaybackInfo {
    let title: String
    let artist: String?
    let url: String
    let duration: TimeInterval
    let elapsedTime: TimeInterval
    let playbackRate: Double
  }

  private struct BrowserTabCandidate {
    let item: NowPlayingItem
    let isActive: Bool
  }

  private struct BrowserState {
    let browser: Browser
    let applications: [NSRunningApplication]
    let order: Int

    var isActive: Bool {
      applications.contains(where: \.isActive)
    }
  }

  private static let browsers = [
    Browser(
      bundleIdentifier: "com.google.Chrome.canary",
      appPath: "/Applications/Google Chrome Canary.app",
      displayName: "Chrome Canary",
      titleProperty: "title",
      supportsJavaScriptProgress: true
    ),
    Browser(
      bundleIdentifier: "com.google.Chrome",
      appPath: "/Applications/Google Chrome.app",
      displayName: "Google Chrome",
      titleProperty: "title",
      supportsJavaScriptProgress: true
    ),
    Browser(
      bundleIdentifier: "com.microsoft.edgemac",
      appPath: "/Applications/Microsoft Edge.app",
      displayName: "Microsoft Edge",
      titleProperty: "title",
      supportsJavaScriptProgress: true
    ),
    Browser(
      bundleIdentifier: "company.thebrowser.dia",
      appPath: "/Applications/Dia.app",
      displayName: "Dia",
      titleProperty: "title",
      supportsJavaScriptProgress: false
    ),
    Browser(
      bundleIdentifier: "com.microsoft.edgemac.Canary",
      appPath: "/Applications/Microsoft Edge Canary.app",
      displayName: "Edge Canary",
      titleProperty: "title",
      supportsJavaScriptProgress: true
    ),
    Browser(
      bundleIdentifier: "com.apple.Safari",
      appPath: "/Applications/Safari.app",
      displayName: "Safari",
      titleProperty: "name",
      supportsJavaScriptProgress: false
    )
  ]

  static func currentItem(completion: @escaping @Sendable (NowPlayingItem?) -> Void) {
    currentCandidate { candidate in
      completion(candidate?.item)
    }
  }

  static func currentCandidate(completion: @escaping @Sendable (NowPlayingCandidate?) -> Void) {
    DispatchQueue.global(qos: .utility).async {
      completion(readBestCandidate())
    }
  }

  private static func readBestCandidate() -> NowPlayingCandidate? {
    let states = browserStates()
    AppleScriptRunner.debugLog(
      "browser states: "
        + states
          .map { "\($0.browser.displayName)(active=\($0.isActive))" }
          .joined(separator: ", ")
    )
    var playbackCandidates: [NowPlayingCandidate] = []

    for state in states {
      AppleScriptRunner.debugLog("checking active playback: \(state.browser.displayName)")
      guard let candidate = readNowPlayingPlaybackCandidate(
        from: state.browser,
        applications: state.applications,
        includeInactiveTabs: false
      ) else {
        AppleScriptRunner.debugLog("active playback nil: \(state.browser.displayName)")
        if state.isActive, let tabCandidate = readNowPlayingActiveTabCandidate(
          from: state.browser,
          applications: state.applications
        ) {
          AppleScriptRunner.debugLog("active tab fallback: \(state.browser.displayName)")
          return NowPlayingCandidate(item: tabCandidate.item, priority: 82)
        }

        continue
      }

      if candidate.item.isPlaying {
        AppleScriptRunner.debugLog("playing candidate: \(state.browser.displayName)")
        return candidate
      }

      playbackCandidates.append(candidate)
    }

    if let candidate = NowPlayingCandidate.bestCandidate(in: playbackCandidates) {
      return candidate
    }

    for state in states {
      AppleScriptRunner.debugLog("checking all-tab playback: \(state.browser.displayName)")
      guard let candidate = readNowPlayingPlaybackCandidate(
        from: state.browser,
        applications: state.applications,
        includeInactiveTabs: true
      ) else {
        AppleScriptRunner.debugLog("all-tab playback nil: \(state.browser.displayName)")
        continue
      }

      if candidate.item.isPlaying {
        AppleScriptRunner.debugLog("all-tab playing candidate: \(state.browser.displayName)")
        return candidate
      }

      playbackCandidates.append(candidate)
    }

    let tabCandidates = states
      .compactMap { state -> BrowserTabCandidate? in
        AppleScriptRunner.debugLog("checking tab fallback: \(state.browser.displayName)")
        return readNowPlayingTabCandidate(from: state.browser, applications: state.applications)
      }
      .map { tabCandidate in
        NowPlayingCandidate(item: tabCandidate.item, priority: tabCandidate.isActive ? 62 : 34)
      }

    return NowPlayingCandidate.bestCandidate(in: tabCandidates)
  }

  private static func readNowPlayingPlaybackCandidate(
    from browser: Browser,
    applications: [NSRunningApplication],
    includeInactiveTabs: Bool
  ) -> NowPlayingCandidate? {
    guard let playbackInfo = browserPlaybackInfo(for: browser, includeInactiveTabs: includeInactiveTabs) else {
      return nil
    }

    let item = NowPlayingItem(
      title: normalizedTitle(playbackInfo.title, url: playbackInfo.url),
      artist: normalizedOptionalText(playbackInfo.artist ?? ""),
      source: browser.displayName,
      duration: playbackInfo.duration,
      elapsedTime: playbackInfo.elapsedTime,
      playbackRate: playbackInfo.playbackRate,
      timestamp: Date()
    )

    return NowPlayingCandidate(
      item: item,
      priority: item.isPlaying ? 125 : (applications.contains(where: \.isActive) ? 66 : 52)
    )
  }

  private static func readNowPlayingActiveTabCandidate(
    from browser: Browser,
    applications: [NSRunningApplication]
  ) -> BrowserTabCandidate? {
    guard let tabInfo = browserActiveTabInfo(for: browser),
          isYouTubeWatchURL(tabInfo.url) else {
      return nil
    }

    return BrowserTabCandidate(
      item: NowPlayingItem(
        title: normalizedTitle(tabInfo.title, url: tabInfo.url),
        artist: nil,
        source: browser.displayName,
        duration: 0,
        elapsedTime: 0,
        playbackRate: 1,
        timestamp: Date()
      ),
      isActive: applications.contains(where: { $0.isActive })
    )
  }

  private static func readNowPlayingTabCandidate(
    from browser: Browser,
    applications: [NSRunningApplication]
  ) -> BrowserTabCandidate? {
    guard let tabInfo = browserTabInfo(for: browser),
          let youtubeTab = tabInfo.first(where: { isYouTubeWatchURL($0.url) }) else {
      return nil
    }

    return BrowserTabCandidate(
      item: NowPlayingItem(
        title: normalizedTitle(youtubeTab.title, url: youtubeTab.url),
        artist: nil,
        source: browser.displayName,
        duration: 0,
        elapsedTime: 0,
        playbackRate: 1,
        timestamp: Date()
      ),
      isActive: applications.contains(where: { $0.isActive })
    )
  }

  private static func browserPlaybackInfo(
    for browser: Browser,
    includeInactiveTabs: Bool
  ) -> BrowserPlaybackInfo? {
    guard browser.supportsJavaScriptProgress else {
      return nil
    }

    let inactiveTabScan = includeInactiveTabs
      ? """
          repeat with browserWindow in windows
            repeat with browserTab in tabs of browserWindow
              try
                with timeout of 1 second
                  set mediaState to execute browserTab javascript "\(appleScriptStringLiteral(mediaStateJavaScript))"
                end timeout
                if mediaState is not missing value and mediaState is not "" then return mediaState as text
              end try
            end repeat
          end repeat
        """
      : ""

    let script = """
      tell application id "\(browser.bundleIdentifier)"
        repeat with browserWindow in windows
          try
            set browserTab to active tab of browserWindow
            with timeout of 1 second
              set mediaState to execute browserTab javascript "\(appleScriptStringLiteral(mediaStateJavaScript))"
            end timeout
            if mediaState is not missing value and mediaState is not "" then return mediaState as text
          end try
        end repeat
      \(inactiveTabScan)
      end tell
      return ""
      """

    guard let output = AppleScriptRunner.run(script), !output.isEmpty else {
      return nil
    }

    return parsePlaybackInfo(output)
  }

  private static func browserActiveTabInfo(for browser: Browser) -> (title: String, url: String)? {
    let script = """
      tell application id "\(browser.bundleIdentifier)"
        if (count of windows) is 0 then return ""
        set tabURL to URL of active tab of front window
        if tabURL is missing value then return ""
        set tabTitle to \(browser.titleProperty) of active tab of front window
        if tabTitle is missing value then set tabTitle to ""
        return tabURL & "\(Self.fieldSeparator)" & tabTitle
      end tell
      """

    guard let output = AppleScriptRunner.run(script), !output.isEmpty else {
      return nil
    }

    let parts = output.components(separatedBy: fieldSeparator)

    guard let url = parts.first, !url.isEmpty else {
      return nil
    }

    return (title: parts.dropFirst().joined(separator: fieldSeparator), url: url)
  }

  private static func browserTabInfo(for browser: Browser) -> [(title: String, url: String)]? {
    let script = """
      tell application id "\(browser.bundleIdentifier)"
        set tabRows to {}
        repeat with browserWindow in windows
          repeat with browserTab in tabs of browserWindow
            set tabURL to URL of browserTab
            if tabURL is not missing value then
              set tabTitle to \(browser.titleProperty) of browserTab
              if tabTitle is missing value then set tabTitle to ""
              set end of tabRows to tabURL & "\(Self.fieldSeparator)" & tabTitle
            end if
          end repeat
        end repeat
        set AppleScript's text item delimiters to "\(Self.rowSeparator)"
        return tabRows as text
      end tell
      """

    guard let output = AppleScriptRunner.run(script), !output.isEmpty else {
      return nil
    }

    return output
      .components(separatedBy: rowSeparator)
      .compactMap { row in
        let parts = row.components(separatedBy: fieldSeparator)

        guard let url = parts.first, !url.isEmpty else {
          return nil
        }

        return (title: parts.dropFirst().joined(separator: fieldSeparator), url: url)
      }
  }

  private static func runningApplications(for browser: Browser) -> [NSRunningApplication] {
    NSRunningApplication.runningApplications(withBundleIdentifier: browser.bundleIdentifier)
  }

  private static func browserStates() -> [BrowserState] {
    browsers
      .enumerated()
      .compactMap { index, browser in
        let applications = runningApplications(for: browser)

        guard !applications.isEmpty else {
          return nil
        }

        return BrowserState(browser: browser, applications: applications, order: index)
      }
      .sorted { lhs, rhs in
        if lhs.isActive != rhs.isActive {
          return lhs.isActive
        }

        return lhs.order < rhs.order
      }
  }

  private static func parsePlaybackInfo(_ output: String) -> BrowserPlaybackInfo? {
    let parts = output.components(separatedBy: fieldSeparator)

    guard parts.count >= 6,
          let duration = Double(parts[3]),
          let elapsedTime = Double(parts[4]),
          let playbackRate = Double(parts[5]),
          duration.isFinite,
          elapsedTime.isFinite,
          playbackRate.isFinite else {
      return nil
    }

    return BrowserPlaybackInfo(
      title: parts[1],
      artist: normalizedOptionalText(parts[2]),
      url: parts[0],
      duration: max(0, duration),
      elapsedTime: max(0, elapsedTime),
      playbackRate: max(0, playbackRate)
    )
  }

  private static func appleScriptStringLiteral(_ value: String) -> String {
    value
      .replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "\"", with: "\\\"")
      .replacingOccurrences(of: "\n", with: " ")
  }

  private static func isYouTubeWatchURL(_ url: String) -> Bool {
    let lowercasedURL = url.lowercased()
    return lowercasedURL.contains("youtube.com/watch")
      || lowercasedURL.contains("music.youtube.com/watch")
      || lowercasedURL.contains("youtu.be/")
  }

  private static func normalizedTitle(_ title: String, url: String) -> String {
    let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)

    guard !trimmedTitle.isEmpty else {
      return isYouTubeWatchURL(url) ? "YouTube" : "Media"
    }

    if trimmedTitle.hasSuffix(" - YouTube") {
      return String(trimmedTitle.dropLast(" - YouTube".count))
    }

    return trimmedTitle
  }

  private static let fieldSeparator = "__EDGED_FIELD__"
  private static let rowSeparator = "__EDGED_ROW__"
  private static let mediaStateJavaScript = """
    (() => {
      const mediaItems = Array.from(document.querySelectorAll('video,audio'));
      const media = mediaItems.find((item) => !item.paused && !item.ended)
        || mediaItems.find((item) => Number.isFinite(item.duration) && item.duration > 0 && item.currentTime > 0)
        || mediaItems.find((item) => Number.isFinite(item.duration) && item.duration > 0);
      if (!media) return '';
      const duration = Number.isFinite(media.duration) ? media.duration : 0;
      const elapsedTime = Number.isFinite(media.currentTime) ? media.currentTime : 0;
      const playbackRate = media.paused ? 0 : (Number.isFinite(media.playbackRate) ? media.playbackRate : 1);
      const metadata = navigator.mediaSession && navigator.mediaSession.metadata;
      const title = (metadata && metadata.title) || document.title || '';
      const artist = (metadata && metadata.artist) || '';
      return [location.href || '', title, artist, duration, elapsedTime, playbackRate].join('\(fieldSeparator)');
    })()
    """
}

private typealias MRMediaRemoteSetWantsNowPlayingNotificationsFunction = @convention(c) (Bool) -> Void
private typealias MRMediaRemoteGetNowPlayingInfoFunction = @convention(c) (
  DispatchQueue,
  @escaping @convention(block) (CFDictionary?) -> Void
) -> Void
private typealias MRMediaRemoteGetNowPlayingClientFunction = @convention(c) (
  DispatchQueue,
  @escaping @convention(block) (UnsafeRawPointer?) -> Void
) -> Void
private typealias MRMediaRemoteGetNowPlayingApplicationDisplayIDFunction = @convention(c) (
  DispatchQueue,
  @escaping @convention(block) (CFString?) -> Void
) -> Void
private typealias MRMediaRemoteGetNowPlayingApplicationIsPlayingFunction = @convention(c) (
  DispatchQueue,
  @escaping @convention(block) (Bool) -> Void
) -> Void
private typealias MRNowPlayingClientStringFunction = @convention(c) (UnsafeRawPointer) -> Unmanaged<CFString>?

private final class MediaRemoteBridge: @unchecked Sendable {
  static let shared = MediaRemoteBridge()

  let getNowPlayingInfo: MRMediaRemoteGetNowPlayingInfoFunction?
  let getNowPlayingClient: MRMediaRemoteGetNowPlayingClientFunction?
  let getApplicationDisplayID: MRMediaRemoteGetNowPlayingApplicationDisplayIDFunction?
  let getApplicationIsPlaying: MRMediaRemoteGetNowPlayingApplicationIsPlayingFunction?
  let clientDisplayName: MRNowPlayingClientStringFunction?
  let clientBundleIdentifier: MRNowPlayingClientStringFunction?

  private let handle: UnsafeMutableRawPointer?

  private init() {
    handle = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_LAZY)
    getNowPlayingInfo = Self.load("MRMediaRemoteGetNowPlayingInfo", from: handle)
    getNowPlayingClient = Self.load("MRMediaRemoteGetNowPlayingClient", from: handle)
    getApplicationDisplayID = Self.load("MRMediaRemoteGetNowPlayingApplicationDisplayID", from: handle)
    getApplicationIsPlaying = Self.load("MRMediaRemoteGetNowPlayingApplicationIsPlaying", from: handle)
    clientDisplayName = Self.load("MRNowPlayingClientGetDisplayName", from: handle)
    clientBundleIdentifier = Self.load("MRNowPlayingClientGetBundleIdentifier", from: handle)

    let setWantsNowPlayingNotifications: MRMediaRemoteSetWantsNowPlayingNotificationsFunction? =
      Self.load("MRMediaRemoteSetWantsNowPlayingNotifications", from: handle)
    setWantsNowPlayingNotifications?(true)
  }

  private static func load<T>(_ symbolName: String, from handle: UnsafeMutableRawPointer?) -> T? {
    guard let handle, let symbol = dlsym(handle, symbolName) else {
      return nil
    }

    return unsafeBitCast(symbol, to: T.self)
  }
}

@MainActor
private final class AudioOutputMonitor: ObservableObject {
  @Published private(set) var route = AudioOutputReader.currentRoute()

  private var timer: Timer?

  init() {
    timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
      Task { @MainActor in
        self?.refresh()
      }
    }
  }

  @MainActor
  deinit {
    timer?.invalidate()
  }

  private func refresh() {
    let nextRoute = AudioOutputReader.currentRoute()

    if nextRoute != route {
      route = nextRoute
    }
  }
}

private enum BluetoothBatteryReader {
  static func batteryFraction(matching names: [String]) -> Double? {
    var iterator: io_iterator_t = 0
    let status = IOServiceGetMatchingServices(
      kIOMainPortDefault,
      IOServiceMatching("AppleDeviceManagementHIDEventService"),
      &iterator
    )

    guard status == KERN_SUCCESS else {
      return nil
    }

    defer {
      IOObjectRelease(iterator)
    }

    let normalizedNames = names.map(normalized)
    var fallbackPercent: Double?

    while true {
      let service = IOIteratorNext(iterator)

      if service == 0 {
        break
      }

      defer {
        IOObjectRelease(service)
      }

      guard let properties = properties(for: service),
            isBluetoothDevice(properties),
            let batteryPercent = batteryPercent(in: properties) else {
        continue
      }

      if fallbackPercent == nil {
        fallbackPercent = batteryPercent
      }

      let productName = stringValue(in: properties, keys: ["Product", "Name"])

      if matches(productName: productName, normalizedNames: normalizedNames) {
        return batteryPercent / 100
      }
    }

    return fallbackPercent.map { $0 / 100 }
  }

  private static func properties(for service: io_object_t) -> [String: Any]? {
    var unmanagedProperties: Unmanaged<CFMutableDictionary>?
    let status = IORegistryEntryCreateCFProperties(
      service,
      &unmanagedProperties,
      kCFAllocatorDefault,
      0
    )

    guard status == KERN_SUCCESS,
          let unmanagedProperties,
          let properties = unmanagedProperties.takeRetainedValue() as? [String: Any] else {
      return nil
    }

    return properties
  }

  private static func isBluetoothDevice(_ properties: [String: Any]) -> Bool {
    if let isBluetooth = properties["BluetoothDevice"] as? Bool, isBluetooth {
      return true
    }

    return stringValue(in: properties, keys: ["Transport"]) == "Bluetooth"
  }

  private static func batteryPercent(in properties: [String: Any]) -> Double? {
    let earbudValues = [
      numberValue(in: properties, key: "BatteryPercentSingle"),
      numberValue(in: properties, key: "BatteryPercentLeft"),
      numberValue(in: properties, key: "BatteryPercentRight")
    ].compactMap { $0 }

    if !earbudValues.isEmpty {
      return earbudValues.min()
    }

    return numberValue(in: properties, key: "BatteryPercent")
      ?? numberValue(in: properties, key: "BatteryPercentCombined")
  }

  private static func numberValue(in properties: [String: Any], key: String) -> Double? {
    if let value = properties[key] as? NSNumber {
      return value.doubleValue
    }

    if let value = properties[key] as? Double {
      return value
    }

    if let value = properties[key] as? Int {
      return Double(value)
    }

    return nil
  }

  private static func stringValue(in properties: [String: Any], keys: [String]) -> String? {
    for key in keys {
      if let value = properties[key] as? String, !value.isEmpty {
        return value
      }
    }

    return nil
  }

  private static func matches(productName: String?, normalizedNames: [String]) -> Bool {
    guard let productName else {
      return false
    }

    let normalizedProductName = normalized(productName)

    guard !normalizedProductName.isEmpty else {
      return false
    }

    return normalizedNames.contains { name in
      name.contains(normalizedProductName) || normalizedProductName.contains(name)
    }
  }

  private static func normalized(_ value: String) -> String {
    value
      .lowercased()
      .replacingOccurrences(of: " ", with: "")
      .replacingOccurrences(of: "-", with: "")
      .replacingOccurrences(of: "’", with: "")
      .replacingOccurrences(of: "'", with: "")
  }
}

private enum AudioOutputReader {
  static func currentRoute() -> AudioOutputRoute {
    guard let deviceID = defaultOutputDeviceID() else {
      return .unknown
    }

    let name = deviceName(for: deviceID) ?? "Unknown output"
    let dataSourceName = dataSourceName(for: deviceID)
    let transportType = transportType(for: deviceID)

    let kind = classify(deviceName: name, dataSourceName: dataSourceName, transportType: transportType)

    return AudioOutputRoute(
      name: dataSourceName ?? name,
      kind: kind,
      batteryFraction: kind == .bluetoothHeadphones
        ? BluetoothBatteryReader.batteryFraction(matching: [name, dataSourceName].compactMap { $0 })
        : nil
    )
  }

  private static func defaultOutputDeviceID() -> AudioObjectID? {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioHardwarePropertyDefaultOutputDevice,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    var deviceID = AudioObjectID(kAudioObjectUnknown)
    var dataSize = UInt32(MemoryLayout<AudioObjectID>.size)
    let status = AudioObjectGetPropertyData(
      AudioObjectID(kAudioObjectSystemObject),
      &address,
      0,
      nil,
      &dataSize,
      &deviceID
    )

    guard status == noErr, deviceID != kAudioObjectUnknown else {
      return nil
    }

    return deviceID
  }

  private static func deviceName(for deviceID: AudioObjectID) -> String? {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioObjectPropertyName,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    var name: Unmanaged<CFString>?
    var dataSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    let status = AudioObjectGetPropertyData(
      deviceID,
      &address,
      0,
      nil,
      &dataSize,
      &name
    )

    guard status == noErr, let name else {
      return nil
    }

    return name.takeRetainedValue() as String
  }

  private static func transportType(for deviceID: AudioObjectID) -> UInt32? {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioDevicePropertyTransportType,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    var transportType: UInt32 = 0
    var dataSize = UInt32(MemoryLayout<UInt32>.size)
    let status = AudioObjectGetPropertyData(
      deviceID,
      &address,
      0,
      nil,
      &dataSize,
      &transportType
    )

    guard status == noErr else {
      return nil
    }

    return transportType
  }

  private static func dataSourceName(for deviceID: AudioObjectID) -> String? {
    guard let dataSourceID = selectedDataSourceID(for: deviceID) else {
      return nil
    }

    var address = AudioObjectPropertyAddress(
      mSelector: kAudioDevicePropertyDataSourceNameForIDCFString,
      mScope: kAudioDevicePropertyScopeOutput,
      mElement: kAudioObjectPropertyElementMain
    )
    var sourceID = dataSourceID
    var name: Unmanaged<CFString>?
    var translationSize = UInt32(MemoryLayout<AudioValueTranslation>.size)
    let inputSize = UInt32(MemoryLayout<UInt32>.size)
    let outputSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    let status = withUnsafeMutablePointer(to: &sourceID) { inputPointer in
      withUnsafeMutablePointer(to: &name) { outputPointer in
        var translation = AudioValueTranslation(
          mInputData: UnsafeMutableRawPointer(inputPointer),
          mInputDataSize: inputSize,
          mOutputData: UnsafeMutableRawPointer(outputPointer),
          mOutputDataSize: outputSize
        )

        return AudioObjectGetPropertyData(
          deviceID,
          &address,
          0,
          nil,
          &translationSize,
          &translation
        )
      }
    }

    guard status == noErr, let name else {
      return nil
    }

    return name.takeRetainedValue() as String
  }

  private static func selectedDataSourceID(for deviceID: AudioObjectID) -> UInt32? {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioDevicePropertyDataSource,
      mScope: kAudioDevicePropertyScopeOutput,
      mElement: kAudioObjectPropertyElementMain
    )
    var dataSourceID: UInt32 = 0
    var dataSize = UInt32(MemoryLayout<UInt32>.size)
    let status = AudioObjectGetPropertyData(
      deviceID,
      &address,
      0,
      nil,
      &dataSize,
      &dataSourceID
    )

    guard status == noErr else {
      return nil
    }

    return dataSourceID
  }

  private static func classify(
    deviceName: String,
    dataSourceName: String?,
    transportType: UInt32?
  ) -> AudioOutputRoute.Kind {
    let searchableName = ([deviceName, dataSourceName] as [String?])
      .compactMap { $0?.lowercased() }
      .joined(separator: " ")

    if transportType == kAudioDeviceTransportTypeBluetooth
      || transportType == kAudioDeviceTransportTypeBluetoothLE
      || searchableName.contains("airpods")
      || searchableName.contains("beats")
      || searchableName.contains("bluetooth") {
      return .bluetoothHeadphones
    }

    if searchableName.contains("headphone")
      || searchableName.contains("headset")
      || searchableName.contains("耳机") {
      return .wiredHeadphones
    }

    if transportType == kAudioDeviceTransportTypeBuiltIn
      || searchableName.contains("speaker")
      || searchableName.contains("扬声器")
      || searchableName.contains("macbook") {
      return .systemSpeaker
    }

    if transportType == kAudioDeviceTransportTypeUSB
      || transportType == kAudioDeviceTransportTypeHDMI
      || transportType == kAudioDeviceTransportTypeDisplayPort
      || transportType == kAudioDeviceTransportTypeAirPlay {
      return .external
    }

    return .unknown
  }
}

private final class IslandPanel: NSPanel {
  override var canBecomeKey: Bool { false }
  override var canBecomeMain: Bool { false }
}

private final class HoverPanel: NSPanel {
  override var canBecomeKey: Bool { false }
  override var canBecomeMain: Bool { false }
}

private final class ClickThroughHostingView<Content: View>: NSHostingView<Content> {
  @MainActor @preconcurrency required init(rootView: Content) {
    super.init(rootView: rootView)
    configureTransparency()
  }

  @MainActor @preconcurrency required dynamic init?(coder: NSCoder) {
    super.init(coder: coder)
    configureTransparency()
  }

  override var isOpaque: Bool { false }
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

  private func configureTransparency() {
    wantsLayer = true
    layer?.backgroundColor = NSColor.clear.cgColor
  }
}

private final class HoverTrackingView: NSView {
  var onHoverChanged: ((Bool) -> Void)?
  private var trackingAreaReference: NSTrackingArea?

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    wantsLayer = true
    layer?.backgroundColor = NSColor.clear.cgColor
  }

  required init?(coder: NSCoder) {
    super.init(coder: coder)
    wantsLayer = true
    layer?.backgroundColor = NSColor.clear.cgColor
  }

  override func updateTrackingAreas() {
    if let trackingAreaReference {
      removeTrackingArea(trackingAreaReference)
    }

    let trackingArea = NSTrackingArea(
      rect: bounds,
      options: [.activeAlways, .mouseEnteredAndExited, .inVisibleRect],
      owner: self,
      userInfo: nil
    )
    addTrackingArea(trackingArea)
    trackingAreaReference = trackingArea

    super.updateTrackingAreas()
  }

  override func mouseEntered(with event: NSEvent) {
    onHoverChanged?(true)
  }

  override func mouseExited(with event: NSEvent) {
    onHoverChanged?(false)
  }
}

@MainActor
private final class IslandHoverState: ObservableObject {
  @Published var isHovered = false
}

@main
private enum NotchyMain {
  @MainActor
  private static var appDelegate: AppDelegate?

  @MainActor
  static func main() {
    if CommandLine.arguments.contains("--diagnose-media") {
      runMediaDiagnosis()
      return
    }

    let app = NSApplication.shared
    appDelegate = AppDelegate()
    app.delegate = appDelegate
    appDelegate?.start()
    app.run()
  }

  private static func runMediaDiagnosis() {
    let semaphore = DispatchSemaphore(value: 0)

    NowPlayingReader.diagnosticReport { report in
      print(report)
      semaphore.signal()
    }

    if semaphore.wait(timeout: .now() + 4) == .timedOut {
      print("Notchy media diagnosis timed out")
    }
  }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  private let hoverState = IslandHoverState()
  private var panels: [NSPanel] = []
  private var hoverPanels: [NSPanel] = []
  private var anchorFrames: [CGRect] = []
  private var didStart = false

  func applicationDidFinishLaunching(_ notification: Notification) {
    start()
  }

  func start() {
    guard !didStart else { return }
    didStart = true

    NSApp.setActivationPolicy(.regular)
    installDockIcon()
    installMenu()
    createIslandWindows()
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(screenConfigurationDidChange),
      name: NSApplication.didChangeScreenParametersNotification,
      object: nil
    )
    NSApp.activate(ignoringOtherApps: true)
  }

  private func installDockIcon() {
    guard let image = AppIconAsset.dockIcon() else { return }
    NSApp.applicationIconImage = image
  }

  private func installMenu() {
    let mainMenu = NSMenu()
    let appMenuItem = NSMenuItem()
    let appMenu = NSMenu()

    appMenu.addItem(
      NSMenuItem(
        title: "Allow QuickTime Access",
        action: #selector(requestQuickTimeAccess(_:)),
        keyEquivalent: ""
      )
    )
    appMenu.addItem(.separator())
    appMenu.addItem(
      NSMenuItem(
        title: "Quit Notchy",
        action: #selector(NSApplication.terminate(_:)),
        keyEquivalent: "q"
      )
    )

    appMenuItem.submenu = appMenu
    mainMenu.addItem(appMenuItem)
    NSApp.mainMenu = mainMenu
  }

  @objc private func requestQuickTimeAccess(_ sender: Any?) {
    QuickTimeNowPlayingReader.requestAutomationPermissionFromUser()
  }

  @objc private func screenConfigurationDidChange() {
    createIslandWindows()
  }

  private func createIslandWindows() {
    panels.forEach { panel in
      panel.orderOut(nil)
      panel.close()
    }
    hoverPanels.forEach { panel in
      panel.orderOut(nil)
      panel.close()
    }
    panels.removeAll()
    hoverPanels.removeAll()

    let frames = Self.windowFrames(size: DemoMetrics.windowSize)
    anchorFrames = frames

    panels = frames.map { frame in
      createIslandWindow(frame: frame)
    }
    hoverPanels = frames.map { frame in
      createHoverWindow(anchorFrame: frame)
    }

    panels.forEach { panel in
      panel.orderFrontRegardless()
    }
    hoverPanels.forEach { panel in
      panel.orderFrontRegardless()
    }
  }

  private func createIslandWindow(frame: CGRect) -> NSPanel {
    let hosting = ClickThroughHostingView(rootView: IslandOverlayView(hoverState: hoverState))
    let panel = IslandPanel(
      contentRect: frame,
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: false
    )

    hosting.frame = CGRect(origin: .zero, size: frame.size)
    hosting.autoresizingMask = [.width, .height]
    panel.appearance = NSAppearance(named: .darkAqua)
    panel.backgroundColor = .clear
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    panel.contentView = hosting
    panel.contentView?.wantsLayer = true
    panel.contentView?.layer?.backgroundColor = NSColor.clear.cgColor
    panel.setFrame(frame, display: true)
    panel.hasShadow = false
    panel.hidesOnDeactivate = false
    panel.ignoresMouseEvents = true
    panel.isFloatingPanel = true
    panel.isMovable = false
    panel.isOpaque = false
    panel.isReleasedWhenClosed = false
    panel.level = .screenSaver
    panel.title = "Notchy"
    panel.titleVisibility = .hidden
    panel.titlebarAppearsTransparent = true

    return panel
  }

  private func createHoverWindow(anchorFrame: CGRect) -> NSPanel {
    let frame = Self.topCenterRect(size: DemoMetrics.hoverTriggerSize, in: anchorFrame)
    let trackingView = HoverTrackingView(frame: CGRect(origin: .zero, size: frame.size))
    let panel = HoverPanel(
      contentRect: frame,
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: false
    )

    trackingView.autoresizingMask = [.width, .height]
    trackingView.onHoverChanged = { [weak self, weak panel] hovering in
      Task { @MainActor in
        self?.setHovered(hovering, sourcePanel: panel)
      }
    }
    panel.backgroundColor = .clear
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    panel.contentView = trackingView
    panel.contentView?.wantsLayer = true
    panel.contentView?.layer?.backgroundColor = NSColor.clear.cgColor
    panel.hasShadow = false
    panel.hidesOnDeactivate = false
    panel.ignoresMouseEvents = false
    panel.isFloatingPanel = true
    panel.isMovable = false
    panel.isOpaque = false
    panel.isReleasedWhenClosed = false
    panel.level = .screenSaver
    panel.title = "Notchy Hover"
    panel.titleVisibility = .hidden
    panel.titlebarAppearsTransparent = true

    return panel
  }

  private func setHovered(_ hovering: Bool, sourcePanel: NSPanel?) {
    guard hoverState.isHovered != hovering else {
      return
    }

    hoverState.isHovered = hovering
    resizeHoverPanels(activePanel: hovering ? sourcePanel : nil)
  }

  private func resizeHoverPanels(activePanel: NSPanel?) {
    let defaultSize = hoverState.isHovered
      ? DemoMetrics.hoverRetentionSize
      : DemoMetrics.hoverTriggerSize

    for (index, panel) in hoverPanels.enumerated() {
      let anchorFrame = index < anchorFrames.count ? anchorFrames[index] : panel.frame
      let size = panel === activePanel ? DemoMetrics.hoverRetentionSize : defaultSize
      panel.setFrame(Self.topCenterRect(size: size, in: anchorFrame), display: true)
    }
  }

  private static func topCenterRect(size: CGSize, in frame: CGRect) -> CGRect {
    CGRect(
      x: (frame.midX - size.width / 2).rounded(),
      y: (frame.maxY - size.height).rounded(),
      width: size.width,
      height: size.height
    )
  }

  private static func windowFrames(size: CGSize) -> [CGRect] {
    let screenFrames = targetScreens().map(\.frame)

    guard !screenFrames.isEmpty else {
      return [topCenterFrame(size: size, in: DemoMetrics.fallbackScreenFrame)]
    }

    return screenFrames.map { screenFrame in
      topCenterFrame(size: size, in: screenFrame)
    }
  }

  private static func topCenterFrame(size: CGSize, in screenFrame: CGRect) -> CGRect {
    let x = (screenFrame.midX - size.width / 2).rounded()
    let y = (screenFrame.maxY - size.height).rounded()
    return CGRect(origin: CGPoint(x: x, y: y), size: size)
  }

  private static func targetScreens() -> [NSScreen] {
    let screens = NSScreen.screens

    if let builtIn = screens.first(where: { screen in
      guard let id = displayID(for: screen) else { return false }
      return CGDisplayIsBuiltin(id) != 0
    }) {
      return [builtIn]
    }

    if let namedBuiltIn = screens.first(where: { screen in
      let name = screen.localizedName.lowercased()
      return name.contains("built-in") || name.contains("built in")
    }) {
      return [namedBuiltIn]
    }

    if let main = NSScreen.main {
      return [main]
    }

    return screens
  }

  private static func displayID(for screen: NSScreen) -> CGDirectDisplayID? {
    guard let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
      return nil
    }

    return CGDirectDisplayID(screenNumber.uint32Value)
  }
}

private struct NotchShape: InsettableShape {
  var insetAmount: CGFloat = 0

  func path(in rect: CGRect) -> Path {
    let r = rect.insetBy(dx: insetAmount, dy: insetAmount)
    let radius = min(r.height * 0.42, r.width / 2)

    var path = Path()
    path.move(to: CGPoint(x: r.minX, y: r.minY))
    path.addLine(to: CGPoint(x: r.maxX, y: r.minY))
    path.addLine(to: CGPoint(x: r.maxX, y: r.maxY - radius))
    path.addQuadCurve(
      to: CGPoint(x: r.maxX - radius, y: r.maxY),
      control: CGPoint(x: r.maxX, y: r.maxY)
    )
    path.addLine(to: CGPoint(x: r.minX + radius, y: r.maxY))
    path.addQuadCurve(
      to: CGPoint(x: r.minX, y: r.maxY - radius),
      control: CGPoint(x: r.minX, y: r.maxY)
    )
    path.addLine(to: CGPoint(x: r.minX, y: r.minY))
    path.closeSubpath()

    return path
  }

  func inset(by amount: CGFloat) -> some InsettableShape {
    var shape = self
    shape.insetAmount += amount
    return shape
  }
}

private struct IslandOverlayView: View {
  @StateObject private var nowPlayingMonitor = NowPlayingMonitor()
  @StateObject private var audioOutputMonitor = AudioOutputMonitor()
  @ObservedObject var hoverState: IslandHoverState
  @State private var contentReveal = false

  private var isHovered: Bool {
    hoverState.isHovered
  }

  var body: some View {
    ZStack(alignment: .top) {
      Color.clear
        .allowsHitTesting(false)

      VStack(spacing: 0) {
        island
        Spacer(minLength: 0)
      }
    }
    .frame(width: DemoMetrics.windowSize.width, height: DemoMetrics.windowSize.height)
    .onAppear {
      contentReveal = isHovered
    }
    .onChange(of: isHovered) { _, hovered in
      if hovered {
        nowPlayingMonitor.requestRefresh()
        contentReveal = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) {
          if hoverState.isHovered {
            contentReveal = true
          }
        }
      } else {
        contentReveal = false
      }
    }
  }

  private var island: some View {
    let shape = NotchShape()

    return ZStack(alignment: .top) {
      islandContent
        .frame(
          width: DemoMetrics.expandedSize.width,
          height: DemoMetrics.expandedSize.height,
          alignment: .top
        )
        .allowsHitTesting(isHovered)
        .accessibilityHidden(!isHovered)
    }
    .frame(
      width: isHovered ? DemoMetrics.expandedSize.width : DemoMetrics.collapsedSize.width,
      height: isHovered ? DemoMetrics.expandedSize.height : DemoMetrics.collapsedSize.height,
      alignment: .top
    )
    .clipped()
    .animation(DemoMetrics.expansionAnimation, value: isHovered)
    .background(
      shape
        .fill(Color.black.opacity(0.98))
        .overlay(
          shape
            .strokeBorder(
              isHovered
                ? Color.white.opacity(0.14)
                : Color.white.opacity(0.03),
              lineWidth: 1
            )
            .mask(
              VStack(spacing: 0) {
                Color.clear.frame(height: 2)
                Color.white
              }
            )
        )
    )
    .clipShape(shape)
    .contentShape(shape)
  }

  @ViewBuilder
  private var islandContent: some View {
    if let item = nowPlayingMonitor.item {
      nowPlayingContent(item)
    } else {
      audioOutputContent
    }
  }

  private func nowPlayingContent(_ item: NowPlayingItem) -> some View {
    HStack(spacing: 12) {
      MediaOutputIconView(route: audioOutputMonitor.route, isPlaying: item.isPlaying, isRevealed: contentReveal)
        .stagedAppearance(isVisible: contentReveal, delay: 0.05, yOffset: 2)

      VStack(alignment: .leading, spacing: 4) {
        Text(item.title)
          .font(.system(size: 13, weight: .semibold, design: .rounded))
          .foregroundStyle(.white.opacity(0.96))
          .lineLimit(1)
          .truncationMode(.tail)
          .stagedAppearance(isVisible: contentReveal, delay: 0.11, yOffset: 3)

        HStack(spacing: 8) {
          Text(item.subtitle)
            .font(.system(size: 11, weight: .medium, design: .rounded))
            .foregroundStyle(.white.opacity(0.62))
            .lineLimit(1)
            .truncationMode(.tail)
            .stagedAppearance(isVisible: contentReveal, delay: 0.17, yOffset: 3)

          Spacer(minLength: 0)

          Group {
            if isHovered {
              TimelineView(.periodic(from: .now, by: 0.5)) { context in
                timeLabel(item.timeLabel(at: context.date))
              }
            } else {
              timeLabel(item.timeLabel)
            }
          }
          .stagedAppearance(isVisible: contentReveal, delay: 0.2, yOffset: 2)
        }

        playbackIndicator(for: item)
          .stagedAppearance(isVisible: contentReveal, delay: 0.24, yOffset: 2)
      }

      Spacer(minLength: 0)
    }
    .frame(maxWidth: DemoMetrics.expandedSize.width - 48, alignment: .leading)
    .padding(.horizontal, 24)
    .padding(.top, DemoMetrics.expandedContentTopInset - 2)
  }

  @ViewBuilder
  private func playbackIndicator(for item: NowPlayingItem) -> some View {
    if item.duration <= 0 && item.isPlaying {
      AudioLevelWaveformView(animated: isHovered && contentReveal)
        .frame(height: 10)
        .padding(.top, 1)
    } else if isHovered {
      TimelineView(.periodic(from: .now, by: 0.5)) { context in
        PlaybackProgressView(
          fraction: item.progressFraction(at: context.date),
          reveal: contentReveal ? 1 : 0
        )
      }
      .frame(height: 4)
    } else {
      PlaybackProgressView(fraction: item.progressFraction, reveal: 0)
        .frame(height: 4)
    }
  }

  private func timeLabel(_ label: String) -> some View {
    Text(label)
      .font(.system(size: 10, weight: .medium, design: .rounded))
      .foregroundStyle(.white.opacity(0.52))
      .monospacedDigit()
      .lineLimit(1)
  }

  private var audioOutputContent: some View {
    HStack(spacing: 12) {
      AudioOutputIconView(route: audioOutputMonitor.route, isRevealed: contentReveal)
        .stagedAppearance(isVisible: contentReveal, delay: 0.05, yOffset: 2)

      VStack(alignment: .leading, spacing: 2) {
        Text(audioOutputMonitor.route.kind.label)
          .font(.system(size: 13, weight: .semibold, design: .rounded))
          .foregroundStyle(.white.opacity(0.96))
          .lineLimit(1)
          .stagedAppearance(isVisible: contentReveal, delay: 0.11, yOffset: 3)

        Text(audioOutputMonitor.route.name)
          .font(.system(size: 11, weight: .medium, design: .rounded))
          .foregroundStyle(.white.opacity(0.62))
          .lineLimit(1)
          .truncationMode(.tail)
          .stagedAppearance(isVisible: contentReveal, delay: 0.17, yOffset: 3)
      }

      Spacer(minLength: 0)
    }
    .frame(maxWidth: DemoMetrics.expandedSize.width - 48, alignment: .leading)
    .padding(.horizontal, 24)
    .padding(.top, DemoMetrics.expandedContentTopInset)
  }
}

private struct MediaOutputIconView: View {
  var route: AudioOutputRoute
  var isPlaying: Bool
  var isRevealed: Bool

  var body: some View {
    ZStack(alignment: .bottomTrailing) {
      AudioOutputIconView(route: route, isRevealed: isRevealed)

      Image(systemName: isPlaying ? "play.fill" : "pause.fill")
        .font(.system(size: 7, weight: .bold))
        .foregroundStyle(.black.opacity(0.86))
        .frame(width: 13, height: 13)
        .background(Circle().fill(.white.opacity(0.94)))
        .overlay(Circle().stroke(.black.opacity(0.14), lineWidth: 0.5))
        .offset(x: 2, y: 2)
    }
    .frame(width: 34, height: 34)
  }
}

private struct StagedAppearanceModifier: ViewModifier {
  var isVisible: Bool
  var delay: Double
  var yOffset: CGFloat

  func body(content: Content) -> some View {
    content
      .opacity(isVisible ? 1 : 0)
      .offset(y: isVisible ? 0 : yOffset)
      .animation(
        isVisible
          ? .easeOut(duration: 0.32).delay(delay)
          : .easeOut(duration: 0.06),
        value: isVisible
      )
  }
}

private extension View {
  func stagedAppearance(
    isVisible: Bool,
    delay: Double,
    yOffset: CGFloat
  ) -> some View {
    modifier(StagedAppearanceModifier(isVisible: isVisible, delay: delay, yOffset: yOffset))
  }
}

private struct AudioOutputIconView: View {
  var route: AudioOutputRoute
  var isRevealed = true

  var body: some View {
    ZStack {
      if route.kind == .bluetoothHeadphones, let batteryFraction = route.batteryFraction {
        Circle()
          .stroke(.white.opacity(0.16), lineWidth: 2)
          .frame(width: 32, height: 32)
          .opacity(isRevealed ? 1 : 0)
          .scaleEffect(isRevealed ? 1 : 0.92)

        Circle()
          .trim(from: 0, to: isRevealed ? batteryFraction : 0)
          .stroke(
            batteryColor(for: batteryFraction),
            style: StrokeStyle(lineWidth: 2, lineCap: .round)
          )
          .frame(width: 32, height: 32)
          .rotationEffect(.degrees(isRevealed ? -90 : -210))
          .opacity(isRevealed ? 1 : 0)
          .animation(
            isRevealed
              ? .easeOut(duration: 0.48).delay(0.1)
              : .easeOut(duration: 0.08),
            value: isRevealed
          )
      }

      Image(systemName: route.kind.symbolName)
        .symbolRenderingMode(.hierarchical)
        .font(.system(size: 18, weight: .semibold))
        .foregroundStyle(.white)
        .frame(width: 24, height: 24)
    }
    .frame(width: 32, height: 32)
  }

  private func batteryColor(for fraction: Double) -> Color {
    if fraction <= 0.2 {
      return .red.opacity(0.9)
    }

    if fraction <= 0.45 {
      return .yellow.opacity(0.9)
    }

    return .green.opacity(0.88)
  }
}

private struct PlaybackProgressView: View {
  var fraction: Double
  var reveal: Double = 1

  var body: some View {
    GeometryReader { proxy in
      ZStack(alignment: .leading) {
        Capsule()
          .fill(.white.opacity(0.14))

        Capsule()
          .fill(.white.opacity(0.82))
          .frame(width: proxy.size.width * clampedFraction * clampedReveal)
      }
      .clipShape(Capsule())
    }
    .animation(
      clampedReveal > 0
        ? .easeOut(duration: 0.48).delay(0.22)
        : .easeOut(duration: 0.06),
      value: clampedReveal
    )
  }

  private var clampedFraction: Double {
    min(1, max(0, fraction))
  }

  private var clampedReveal: Double {
    min(1, max(0, reveal))
  }
}

private struct AudioLevelWaveformView: View {
  var animated = true

  private let barCount = 24
  private let spacing: CGFloat = 3

  @ViewBuilder
  var body: some View {
    if animated {
      TimelineView(.animation) { context in
        waveform(at: context.date)
      }
    } else {
      waveform(at: Date())
    }
  }

  private func waveform(at date: Date) -> some View {
    GeometryReader { proxy in
      let availableWidth = max(1, proxy.size.width - CGFloat(barCount - 1) * spacing)
      let barWidth = max(2, availableWidth / CGFloat(barCount))
      let time = date.timeIntervalSinceReferenceDate

      HStack(alignment: .center, spacing: spacing) {
        ForEach(0..<barCount, id: \.self) { index in
          let wave = sin(time * 5.4 + Double(index) * 0.58)
          let counterWave = sin(time * 3.2 + Double(index) * 0.31)
          let level = 0.28 + 0.72 * abs(wave * 0.72 + counterWave * 0.28)

          Capsule()
            .fill(.white.opacity(0.72))
            .frame(width: barWidth, height: max(2, proxy.size.height * level))
        }
      }
      .frame(width: proxy.size.width, height: proxy.size.height, alignment: .center)
    }
  }
}
