import AppKit
import ApplicationServices
import CoreAudio
import CoreGraphics
import Darwin
import Foundation
import IOKit
import ServiceManagement
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

@MainActor
private final class NotchySettings: ObservableObject {
  static let shared = NotchySettings()

  private static let animationsEnabledKey = "notchy.animationsEnabled"
  private static let showsDockIconKey = "notchy.showsDockIcon"
  static let dockIconVisibilityDidChange = Notification.Name("notchy.dockIconVisibilityDidChange")

  @Published var animationsEnabled: Bool {
    didSet {
      UserDefaults.standard.set(animationsEnabled, forKey: Self.animationsEnabledKey)
    }
  }

  @Published var showsDockIcon: Bool {
    didSet {
      UserDefaults.standard.set(showsDockIcon, forKey: Self.showsDockIconKey)
      NotificationCenter.default.post(name: Self.dockIconVisibilityDidChange, object: self)
    }
  }

  @Published private(set) var openAtLoginEnabled: Bool
  @Published private(set) var openAtLoginError: String?

  private init() {
    openAtLoginEnabled = LoginItemController.isEnabled
    openAtLoginError = nil

    if UserDefaults.standard.object(forKey: Self.animationsEnabledKey) == nil {
      animationsEnabled = true
    } else {
      animationsEnabled = UserDefaults.standard.bool(forKey: Self.animationsEnabledKey)
    }

    if UserDefaults.standard.object(forKey: Self.showsDockIconKey) == nil {
      showsDockIcon = true
    } else {
      showsDockIcon = UserDefaults.standard.bool(forKey: Self.showsDockIconKey)
    }
  }

  func refreshOpenAtLoginStatus() {
    openAtLoginEnabled = LoginItemController.isEnabled
  }

  func setOpenAtLoginEnabled(_ isEnabled: Bool) {
    do {
      try LoginItemController.setEnabled(isEnabled)
      openAtLoginError = nil
    } catch {
      openAtLoginError = error.localizedDescription
    }

    refreshOpenAtLoginStatus()
  }
}

private enum LoginItemController {
  static var isEnabled: Bool {
    SMAppService.mainApp.status == .enabled
  }

  static func setEnabled(_ isEnabled: Bool) throws {
    if isEnabled {
      if SMAppService.mainApp.status != .enabled {
        try SMAppService.mainApp.register()
      }
    } else if SMAppService.mainApp.status == .enabled {
      try SMAppService.mainApp.unregister()
    }
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

  var hasKnownPlaybackState: Bool {
    playbackRate >= 0
  }

  var hasUnknownPlaybackState: Bool {
    !hasKnownPlaybackState
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
      guard hasKnownPlaybackState else {
        return "Playing"
      }

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

  func isSameSource(as other: NowPlayingItem) -> Bool {
    let lhs = Self.normalizedIdentity(source)
    let rhs = Self.normalizedIdentity(other.source)

    guard !lhs.isEmpty, !rhs.isEmpty else {
      return false
    }

    return lhs == rhs || lhs.contains(rhs) || rhs.contains(lhs)
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

private struct ConferenceSession: Equatable, Sendable {
  var title: String
  var source: String
  var detail: String
  var timestamp: Date

  var subtitle: String {
    "\(source) • \(detail)"
  }
}

private struct NowPlayingCandidate: Sendable {
  let item: NowPlayingItem
  let priority: Int

  static func best(in candidates: [NowPlayingCandidate]) -> NowPlayingItem? {
    bestCandidate(in: candidates)?.item
  }

  static func bestCandidate(in candidates: [NowPlayingCandidate]) -> NowPlayingCandidate? {
    let sortedCandidates = candidates.sorted { lhs, rhs in
      if lhs.priority != rhs.priority {
        return lhs.priority > rhs.priority
      }

      if lhs.item.isPlaying != rhs.item.isPlaying {
        return lhs.item.isPlaying
      }

      return lhs.item.timestamp > rhs.item.timestamp
    }

    guard let best = sortedCandidates.first else {
      return nil
    }

    if best.item.isPlaying,
       let pausedCandidate = sortedCandidates.first(where: { candidate in
         !candidate.item.isPlaying
           && candidate.item.hasTimedProgress
           && candidate.item.isSameMedia(as: best.item)
           && candidate.item.isSameSource(as: best.item)
       }) {
      return pausedCandidate
    }

    return best
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
private final class ConferenceMonitor: ObservableObject {
  @Published private(set) var session: ConferenceSession?

  private var timer: Timer?
  private var workspaceObservers: [NSObjectProtocol] = []
  private var isRefreshing = false

  init() {
    requestRefresh()
    timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
      Task { @MainActor in
        self?.requestRefresh()
      }
    }

    let notificationCenter = NSWorkspace.shared.notificationCenter
    for name in [
      NSWorkspace.didLaunchApplicationNotification,
      NSWorkspace.didTerminateApplicationNotification,
      NSWorkspace.didActivateApplicationNotification
    ] {
      workspaceObservers.append(
        notificationCenter.addObserver(
          forName: name,
          object: nil,
          queue: .main
        ) { [weak self] _ in
          Task { @MainActor in
            self?.requestRefresh()
          }
        }
      )
    }
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
    ConferenceReader.currentSession { [weak self] session in
      Task { @MainActor in
        guard let self else {
          return
        }

        self.isRefreshing = false
        if self.session != session {
          self.session = session
        }
      }
    }
  }
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
    let playbackState = item.hasKnownPlaybackState
      ? (item.isPlaying ? "playing" : "paused")
      : "unknown"
    return "priority=\(candidate.priority) source=\(item.source) state=\(playbackState) elapsed=\(elapsed) duration=\(duration) title=\"\(item.title)\" subtitle=\"\(item.subtitle)\""
  }
}

private enum ConferenceReader {
  static func currentSession(completion: @escaping @Sendable (ConferenceSession?) -> Void) {
    DispatchQueue.global(qos: .utility).async {
      completion(TeamsConferenceReader.currentSession())
    }
  }
}

private enum TeamsConferenceReader {
  private struct ConferencingApp: Sendable {
    let bundleIdentifiers: [String]
    let displayName: String
    let iconSource: String
    let appPaths: [String]
  }

  private static let app = ConferencingApp(
    bundleIdentifiers: [
      "com.microsoft.teams2",
      "com.microsoft.teams"
    ],
    displayName: "Microsoft Teams",
    iconSource: "Microsoft Teams",
    appPaths: [
      "/Applications/Microsoft Teams.app",
      "~/Applications/Microsoft Teams.app"
    ]
  )

  private static let positiveTitleTokens = [
    "meeting",
    "call",
    "teams meeting",
    "meet now",
    "calling",
    "ringing",
    "webinar",
    "live event",
    "participant",
    "participants",
    "screen share",
    "sharing",
    "presenting",
    "会议",
    "通话",
    "来电",
    "屏幕共享",
    "共享"
  ]

  private static let negativeTitleTokens = [
    "notification",
    "reminder",
    "preferences",
    "settings",
    "通知",
    "提醒",
    "设置"
  ]

  static func currentSession() -> ConferenceSession? {
    let applications = runningApplications(for: app)

    guard !applications.isEmpty else {
      return nil
    }

    let title = matchingMeetingWindowTitle(for: applications)
      ?? (hasActiveCallHelper() ? "Teams Meeting" : nil)

    guard let title else {
      return nil
    }

    return ConferenceSession(
      title: normalizedMeetingTitle(title),
      source: app.displayName,
      detail: "Audio/Video Meeting",
      timestamp: Date()
    )
  }

  private static func runningApplications(for app: ConferencingApp) -> [NSRunningApplication] {
    let exactApplications = app.bundleIdentifiers.flatMap {
      NSRunningApplication.runningApplications(withBundleIdentifier: $0)
    }

    let relatedApplications = NSWorkspace.shared.runningApplications.filter { runningApplication in
      let localizedName = runningApplication.localizedName?.lowercased() ?? ""
      let bundleIdentifier = runningApplication.bundleIdentifier?.lowercased() ?? ""

      return localizedName.contains("microsoft teams")
        || localizedName == "msteams"
        || bundleIdentifier.contains("com.microsoft.teams")
    }

    var seenProcessIDs = Set<pid_t>()
    return (exactApplications + relatedApplications).filter { application in
      seenProcessIDs.insert(application.processIdentifier).inserted
    }
  }

  private static func matchingMeetingWindowTitle(for applications: [NSRunningApplication]) -> String? {
    let processIDs = Set(applications.map(\.processIdentifier))

    guard let windowInfo = CGWindowListCopyWindowInfo(
      [.optionOnScreenOnly, .excludeDesktopElements],
      CGWindowID(0)
    ) as? [[String: Any]] else {
      return nil
    }

    return windowInfo
      .compactMap { window -> String? in
        guard isTeamsWindow(window, matching: processIDs),
              isVisibleWindow(window),
              let title = window[kCGWindowName as String] as? String,
              isLikelyMeetingWindowTitle(title) else {
          return nil
        }

        return title
      }
      .first
  }

  private static func isTeamsWindow(_ window: [String: Any], matching processIDs: Set<pid_t>) -> Bool {
    if let processID = processIdentifier(from: window),
       processIDs.contains(processID) {
      return true
    }

    let ownerName = (window[kCGWindowOwnerName as String] as? String ?? "").lowercased()
    return ownerName.contains("microsoft teams") || ownerName == "msteams"
  }

  private static func processIdentifier(from window: [String: Any]) -> pid_t? {
    if let processIdentifier = window[kCGWindowOwnerPID as String] as? pid_t {
      return processIdentifier
    }

    if let number = window[kCGWindowOwnerPID as String] as? NSNumber {
      return pid_t(number.int32Value)
    }

    return nil
  }

  private static func isVisibleWindow(_ window: [String: Any]) -> Bool {
    if let layer = window[kCGWindowLayer as String] as? Int, layer != 0 {
      return false
    }

    guard let boundsDictionary = window[kCGWindowBounds as String] as? NSDictionary,
          let bounds = CGRect(dictionaryRepresentation: boundsDictionary) else {
      return true
    }

    return bounds.width >= 160 && bounds.height >= 120
  }

  private static func isLikelyMeetingWindowTitle(_ title: String) -> Bool {
    let normalizedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

    guard !normalizedTitle.isEmpty,
          normalizedTitle != "microsoft teams",
          normalizedTitle != "teams" else {
      return false
    }

    guard !negativeTitleTokens.contains(where: { normalizedTitle.contains($0) }) else {
      return false
    }

    return positiveTitleTokens.contains(where: { normalizedTitle.contains($0) })
  }

  private static func hasActiveCallHelper() -> Bool {
    guard let output = processOutput(
      executablePath: "/usr/bin/pgrep",
      arguments: [
        "-fl",
        "Microsoft Teams|MSTeams|teams2|SlimCore|video_capture|audio\\.mojom"
      ]
    )?.lowercased() else {
      return false
    }

    let teamsOutput = output
      .split(separator: "\n")
      .filter { line in
        line.contains("microsoft teams")
          || line.contains("msteams")
          || line.contains("teams2")
      }
      .joined(separator: "\n")

    let hasMediaService = teamsOutput.contains("video_capture.mojom.videocaptureservice")
      || teamsOutput.contains("audio.mojom.audioservice")
    let hasCallEngine = teamsOutput.contains("microsoft teams modulehost")
      && teamsOutput.contains("slimcore")

    return hasMediaService && hasCallEngine
  }

  private static func processOutput(executablePath: String, arguments: [String]) -> String? {
    let process = Process()
    let pipe = Pipe()

    process.executableURL = URL(fileURLWithPath: executablePath)
    process.arguments = arguments
    process.standardOutput = pipe
    process.standardError = Pipe()

    do {
      try process.run()
    } catch {
      return nil
    }

    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()

    guard process.terminationStatus == 0 else {
      return nil
    }

    return String(data: data, encoding: .utf8)
  }

  private static func normalizedMeetingTitle(_ title: String) -> String {
    var cleanedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)

    for suffix in [
      " | Microsoft Teams",
      " - Microsoft Teams",
      " — Microsoft Teams",
      " – Microsoft Teams"
    ] {
      if cleanedTitle.hasSuffix(suffix) {
        cleanedTitle.removeLast(suffix.count)
      }
    }

    let loweredTitle = cleanedTitle.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

    if loweredTitle.isEmpty || loweredTitle == "meeting" || loweredTitle == "call" {
      return "Teams Meeting"
    }

    return cleanedTitle
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
    let supportsInactiveTabJavaScriptScan: Bool

    init(
      bundleIdentifier: String,
      appPath: String,
      displayName: String,
      titleProperty: String,
      supportsJavaScriptProgress: Bool,
      supportsInactiveTabJavaScriptScan: Bool = true
    ) {
      self.bundleIdentifier = bundleIdentifier
      self.appPath = appPath
      self.displayName = displayName
      self.titleProperty = titleProperty
      self.supportsJavaScriptProgress = supportsJavaScriptProgress
      self.supportsInactiveTabJavaScriptScan = supportsInactiveTabJavaScriptScan
    }
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
      bundleIdentifier: "company.thebrowser.Browser",
      appPath: "/Applications/Arc.app",
      displayName: "Arc",
      titleProperty: "title",
      supportsJavaScriptProgress: true
    ),
    Browser(
      bundleIdentifier: "com.brave.Browser",
      appPath: "/Applications/Brave Browser.app",
      displayName: "Brave Browser",
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
      supportsJavaScriptProgress: true,
      supportsInactiveTabJavaScriptScan: false
    ),
    Browser(
      bundleIdentifier: "com.microsoft.edgemac.Canary",
      appPath: "/Applications/Microsoft Edge Canary.app",
      displayName: "Edge Canary",
      titleProperty: "title",
      supportsJavaScriptProgress: true
    ),
    Browser(
      bundleIdentifier: "com.vivaldi.Vivaldi",
      appPath: "/Applications/Vivaldi.app",
      displayName: "Vivaldi",
      titleProperty: "title",
      supportsJavaScriptProgress: true
    ),
    Browser(
      bundleIdentifier: "com.operasoftware.Opera",
      appPath: "/Applications/Opera.app",
      displayName: "Opera",
      titleProperty: "title",
      supportsJavaScriptProgress: true
    ),
    Browser(
      bundleIdentifier: "com.operasoftware.OperaGX",
      appPath: "/Applications/Opera GX.app",
      displayName: "Opera GX",
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
      guard state.browser.supportsInactiveTabJavaScriptScan else {
        AppleScriptRunner.debugLog("all-tab playback skipped: \(state.browser.displayName)")
        continue
      }

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

    if let candidate = NowPlayingCandidate.bestCandidate(in: playbackCandidates) {
      return candidate
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
          isLikelyMediaTab(title: tabInfo.title, url: tabInfo.url) else {
      return nil
    }

    return BrowserTabCandidate(
      item: NowPlayingItem(
        title: normalizedTitle(tabInfo.title, url: tabInfo.url),
        artist: nil,
        source: browser.displayName,
        duration: 0,
        elapsedTime: 0,
        playbackRate: -1,
        timestamp: Date()
      ),
      isActive: applications.contains(where: { $0.isActive })
    )
  }

  private static func readNowPlayingTabCandidate(
    from browser: Browser,
    applications: [NSRunningApplication]
  ) -> BrowserTabCandidate? {
    guard let mediaTab = browserMediaTabInfo(for: browser) else {
      return nil
    }

    return BrowserTabCandidate(
      item: NowPlayingItem(
        title: normalizedTitle(mediaTab.title, url: mediaTab.url),
        artist: nil,
        source: browser.displayName,
        duration: 0,
        elapsedTime: 0,
        playbackRate: -1,
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

  private static func browserMediaTabInfo(for browser: Browser) -> (title: String, url: String)? {
    let script = """
      tell application id "\(browser.bundleIdentifier)"
        with timeout of 2 seconds
          repeat with browserWindow in windows
            repeat with browserTab in tabs of browserWindow
              try
                set tabURL to URL of browserTab
                if tabURL is not missing value then
                  set tabTitle to \(browser.titleProperty) of browserTab
                  if tabTitle is missing value then set tabTitle to ""
                  if tabURL contains "youtube.com/watch" or tabURL contains "music.youtube.com/watch" or tabURL contains "youtu.be/" or tabURL contains "youtube.com/shorts/" or tabURL contains "youtube.com/live/" or tabURL contains "youtube.com/embed/" or tabTitle ends with " - YouTube" then
                    return tabURL & "\(Self.fieldSeparator)" & tabTitle
                  end if
                end if
              end try
            end repeat
          end repeat
        end timeout
      end tell
      return ""
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
      || lowercasedURL.contains("youtube.com/shorts/")
      || lowercasedURL.contains("youtube.com/live/")
      || lowercasedURL.contains("youtube.com/embed/")
  }

  private static func isLikelyMediaTab(title: String, url: String) -> Bool {
    if isYouTubeWatchURL(url) {
      return true
    }

    let lowercasedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    return lowercasedTitle.hasSuffix(" - youtube")
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
  private var settingsWindowController: NSWindowController?
  private var statusItem: NSStatusItem?
  private var settingsObservers: [NSObjectProtocol] = []
  private var didStart = false

  func applicationDidFinishLaunching(_ notification: Notification) {
    start()
  }

  func start() {
    guard !didStart else { return }
    didStart = true

    applyDockIconVisibility()
    installDockIcon()
    installMenu()
    createIslandWindows()
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(screenConfigurationDidChange),
      name: NSApplication.didChangeScreenParametersNotification,
      object: nil
    )
    settingsObservers.append(
      NotificationCenter.default.addObserver(
        forName: NotchySettings.dockIconVisibilityDidChange,
        object: nil,
        queue: .main
      ) { [weak self] _ in
        Task { @MainActor in
          self?.applyDockIconVisibility()
        }
      }
    )
    NSApp.activate(ignoringOtherApps: true)
  }

  @MainActor
  deinit {
    let notificationCenter = NotificationCenter.default
    settingsObservers.forEach { notificationCenter.removeObserver($0) }
  }

  private func installDockIcon() {
    guard let image = AppIconAsset.dockIcon() else { return }
    NSApp.applicationIconImage = image
  }

  private func applyDockIconVisibility() {
    if NotchySettings.shared.showsDockIcon {
      NSApp.setActivationPolicy(.regular)
      removeStatusItem()
    } else {
      NSApp.setActivationPolicy(.accessory)
      installStatusItem()
    }
  }

  private func installStatusItem() {
    guard statusItem == nil else { return }

    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    if let image = AppIconAsset.dockIcon()?.copy() as? NSImage {
      image.size = NSSize(width: 18, height: 18)
      image.isTemplate = false
      item.button?.image = image
    } else {
      item.button?.image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: "Notchy")
    }
    item.button?.toolTip = "Notchy"
    item.menu = makeControlMenu()
    statusItem = item
  }

  private func removeStatusItem() {
    guard let statusItem else { return }
    NSStatusBar.system.removeStatusItem(statusItem)
    self.statusItem = nil
  }

  private func installMenu() {
    let mainMenu = NSMenu()
    let appMenuItem = NSMenuItem()
    let appMenu = makeControlMenu()

    appMenuItem.submenu = appMenu
    mainMenu.addItem(appMenuItem)
    NSApp.mainMenu = mainMenu
  }

  private func makeControlMenu() -> NSMenu {
    let menu = NSMenu()
    let settingsItem = NSMenuItem(
      title: "Settings...",
      action: #selector(showSettings(_:)),
      keyEquivalent: ","
    )
    settingsItem.target = self
    menu.addItem(settingsItem)

    let aboutItem = NSMenuItem(
      title: "About Notchy",
      action: #selector(showAbout(_:)),
      keyEquivalent: ""
    )
    aboutItem.target = self
    menu.addItem(aboutItem)

    menu.addItem(.separator())
    menu.addItem(
      NSMenuItem(
        title: "Quit Notchy",
        action: #selector(NSApplication.terminate(_:)),
        keyEquivalent: "q"
      )
    )

    return menu
  }

  @objc private func showAbout(_ sender: Any?) {
    var options: [NSApplication.AboutPanelOptionKey: Any] = [
      .applicationName: "Notchy",
      .version: "0.1.0",
      .credits: NSAttributedString(string: "A notch-first now playing companion for macOS.")
    ]

    if let image = AppIconAsset.dockIcon() ?? NSApp.applicationIconImage {
      options[.applicationIcon] = image
    }

    NSApp.orderFrontStandardAboutPanel(options: options)
    NSApp.activate(ignoringOtherApps: true)
  }

  @objc private func showSettings(_ sender: Any?) {
    if let window = settingsWindowController?.window {
      window.makeKeyAndOrderFront(nil)
      NSApp.activate(ignoringOtherApps: true)
      return
    }

    let settingsView = NotchySettingsView(settings: .shared)
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 560, height: 460),
      styleMask: [.titled, .closable, .miniaturizable],
      backing: .buffered,
      defer: false
    )
    window.center()
    window.contentView = NSHostingView(rootView: settingsView)
    window.isReleasedWhenClosed = false
    window.title = "Notchy Settings"

    let controller = NSWindowController(window: window)
    settingsWindowController = controller
    controller.showWindow(nil)
    NSApp.activate(ignoringOtherApps: true)
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

private struct NotchySettingsView: View {
  @ObservedObject var settings: NotchySettings
  @State private var permissionRefreshToken = UUID()

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      generalSettings
      Divider()
      permissionSettings
    }
    .padding(20)
    .frame(width: 560, height: 460)
    .onAppear {
      settings.refreshOpenAtLoginStatus()
    }
  }

  private var generalSettings: some View {
    VStack(alignment: .leading, spacing: 10) {
      SettingsToggleRow(title: "Animation", isOn: $settings.animationsEnabled)
      SettingsToggleRow(title: "Show Dock Icon", isOn: $settings.showsDockIcon)
      SettingsToggleRow(
        title: "Open at Login",
        isOn: Binding(
          get: { settings.openAtLoginEnabled },
          set: { settings.setOpenAtLoginEnabled($0) }
        )
      )

      if let error = settings.openAtLoginError {
        Text(error)
          .font(.system(size: 11))
          .foregroundStyle(.secondary)
          .padding(.horizontal, 10)
      }
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 8)
  }

  private var permissionSettings: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Text("Permissions")
          .font(.headline)

        Spacer()

        Button {
          permissionRefreshToken = UUID()
        } label: {
          Image(systemName: "arrow.clockwise")
        }
        .buttonStyle(.borderless)

        Button("Open Automation") {
          SystemSettingsNavigator.openAutomationPrivacy()
        }
      }

      HStack {
        Text("Screen Recording")
          .font(.system(size: 13, weight: .medium))

        Spacer()

        PermissionStateBadge(state: ScreenRecordingPermission.state)

        Button("Request") {
          ScreenRecordingPermission.request()
          permissionRefreshToken = UUID()
        }
        .disabled(!ScreenRecordingPermission.state.canRequest)

        Button("Open") {
          SystemSettingsNavigator.openScreenRecordingPrivacy()
        }
      }
      .padding(.horizontal, 10)
      .padding(.vertical, 8)
      .background(.quaternary.opacity(0.42), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

      ScrollView {
        LazyVStack(spacing: 8) {
          ForEach(NotchyPermissionTarget.installed) { target in
            NotchyPermissionRow(
              target: target,
              refreshToken: permissionRefreshToken
            ) {
              permissionRefreshToken = UUID()
            }
          }
        }
        .padding(.vertical, 2)
      }
    }
  }
}

private struct SettingsToggleRow: View {
  let title: String
  @Binding var isOn: Bool

  var body: some View {
    HStack(spacing: 12) {
      Text(title)
        .font(.headline)

      Spacer()

      SwitchControl(isOn: $isOn)
        .frame(width: 42, height: 24)
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 8)
  }
}

private struct SwitchControl: NSViewRepresentable {
  @Binding var isOn: Bool

  func makeCoordinator() -> Coordinator {
    Coordinator(isOn: $isOn)
  }

  func makeNSView(context: Context) -> NSSwitch {
    let control = NSSwitch()
    control.controlSize = .regular
    control.state = isOn ? .on : .off
    control.target = context.coordinator
    control.action = #selector(Coordinator.switchDidChange(_:))
    return control
  }

  func updateNSView(_ nsView: NSSwitch, context: Context) {
    context.coordinator.isOn = $isOn

    let targetState: NSControl.StateValue = isOn ? .on : .off
    if nsView.state != targetState {
      nsView.state = targetState
    }
  }

  final class Coordinator: NSObject {
    var isOn: Binding<Bool>

    init(isOn: Binding<Bool>) {
      self.isOn = isOn
    }

    @MainActor
    @objc func switchDidChange(_ sender: NSSwitch) {
      isOn.wrappedValue = sender.state == .on
    }
  }
}

private struct NotchyPermissionRow: View {
  let target: NotchyPermissionTarget
  let refreshToken: UUID
  let onRefresh: () -> Void

  var body: some View {
    let _ = refreshToken
    let state = target.permissionState

    HStack(spacing: 12) {
      MediaSourceAppIconView(source: target.iconSource, size: 26)

      VStack(alignment: .leading, spacing: 2) {
        Text(target.displayName)
          .font(.system(size: 13, weight: .medium))

        Text(target.bundleIdentifier)
          .font(.system(size: 10, weight: .regular))
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .truncationMode(.middle)
      }

      Spacer(minLength: 12)

      PermissionStateBadge(state: state)

      Button("Request") {
        target.requestPermission()
        onRefresh()
      }
      .disabled(!state.canRequest)
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 8)
    .background(.quaternary.opacity(0.42), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
  }
}

private struct PermissionStateBadge: View {
  let state: NotchyPermissionState

  var body: some View {
    HStack(spacing: 5) {
      Circle()
        .fill(state.color)
        .frame(width: 7, height: 7)

      Text(state.title)
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(.secondary)
    }
    .frame(width: 104, alignment: .leading)
  }
}

private struct NotchyPermissionTarget: Identifiable {
  let displayName: String
  let bundleIdentifier: String
  let iconSource: String
  let appPaths: [String]

  var id: String {
    bundleIdentifier
  }

  @MainActor
  var permissionState: NotchyPermissionState {
    guard isInstalled else {
      return .notInstalled
    }

    return NotchyPermissionState(status: AutomationPermission.status(bundleIdentifier: bundleIdentifier))
  }

  @MainActor
  func requestPermission() {
    guard isInstalled else { return }
    _ = AutomationPermission.request(bundleIdentifier: bundleIdentifier)
  }

  @MainActor
  var isInstalled: Bool {
    if NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) != nil {
      return true
    }

    return appPaths.contains { appPath in
      FileManager.default.fileExists(atPath: (appPath as NSString).expandingTildeInPath)
    }
  }

  @MainActor
  static var installed: [NotchyPermissionTarget] {
    all.filter(\.isInstalled)
  }

  static let all: [NotchyPermissionTarget] = [
    NotchyPermissionTarget(
      displayName: "Apple Music",
      bundleIdentifier: "com.apple.Music",
      iconSource: "Apple Music",
      appPaths: ["/System/Applications/Music.app", "/Applications/Music.app"]
    ),
    NotchyPermissionTarget(
      displayName: "QuickTime Player",
      bundleIdentifier: "com.apple.QuickTimePlayerX",
      iconSource: "QuickTime Player",
      appPaths: ["/System/Applications/QuickTime Player.app", "/Applications/QuickTime Player.app"]
    ),
    NotchyPermissionTarget(
      displayName: "Chrome Canary",
      bundleIdentifier: "com.google.Chrome.canary",
      iconSource: "Chrome Canary",
      appPaths: ["/Applications/Google Chrome Canary.app", "~/Applications/Google Chrome Canary.app"]
    ),
    NotchyPermissionTarget(
      displayName: "Google Chrome",
      bundleIdentifier: "com.google.Chrome",
      iconSource: "Google Chrome",
      appPaths: ["/Applications/Google Chrome.app", "~/Applications/Google Chrome.app"]
    ),
    NotchyPermissionTarget(
      displayName: "Arc",
      bundleIdentifier: "company.thebrowser.Browser",
      iconSource: "Arc",
      appPaths: ["/Applications/Arc.app", "~/Applications/Arc.app"]
    ),
    NotchyPermissionTarget(
      displayName: "Brave Browser",
      bundleIdentifier: "com.brave.Browser",
      iconSource: "Brave Browser",
      appPaths: ["/Applications/Brave Browser.app", "~/Applications/Brave Browser.app"]
    ),
    NotchyPermissionTarget(
      displayName: "Microsoft Edge",
      bundleIdentifier: "com.microsoft.edgemac",
      iconSource: "Microsoft Edge",
      appPaths: ["/Applications/Microsoft Edge.app", "~/Applications/Microsoft Edge.app"]
    ),
    NotchyPermissionTarget(
      displayName: "Edge Canary",
      bundleIdentifier: "com.microsoft.edgemac.Canary",
      iconSource: "Edge Canary",
      appPaths: ["/Applications/Microsoft Edge Canary.app", "~/Applications/Microsoft Edge Canary.app"]
    ),
    NotchyPermissionTarget(
      displayName: "Dia",
      bundleIdentifier: "company.thebrowser.dia",
      iconSource: "Dia",
      appPaths: ["/Applications/Dia.app", "~/Applications/Dia.app"]
    ),
    NotchyPermissionTarget(
      displayName: "Vivaldi",
      bundleIdentifier: "com.vivaldi.Vivaldi",
      iconSource: "Vivaldi",
      appPaths: ["/Applications/Vivaldi.app", "~/Applications/Vivaldi.app"]
    ),
    NotchyPermissionTarget(
      displayName: "Opera",
      bundleIdentifier: "com.operasoftware.Opera",
      iconSource: "Opera",
      appPaths: ["/Applications/Opera.app", "~/Applications/Opera.app"]
    ),
    NotchyPermissionTarget(
      displayName: "Opera GX",
      bundleIdentifier: "com.operasoftware.OperaGX",
      iconSource: "Opera GX",
      appPaths: ["/Applications/Opera GX.app", "~/Applications/Opera GX.app"]
    ),
    NotchyPermissionTarget(
      displayName: "Safari",
      bundleIdentifier: "com.apple.Safari",
      iconSource: "Safari",
      appPaths: ["/Applications/Safari.app", "/System/Applications/Safari.app"]
    )
  ]
}

private enum NotchyPermissionState: Equatable {
  case allowed
  case denied
  case needsApproval
  case notInstalled
  case notRunning
  case unknown(OSStatus)

  init(status: OSStatus) {
    switch Int(status) {
    case Int(noErr):
      self = .allowed
    case -1743:
      self = .denied
    case -1744:
      self = .needsApproval
    case -600:
      self = .notRunning
    default:
      self = .unknown(status)
    }
  }

  var title: String {
    switch self {
    case .allowed:
      return "Allowed"
    case .denied:
      return "Denied"
    case .needsApproval:
      return "Needs Approval"
    case .notInstalled:
      return "Not Installed"
    case .notRunning:
      return "Not Running"
    case let .unknown(status):
      return "Status \(status)"
    }
  }

  var color: Color {
    switch self {
    case .allowed:
      return Color(nsColor: .systemGreen)
    case .denied:
      return Color(nsColor: .systemRed)
    case .needsApproval:
      return Color(nsColor: .systemYellow)
    case .notInstalled:
      return Color(nsColor: .tertiaryLabelColor)
    case .notRunning:
      return Color(nsColor: .tertiaryLabelColor)
    case .unknown:
      return Color(nsColor: .systemOrange)
    }
  }

  var canRequest: Bool {
    self != .allowed && self != .notInstalled && self != .notRunning
  }
}

private enum ScreenRecordingPermission {
  @MainActor
  static var state: NotchyPermissionState {
    CGPreflightScreenCaptureAccess() ? .allowed : .needsApproval
  }

  @MainActor
  static func request() {
    _ = CGRequestScreenCaptureAccess()
  }
}

private enum SystemSettingsNavigator {
  static func openAutomationPrivacy() {
    let urlStrings = [
      "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation",
      "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Automation"
    ]

    for urlString in urlStrings {
      guard let url = URL(string: urlString) else { continue }

      if NSWorkspace.shared.open(url) {
        return
      }
    }
  }

  static func openScreenRecordingPrivacy() {
    let urlStrings = [
      "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture",
      "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_ScreenCapture"
    ]

    for urlString in urlStrings {
      guard let url = URL(string: urlString) else { continue }

      if NSWorkspace.shared.open(url) {
        return
      }
    }
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

private struct IslandBackgroundView: View {
  var isHovered: Bool

  var body: some View {
    let shape = NotchShape()
    let expandedOpacity = isHovered ? 1.0 : 0.0

    ZStack {
      shape.fill(Color.black)
        .opacity(1 - expandedOpacity)

      Group {
        VisualEffectBlurView(
          material: .underWindowBackground,
          blendingMode: .behindWindow
        )
        .clipShape(shape)
        .mask(glassRevealMask)

        shape.fill(topBlackGradient)
        shape.fill(glassTintGradient)
        shape.fill(bottomFrostGradient).blendMode(.plusLighter)
      }
      .opacity(expandedOpacity)
    }
    .overlay(border(for: shape).opacity(expandedOpacity))
  }

  private var topBlackGradient: LinearGradient {
    LinearGradient(
      stops: [
        .init(color: .black, location: 0),
        .init(color: .black, location: 0.28),
        .init(color: .black.opacity(isHovered ? 0.82 : 0.96), location: 0.44),
        .init(color: .black.opacity(isHovered ? 0.28 : 0.54), location: 0.72),
        .init(color: .black.opacity(isHovered ? 0.12 : 0.34), location: 1)
      ],
      startPoint: .top,
      endPoint: .bottom
    )
  }

  private var glassRevealMask: LinearGradient {
    LinearGradient(
      stops: [
        .init(color: .clear, location: 0),
        .init(color: .clear, location: 0.26),
        .init(color: .white.opacity(isHovered ? 0.55 : 0.18), location: 0.48),
        .init(color: .white.opacity(isHovered ? 1.0 : 0.62), location: 1)
      ],
      startPoint: .top,
      endPoint: .bottom
    )
  }

  private var glassTintGradient: LinearGradient {
    LinearGradient(
      stops: [
        .init(color: .clear, location: 0),
        .init(color: .clear, location: 0.38),
        .init(color: Color(red: 0.04, green: 0.04, blue: 0.045).opacity(isHovered ? 0.08 : 0.04), location: 0.68),
        .init(color: Color(red: 0.10, green: 0.10, blue: 0.11).opacity(isHovered ? 0.16 : 0.08), location: 1)
      ],
      startPoint: .top,
      endPoint: .bottom
    )
  }

  private var bottomFrostGradient: LinearGradient {
    LinearGradient(
      stops: [
        .init(color: .clear, location: 0),
        .init(color: .clear, location: 0.56),
        .init(color: .white.opacity(isHovered ? 0.06 : 0.015), location: 0.82),
        .init(color: .white.opacity(isHovered ? 0.16 : 0.04), location: 1)
      ],
      startPoint: .top,
      endPoint: .bottom
    )
  }

  private func border(for shape: NotchShape) -> some View {
    shape
      .strokeBorder(
        isHovered
          ? Color.white.opacity(0.13)
          : Color.white.opacity(0.025),
        lineWidth: 1
      )
      .mask(
        LinearGradient(
          stops: [
            .init(color: .clear, location: 0),
            .init(color: .clear, location: 0.50),
            .init(color: .white.opacity(0.56), location: 0.76),
            .init(color: .white, location: 1)
          ],
          startPoint: .top,
          endPoint: .bottom
        )
      )
  }
}

private struct VisualEffectBlurView: NSViewRepresentable {
  var material: NSVisualEffectView.Material
  var blendingMode: NSVisualEffectView.BlendingMode

  func makeNSView(context: Context) -> NSVisualEffectView {
    let view = NSVisualEffectView()
    view.blendingMode = blendingMode
    view.material = material
    view.state = .active
    view.appearance = NSAppearance(named: .darkAqua)
    view.wantsLayer = true
    view.layer?.backgroundColor = NSColor.clear.cgColor
    return view
  }

  func updateNSView(_ view: NSVisualEffectView, context: Context) {
    view.blendingMode = blendingMode
    view.material = material
    view.state = .active
    view.appearance = NSAppearance(named: .darkAqua)
  }
}

private enum IslandDisplayState {
  case conference(ConferenceSession)
  case nowPlaying(NowPlayingItem)
  case audioOutput

  static func resolve(
    conferenceSession: ConferenceSession?,
    nowPlayingItem: NowPlayingItem?
  ) -> IslandDisplayState {
    if let conferenceSession {
      return .conference(conferenceSession)
    }

    if let nowPlayingItem {
      return .nowPlaying(nowPlayingItem)
    }

    return .audioOutput
  }
}

private struct IslandOverlayView: View {
  @StateObject private var nowPlayingMonitor = NowPlayingMonitor()
  @StateObject private var conferenceMonitor = ConferenceMonitor()
  @StateObject private var audioOutputMonitor = AudioOutputMonitor()
  @ObservedObject private var settings = NotchySettings.shared
  @ObservedObject var hoverState: IslandHoverState
  @State private var contentReveal = false

  private var isHovered: Bool {
    hoverState.isHovered
  }

  private var displayState: IslandDisplayState {
    IslandDisplayState.resolve(
      conferenceSession: conferenceMonitor.session,
      nowPlayingItem: nowPlayingMonitor.item
    )
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
        conferenceMonitor.requestRefresh()
        if settings.animationsEnabled {
          contentReveal = false
          DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) {
            if hoverState.isHovered {
              contentReveal = true
            }
          }
        } else {
          contentReveal = true
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
    .animation(settings.animationsEnabled ? DemoMetrics.expansionAnimation : nil, value: isHovered)
    .background(IslandBackgroundView(isHovered: isHovered))
    .clipShape(shape)
    .contentShape(shape)
  }

  @ViewBuilder
  private var islandContent: some View {
    switch displayState {
    case let .conference(session):
      conferenceContent(session)
    case let .nowPlaying(item):
      nowPlayingContent(item)
    case .audioOutput:
      audioOutputContent
    }
  }

  private func conferenceContent(_ session: ConferenceSession) -> some View {
    HStack(spacing: 12) {
      MediaOutputIconView(
        route: audioOutputMonitor.route,
        isPlaying: true,
        isRevealed: contentReveal,
        badgeSymbolName: "video.fill"
      )
      .stagedAppearance(isVisible: contentReveal, delay: 0.05, yOffset: 2)

      VStack(alignment: .leading, spacing: 4) {
        Text(session.title)
          .font(.system(size: 13, weight: .semibold, design: .rounded))
          .foregroundStyle(.white.opacity(0.96))
          .lineLimit(1)
          .truncationMode(.tail)
          .stagedAppearance(isVisible: contentReveal, delay: 0.11, yOffset: 3)

        HStack(spacing: 8) {
          HStack(spacing: 5) {
            MediaSourceAppIconView(source: session.source, size: 13)

            Text(session.subtitle)
              .font(.system(size: 11, weight: .medium, design: .rounded))
              .foregroundStyle(.white.opacity(0.62))
              .lineLimit(1)
              .truncationMode(.tail)
          }
          .stagedAppearance(isVisible: contentReveal, delay: 0.17, yOffset: 3)

          Spacer(minLength: 0)

          HStack(spacing: 7) {
            Text("Live")
              .font(.system(size: 10, weight: .semibold, design: .rounded))
              .foregroundStyle(Color(nsColor: .systemGreen).opacity(0.9))
              .lineLimit(1)

            MiniAudioLevelMeterView(
              animated: isHovered && contentReveal && settings.animationsEnabled,
              color: Color(nsColor: .systemGreen).opacity(0.84)
            )
            .frame(width: 22, height: 10)
          }
          .stagedAppearance(isVisible: contentReveal, delay: 0.2, yOffset: 2)
        }
      }

      Spacer(minLength: 0)
    }
    .frame(maxWidth: DemoMetrics.expandedSize.width - 48, alignment: .leading)
    .padding(.horizontal, 24)
    .padding(.top, DemoMetrics.expandedContentTopInset - 2)
  }

  private func nowPlayingContent(_ item: NowPlayingItem) -> some View {
    HStack(spacing: 12) {
      MediaOutputIconView(
        route: audioOutputMonitor.route,
        isPlaying: item.isPlaying || item.hasUnknownPlaybackState,
        isRevealed: contentReveal
      )
        .stagedAppearance(isVisible: contentReveal, delay: 0.05, yOffset: 2)

      VStack(alignment: .leading, spacing: 4) {
        Text(item.title)
          .font(.system(size: 13, weight: .semibold, design: .rounded))
          .foregroundStyle(.white.opacity(0.96))
          .lineLimit(1)
          .truncationMode(.tail)
          .stagedAppearance(isVisible: contentReveal, delay: 0.11, yOffset: 3)

        HStack(spacing: 8) {
          HStack(spacing: 5) {
            MediaSourceAppIconView(source: item.source, size: 13)

            Text(item.subtitle)
              .font(.system(size: 11, weight: .medium, design: .rounded))
              .foregroundStyle(.white.opacity(0.62))
              .lineLimit(1)
              .truncationMode(.tail)
          }
            .stagedAppearance(isVisible: contentReveal, delay: 0.17, yOffset: 3)

          Spacer(minLength: 0)

          playbackStatus(for: item)
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
  private func playbackStatus(for item: NowPlayingItem) -> some View {
    if item.hasTimedProgress {
      Group {
        if isHovered {
          TimelineView(.periodic(from: .now, by: 0.5)) { context in
            timeLabel(item.timeLabel(at: context.date))
          }
        } else {
          timeLabel(item.timeLabel)
        }
      }
    } else if item.isPlaying || item.hasUnknownPlaybackState {
      HStack(spacing: 7) {
        timeLabel(item.timeLabel)

        MiniAudioLevelMeterView(
          animated: isHovered && contentReveal && settings.animationsEnabled && (item.isPlaying || item.hasUnknownPlaybackState),
          color: .white.opacity(0.62)
        )
        .frame(width: 22, height: 10)
      }
    } else {
      timeLabel(item.timeLabel)
    }
  }

  @ViewBuilder
  private func playbackIndicator(for item: NowPlayingItem) -> some View {
    if isHovered {
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
  var badgeSymbolName: String? = nil

  var body: some View {
    ZStack(alignment: .bottomTrailing) {
      AudioOutputIconView(route: route, isRevealed: isRevealed)

      Image(systemName: badgeSymbolName ?? (isPlaying ? "play.fill" : "pause.fill"))
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

private struct MediaSourceAppIconView: View {
  var source: String
  var size: CGFloat = 34

  var body: some View {
    ZStack {
      if let image = MediaSourceAppIconResolver.icon(for: source) {
        Image(nsImage: image)
          .resizable()
          .interpolation(.high)
          .aspectRatio(contentMode: .fit)
          .frame(width: imageSize, height: imageSize)
          .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
      } else {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
          .fill(.white.opacity(0.12))

        Image(systemName: "play.rectangle.fill")
          .font(.system(size: fallbackSymbolSize, weight: .semibold))
          .foregroundStyle(.white.opacity(0.84))
      }
    }
    .frame(width: size, height: size)
  }

  private var imageSize: CGFloat {
    size >= 24 ? size - 2 : size
  }

  private var cornerRadius: CGFloat {
    max(3, size * 0.22)
  }

  private var fallbackSymbolSize: CGFloat {
    size >= 24 ? 15 : 8
  }
}

@MainActor
private enum MediaSourceAppIconResolver {
  private struct IconSpec {
    let bundleIdentifiers: [String]
    let appPaths: [String]
  }

  private static var cache: [String: NSImage] = [:]
  private static var misses = Set<String>()

  private static let specs: [(matches: [String], spec: IconSpec)] = [
    (
      matches: ["chrome canary"],
      spec: IconSpec(
        bundleIdentifiers: ["com.google.Chrome.canary"],
        appPaths: ["/Applications/Google Chrome Canary.app", "~/Applications/Google Chrome Canary.app"]
      )
    ),
    (
      matches: ["google chrome", "chrome"],
      spec: IconSpec(
        bundleIdentifiers: ["com.google.Chrome"],
        appPaths: ["/Applications/Google Chrome.app", "~/Applications/Google Chrome.app"]
      )
    ),
    (
      matches: ["arc"],
      spec: IconSpec(
        bundleIdentifiers: ["company.thebrowser.Browser"],
        appPaths: ["/Applications/Arc.app", "~/Applications/Arc.app"]
      )
    ),
    (
      matches: ["brave"],
      spec: IconSpec(
        bundleIdentifiers: ["com.brave.Browser"],
        appPaths: ["/Applications/Brave Browser.app", "~/Applications/Brave Browser.app"]
      )
    ),
    (
      matches: ["edge canary"],
      spec: IconSpec(
        bundleIdentifiers: ["com.microsoft.edgemac.Canary"],
        appPaths: ["/Applications/Microsoft Edge Canary.app", "~/Applications/Microsoft Edge Canary.app"]
      )
    ),
    (
      matches: ["microsoft edge", "edge"],
      spec: IconSpec(
        bundleIdentifiers: ["com.microsoft.edgemac"],
        appPaths: ["/Applications/Microsoft Edge.app", "~/Applications/Microsoft Edge.app"]
      )
    ),
    (
      matches: ["dia"],
      spec: IconSpec(
        bundleIdentifiers: ["company.thebrowser.dia", "com.thebrowsercompany.dia"],
        appPaths: ["/Applications/Dia.app", "~/Applications/Dia.app"]
      )
    ),
    (
      matches: ["vivaldi"],
      spec: IconSpec(
        bundleIdentifiers: ["com.vivaldi.Vivaldi"],
        appPaths: ["/Applications/Vivaldi.app", "~/Applications/Vivaldi.app"]
      )
    ),
    (
      matches: ["opera gx"],
      spec: IconSpec(
        bundleIdentifiers: ["com.operasoftware.OperaGX"],
        appPaths: ["/Applications/Opera GX.app", "~/Applications/Opera GX.app"]
      )
    ),
    (
      matches: ["opera"],
      spec: IconSpec(
        bundleIdentifiers: ["com.operasoftware.Opera"],
        appPaths: ["/Applications/Opera.app", "~/Applications/Opera.app"]
      )
    ),
    (
      matches: ["quicktime", "quick time"],
      spec: IconSpec(
        bundleIdentifiers: ["com.apple.QuickTimePlayerX"],
        appPaths: ["/System/Applications/QuickTime Player.app", "/Applications/QuickTime Player.app"]
      )
    ),
    (
      matches: ["apple music", "music"],
      spec: IconSpec(
        bundleIdentifiers: ["com.apple.Music"],
        appPaths: ["/System/Applications/Music.app", "/Applications/Music.app"]
      )
    ),
    (
      matches: ["safari"],
      spec: IconSpec(
        bundleIdentifiers: ["com.apple.Safari"],
        appPaths: ["/Applications/Safari.app", "/System/Applications/Safari.app"]
      )
    ),
    (
      matches: ["microsoft teams", "teams"],
      spec: IconSpec(
        bundleIdentifiers: ["com.microsoft.teams2", "com.microsoft.teams"],
        appPaths: ["/Applications/Microsoft Teams.app", "~/Applications/Microsoft Teams.app"]
      )
    )
  ]

  static func icon(for source: String) -> NSImage? {
    let key = source.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

    guard !key.isEmpty, !misses.contains(key) else {
      return nil
    }

    if let cached = cache[key] {
      return cached
    }

    guard let spec = specs.first(where: { entry in
      entry.matches.contains { key.contains($0) }
    })?.spec else {
      misses.insert(key)
      return nil
    }

    guard let image = resolveIcon(for: spec) else {
      misses.insert(key)
      return nil
    }

    cache[key] = image
    return image
  }

  private static func resolveIcon(for spec: IconSpec) -> NSImage? {
    for bundleIdentifier in spec.bundleIdentifiers {
      if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) {
        return NSWorkspace.shared.icon(forFile: appURL.path)
      }
    }

    for appPath in spec.appPaths {
      let expandedPath = (appPath as NSString).expandingTildeInPath
      if FileManager.default.fileExists(atPath: expandedPath) {
        return NSWorkspace.shared.icon(forFile: expandedPath)
      }
    }

    return nil
  }
}

private struct StagedAppearanceModifier: ViewModifier {
  @ObservedObject private var settings = NotchySettings.shared
  var isVisible: Bool
  var delay: Double
  var yOffset: CGFloat

  func body(content: Content) -> some View {
    content
      .opacity(isVisible ? 1 : 0)
      .offset(y: isVisible ? 0 : yOffset)
      .animation(
        settings.animationsEnabled
          ? (isVisible
            ? .easeOut(duration: 0.32).delay(delay)
            : .easeOut(duration: 0.06))
          : nil,
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
  @ObservedObject private var settings = NotchySettings.shared
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
          .rotationEffect(.degrees(settings.animationsEnabled ? (isRevealed ? -90 : -210) : -90))
          .opacity(isRevealed ? 1 : 0)
          .animation(
            settings.animationsEnabled
              ? (isRevealed
                ? .easeOut(duration: 0.48).delay(0.1)
                : .easeOut(duration: 0.08))
              : nil,
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
  @ObservedObject private var settings = NotchySettings.shared
  var fraction: Double
  var reveal: Double = 1

  var body: some View {
    GeometryReader { proxy in
      ZStack(alignment: .leading) {
        Capsule()
          .fill(Color(nsColor: .systemGreen).opacity(0.18))

        Capsule()
          .fill(Color(nsColor: .systemGreen).opacity(0.92))
          .frame(width: proxy.size.width * clampedFraction * clampedReveal)
      }
      .clipShape(Capsule())
    }
    .animation(
      settings.animationsEnabled
        ? (clampedReveal > 0
          ? .easeOut(duration: 0.48).delay(0.22)
          : .easeOut(duration: 0.06))
        : nil,
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

private struct MiniAudioLevelMeterView: View {
  var animated = true
  var color: Color = .white.opacity(0.72)

  private let baseLevels: [CGFloat] = [0.42, 0.76, 0.56, 0.92, 0.48]
  private let spacing: CGFloat = 2

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
      let barWidth = max(2, (proxy.size.width - CGFloat(baseLevels.count - 1) * spacing) / CGFloat(baseLevels.count))
      let time = date.timeIntervalSinceReferenceDate

      HStack(alignment: .center, spacing: spacing) {
        ForEach(0..<baseLevels.count, id: \.self) { index in
          let pulse = animated ? CGFloat(sin(time * 4.8 + Double(index) * 0.82)) * 0.16 : 0
          let level = min(1, max(0.28, baseLevels[index] + pulse))

          Capsule()
            .fill(color)
            .frame(width: barWidth, height: max(2, proxy.size.height * level))
        }
      }
      .frame(width: proxy.size.width, height: proxy.size.height, alignment: .center)
    }
  }
}
