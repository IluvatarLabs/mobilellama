import CloudKit
import CryptoKit
import Flutter
import Foundation
import UIKit

@MainActor
final class ChatCloudSyncBridge {
  init(application: UIApplication, messenger: FlutterBinaryMessenger) {
    self.application = application
    channel = FlutterMethodChannel(
      name: "app.mobollama/chat_sync",
      binaryMessenger: messenger
    )
    accountObserver = NotificationCenter.default.addObserver(forName: .CKAccountChanged, object: nil, queue: nil) { [weak self] _ in
      Task { @MainActor [weak self] in
        guard let self, #available(iOS 17.0, *), let store = self.storeObject as? ChatCloudSyncStore else { return }
        await store.accountMayHaveChanged()
      }
    }
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self else {
        result(
          FlutterError(
            code: "chat_sync_unavailable",
            message: "Chat sync is unavailable.",
            details: nil
          )
        )
        return
      }
      Task { @MainActor in
        await self.handle(call, result: result)
      }
    }
  }

  private let application: UIApplication
  private let channel: FlutterMethodChannel
  private var accountObserver: NSObjectProtocol?
  private var storeObject: AnyObject?
  private var storeTask: Task<AnyObject, Error>?

  deinit {
    if let accountObserver { NotificationCenter.default.removeObserver(accountObserver) }
    channel.setMethodCallHandler(nil)
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) async {
    guard #available(iOS 17.0, *) else {
      switch call.method {
      case "initialize", "status", "disable":
        result(Self.unsupportedStatus)
      default:
        result(
          FlutterError(
            code: "chat_sync_unsupported",
            message: "Apple chat sync requires iOS 17 or later.",
            details: nil
          )
        )
      }
      return
    }

    do {
      let store = try await syncStore()
      switch call.method {
      case "initialize":
        let status = try await store.initialize()
        if status.enabled { application.registerForRemoteNotifications() }
        result(status.map)
      case "enable":
        let status = try await store.enable()
        if status.enabled { application.registerForRemoteNotifications() }
        result(status.map)
      case "disable":
        result(try await store.disable().map)
      case "status":
        result(await store.status().map)
      case "put":
        let arguments = try Self.putArguments(call.arguments)
        try await store.put(
          id: arguments.id,
          json: arguments.json,
          deleted: arguments.deleted
        )
        result(nil)
      case "collectMigration":
        result(try await store.collectMigration().map)
      case "finishMigration":
        result(try await store.finishMigration().map)
      case "sync":
        result(try await store.sync().map)
      case "nextChange":
        result(try await store.nextChange())
      case "acknowledge":
        let token = try Self.acknowledgementToken(call.arguments)
        try await store.acknowledge(token: token)
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    } catch let error as ChatCloudSyncError {
      result(
        FlutterError(
          code: error.code,
          message: error.message,
          details: nil
        )
      )
    } catch {
      result(
        FlutterError(
          code: "chat_sync_failed",
          message: error.localizedDescription,
          details: nil
        )
      )
    }
  }

  @available(iOS 17.0, *)
  private func syncStore() async throws -> ChatCloudSyncStore {
    if let store = storeObject as? ChatCloudSyncStore { return store }
    if let storeTask {
      return try await storeTask.value as! ChatCloudSyncStore
    }
    let channel = channel
    let task = Task.detached(priority: .utility) { () throws -> AnyObject in
      try ChatCloudSyncStore.open {
        await MainActor.run {
          channel.invokeMethod("changed", arguments: nil)
        }
      }
    }
    storeTask = task
    do {
      let object = try await task.value
      storeObject = object
      storeTask = nil
      return object as! ChatCloudSyncStore
    } catch {
      storeTask = nil
      throw error
    }
  }

  private static var unsupportedStatus: [String: Any] {
    [
      "supported": false,
      "enabled": false,
      "pending": 0,
      "lastSync": NSNull(),
      "error": NSNull(),
    ]
  }

  private static func putArguments(_ value: Any?) throws -> (
    id: String,
    json: String?,
    deleted: Bool
  ) {
    guard
      let arguments = value as? [String: Any],
      let id = arguments["id"] as? String,
      let deleted = arguments["deleted"] as? Bool
    else {
      throw ChatCloudSyncError.invalidArguments(
        "Expected id, json, and deleted arguments."
      )
    }
    let json = arguments["json"] as? String
    if deleted && json != nil {
      throw ChatCloudSyncError.invalidArguments(
        "A deleted chat must not include JSON."
      )
    }
    if !deleted && json == nil {
      throw ChatCloudSyncError.invalidArguments(
        "A chat snapshot must include JSON."
      )
    }
    return (id, json, deleted)
  }

  private static func acknowledgementToken(_ value: Any?) throws -> String {
    guard
      let arguments = value as? [String: Any],
      let token = arguments["token"] as? String,
      !token.isEmpty,
      token.utf8.count <= 512
    else {
      throw ChatCloudSyncError.invalidArguments(
        "Expected a non-empty acknowledgement token."
      )
    }
    return token
  }
}

private struct ChatCloudSyncError: Error, LocalizedError {
  let code: String
  let message: String

  var errorDescription: String? { message }

  static func invalidArguments(_ message: String) -> Self {
    Self(code: "invalid_arguments", message: message)
  }

  static func unavailable(_ message: String) -> Self {
    Self(code: "chat_sync_unavailable", message: message)
  }

  static func persistence(_ message: String) -> Self {
    Self(code: "chat_sync_persistence", message: message)
  }

  static func cloud(_ message: String) -> Self {
    Self(code: "chat_sync_cloud", message: message)
  }
}

@available(iOS 17.0, *)
private struct ChatCloudSyncStatus: Sendable {
  let enabled: Bool
  let pending: Int
  let lastSync: Date?
  let error: String?
  var migrationPending = false
  var inventoryReady = false
  var accountScope = ""

  var map: [String: Any] {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return [
      "supported": true,
      "migrationPending": migrationPending,
      "accountScope": accountScope,
      "inventoryReady": inventoryReady,
      "enabled": enabled,
      "pending": pending,
      "lastSync": lastSync.map(formatter.string(from:)) ?? NSNull(),
      "error": error ?? NSNull(),
    ]
  }
}

@available(iOS 17.0, *)
struct ChatCloudSyncState: Codable {
  var schemaVersion = 1
  // Optional for reading the preserved v1 state. Only the V2 store writes these.
  var inventoryReady: Bool?
  var migrationComplete: Bool?
  var oldWritesStopped: Bool?
  var adoptionComplete: Bool?
  var engineCaughtUp: Bool?
  var zoneObserved: Bool?
  var enabled = false
  var accountRecordName: String?
  var engineState: CKSyncEngine.State.Serialization?
  var chats: [String: ChatCloudSyncEntry] = [:]
  var inbox: [ChatCloudSyncInboxItem] = []
  var quarantinedInbox: [ChatCloudSyncInboxItem] = []
  var lastSync: Date?
  var error: String?
}

@available(iOS 17.0, *)
struct ChatCloudSyncEntry: Codable {
  var id: String
  var revision: String
  var digest: String
  var deleted: Bool
  var assetFile: String?
  var systemFields: Data?
  var dirty: Bool
  var inFlightAssets: [String: String] = [:]
}

@available(iOS 17.0, *)
struct ChatCloudSyncInboxItem: Codable {
  var token: String
  var id: String
  var assetFile: String?
  var deleted: Bool
  var conflict: Bool
  var dedupeKey: String
  var source: String?
}

@available(iOS 17.0, *)
private struct ChatCloudServerValue {
  var id: String
  var revision: String
  var digest: String
  var deleted: Bool
  var data: Data?
  var systemFields: Data
}

@available(iOS 17.0, *)
enum ChatCloudSyncLocalPutDecision: Equatable {
  case unchanged
  case preserveConflict(dedupeKey: String)
  case write
}

@available(iOS 17.0, *)
enum ChatCloudSyncStateLogic {
  static func prepareForAccount(
    _ accountRecordName: String,
    state: inout ChatCloudSyncState
  ) -> Bool {
    let switched = state.accountRecordName != nil
      && state.accountRecordName != accountRecordName
    guard switched else {
      state.accountRecordName = accountRecordName
      return false
    }

    state.quarantinedInbox.append(contentsOf: state.inbox)
    state.inbox.removeAll()
    state.engineState = nil
    state.inventoryReady = false
    state.migrationComplete = false
    state.adoptionComplete = false
    state.engineCaughtUp = false
    state.zoneObserved = false
    state.chats.removeAll()
    state.accountRecordName = accountRecordName
    return true
  }

  static func localPutDecision(
    id: String,
    digest: String,
    deleted: Bool,
    state: ChatCloudSyncState
  ) -> ChatCloudSyncLocalPutDecision {
    if state.inbox.contains(where: { !$0.conflict && $0.id == id }) {
      if let server = state.chats[id],
         server.deleted == deleted,
         server.digest == digest {
        return .unchanged
      }
      return .preserveConflict(
        dedupeKey: "pending:\(id):\(deleted):\(digest)"
      )
    }

    if let existing = state.chats[id],
       existing.deleted == deleted,
       existing.digest == digest {
      return .unchanged
    }
    return .write
  }

  @discardableResult
  static func preserveConflict(
    entry: ChatCloudSyncEntry,
    serverRevision: String,
    state: inout ChatCloudSyncState,
    token: @autoclosure () -> String = UUID().uuidString,
    conflictID: @autoclosure () -> String = UUID().uuidString
  ) -> Bool {
    let key = "conflict:\(entry.id):\(entry.revision):\(serverRevision)"
    guard !state.inbox.contains(where: { $0.dedupeKey == key }) else {
      return false
    }
    state.inbox.append(
      ChatCloudSyncInboxItem(
        token: token(),
        id: (entry.id.hasPrefix("folder:") ? "folder:" : entry.id.hasPrefix("chat:") ? "chat:" : "") + conflictID(),
        assetFile: entry.assetFile,
        deleted: entry.deleted,
        conflict: true,
        dedupeKey: key
      )
    )
    return true
  }

  static func applyingSentAcknowledgement(
    revision sentRevision: String?,
    systemFields: Data,
    to entry: ChatCloudSyncEntry
  ) -> (entry: ChatCloudSyncEntry, releasedAsset: String?) {
    var updated = entry
    updated.systemFields = systemFields
    guard let sentRevision else { return (updated, nil) }
    let releasedAsset = updated.inFlightAssets.removeValue(forKey: sentRevision)
    if updated.revision == sentRevision {
      updated.dirty = false
    }
    return (updated, releasedAsset)
  }
}

/// Adapted from Apple's MIT-licensed CKSyncEngine sample. See
/// docs/licenses/apple-cloudkit-sample.txt.
@available(iOS 17.0, *)
private final actor ChatCloudSyncStore: CKSyncEngineDelegate {
  typealias ChangeNotification = @Sendable () async -> Void

  static let container = CKContainer(
    identifier: "iCloud.app.mobollama.mobollama"
  )
  static let zoneName = "ChatsV2"
  static let recordType: CKRecord.RecordType = "Chat"
  static let maxSnapshotBytes = 128 * 1024 * 1024
  static let maxIDBytes = 512

  static func open(
    notifyChanged: @escaping ChangeNotification
  ) throws -> ChatCloudSyncStore {
    let fileManager = FileManager.default
    guard let applicationSupport = fileManager.urls(
      for: .applicationSupportDirectory,
      in: .userDomainMask
    ).first else {
      throw ChatCloudSyncError.persistence(
        "The chat sync storage directory is unavailable."
      )
    }
    let directory = applicationSupport.appendingPathComponent(
      "ChatCloudSyncV2",
      isDirectory: true
    )
    let assetsDirectory = directory.appendingPathComponent(
      "Assets",
      isDirectory: true
    )
    try fileManager.createDirectory(
      at: assetsDirectory,
      withIntermediateDirectories: true
    )
    let stateURL = directory.appendingPathComponent("state.json")
    if !fileManager.fileExists(atPath: stateURL.path) {
      var initial = ChatCloudSyncState()
      let legacyURL = applicationSupport.appendingPathComponent("ChatCloudSync/state.json")
      if fileManager.fileExists(atPath: legacyURL.path) {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let legacy = try decoder.decode(ChatCloudSyncState.self, from: Data(contentsOf: legacyURL))
        guard legacy.schemaVersion == 1 else {
          throw ChatCloudSyncError.persistence("The legacy sync state could not be upgraded. Its files were preserved.")
        }
        initial.enabled = legacy.enabled
        initial.accountRecordName = legacy.accountRecordName
      }
      initial.oldWritesStopped = true
      initial.inventoryReady = false
      initial.migrationComplete = false
      try write(initial, to: stateURL)
    }

    do {
      let data = try Data(contentsOf: stateURL)
      let decoder = JSONDecoder()
      decoder.dateDecodingStrategy = .iso8601
      var state = try decoder.decode(ChatCloudSyncState.self, from: data)
      guard state.schemaVersion == 1 else {
        throw ChatCloudSyncError.persistence(
          "The chat sync state version is not supported."
        )
      }
      for id in state.chats.keys {
        state.chats[id]?.inFlightAssets.removeAll()
      }
      try write(state, to: stateURL)
      cleanupUnreferencedAssets(
        state: state,
        assetsDirectory: assetsDirectory
      )
      return ChatCloudSyncStore(
        stateURL: stateURL,
        assetsDirectory: assetsDirectory,
        state: state,
        loadError: nil,
        notifyChanged: notifyChanged
      )
    } catch {
      return ChatCloudSyncStore(
        stateURL: stateURL,
        assetsDirectory: assetsDirectory,
        state: nil,
        loadError:
          "Chat sync state could not be read. The existing file was preserved: "
          + error.localizedDescription,
        notifyChanged: notifyChanged
      )
    }
  }

  private init(
    stateURL: URL,
    assetsDirectory: URL,
    state: ChatCloudSyncState?,
    loadError: String?,
    notifyChanged: @escaping ChangeNotification
  ) {
    self.stateURL = stateURL
    self.assetsDirectory = assetsDirectory
    self.state = state
    self.loadError = loadError
    self.notifyChanged = notifyChanged
  }

  private let stateURL: URL
  private let assetsDirectory: URL
  private let notifyChanged: ChangeNotification
  private var state: ChatCloudSyncState?
  private var loadError: String?
  private var runtimeError: String?
  private var engine: CKSyncEngine?

  func status() -> ChatCloudSyncStatus {
    guard let state else {
      return ChatCloudSyncStatus(
        enabled: false,
        pending: 0,
        lastSync: nil,
        error: loadError
      )
    }
    return ChatCloudSyncStatus(
      enabled: state.enabled,
      pending: state.chats.values.filter(\.dirty).count + state.inbox.count,
      lastSync: state.lastSync,
      error: runtimeError ?? state.error,
      migrationPending: state.migrationComplete != true,
      inventoryReady: state.inventoryReady == true,
      accountScope: Self.digest(Data((state.accountRecordName ?? "").utf8))
    )
  }

  func initialize() async throws -> ChatCloudSyncStatus {
    try requireState()
    guard state?.enabled == true else { return status() }
    do {
      try await resumeEngineForCurrentAccount()
    } catch {
      try await record(error)
    }
    return status()
  }

  func enable() async throws -> ChatCloudSyncStatus {
    var candidate = try requireState()
    let account = try await availableAccountRecordID()
    let priorAssets = Set(candidate.chats.values.flatMap { entry in
      [entry.assetFile].compactMap { $0 } + Array(entry.inFlightAssets.values)
    })
    let switchedAccount = ChatCloudSyncStateLogic.prepareForAccount(
      account.recordName,
      state: &candidate
    )
    candidate.enabled = true
    candidate.error = switchedAccount && !candidate.quarantinedInbox.isEmpty
      ? "Changes from the previous iCloud account remain on this device and were not uploaded."
      : nil
    try commit(candidate)
    for asset in priorAssets { removeAssetIfUnreferenced(asset) }
    runtimeError = nil
    startEngine()
    await notifyChanged()
    return status()
  }

  func disable() async throws -> ChatCloudSyncStatus {
    var candidate = try requireState()
    candidate.enabled = false
    candidate.error = nil
    try commit(candidate)
    let previousEngine = engine
    engine = nil
    await previousEngine?.cancelOperations()
    runtimeError = nil
    await notifyChanged()
    return status()
  }

  func put(id: String, json: String?, deleted: Bool) async throws {
    try Self.validateID(id)
    var candidate = try requireEnabledState()
    guard candidate.migrationComplete == true else {
      throw ChatCloudSyncError.unavailable("iCloud history upgrade is pending. Local chats remain available.")
    }
    guard id.hasPrefix("chat:") || id.hasPrefix("folder:") else {
      throw ChatCloudSyncError.invalidArguments("Expected a versioned chat or folder identifier.")
    }
    let data: Data?
    let digest: String
    if deleted {
      guard json == nil else {
        throw ChatCloudSyncError.invalidArguments(
          "A deleted chat must not include JSON."
        )
      }
      data = nil
      digest = Self.deletedDigest
    } else {
      guard let json else {
        throw ChatCloudSyncError.invalidArguments(
          "A chat snapshot must include JSON."
        )
      }
      let value = Data(json.utf8)
      guard value.count <= Self.maxSnapshotBytes else {
        throw ChatCloudSyncError.invalidArguments(
          "Chat snapshots must not exceed 128 MiB."
        )
      }
      guard
        let object = try? JSONSerialization.jsonObject(with: value),
        let payload = object as? [String: Any],
        (payload["version"] as? Int) == 2,
        (id.hasPrefix("folder:") ? payload["format"] as? String == "mobilellama-folder" : payload["format"] as? String == "mobilellama-chat-backup")
      else {
        throw ChatCloudSyncError.invalidArguments(
          "A chat snapshot must be a JSON object."
        )
      }
      data = value
      digest = Self.digest(value)
    }

    switch ChatCloudSyncStateLogic.localPutDecision(
      id: id,
      digest: digest,
      deleted: deleted,
      state: candidate
    ) {
    case .unchanged:
      if candidate.chats[id]?.dirty == true, let engine {
        engine.state.add(
          pendingRecordZoneChanges: [.saveRecord(Self.recordID(id))]
        )
      }
      return
    case .preserveConflict(let dedupeKey):
      if !candidate.inbox.contains(where: { $0.dedupeKey == dedupeKey }) {
        let file = try data.map(writeAsset)
        candidate.inbox.append(
          ChatCloudSyncInboxItem(
            token: UUID().uuidString,
            id: (id.hasPrefix("folder:") ? "folder:" : "chat:") + UUID().uuidString,
            assetFile: file,
            deleted: deleted,
            conflict: true,
            dedupeKey: dedupeKey
          )
        )
        try commit(candidate)
        await notifyChanged()
      }
      return
    case .write:
      break
    }

    let assetFile = try data.map(writeAsset)
    let previousAsset = candidate.chats[id]?.assetFile
    let revision = UUID().uuidString
    candidate.chats[id] = ChatCloudSyncEntry(
      id: id,
      revision: revision,
      digest: digest,
      deleted: deleted,
      assetFile: assetFile,
      systemFields: candidate.chats[id]?.systemFields,
      dirty: true,
      inFlightAssets: candidate.chats[id]?.inFlightAssets ?? [:]
    )
    do {
      try commit(candidate)
    } catch {
      if let assetFile { try? FileManager.default.removeItem(at: assetURL(assetFile)) }
      throw error
    }
    engine?.state.add(
      pendingRecordZoneChanges: [.saveRecord(Self.recordID(id))]
    )
    removeAssetIfUnreferenced(previousAsset)
    await notifyChanged()
  }

  func collectMigration() async throws -> ChatCloudSyncStatus {
    let initial = try requireEnabledState()
    try await validateCurrentAccount()
    if initial.inventoryReady == true || initial.migrationComplete == true { return status() }
    let account = try await availableAccountRecordID()
    guard account.recordName == initial.accountRecordName else {
      throw ChatCloudSyncError.unavailable("The iCloud account changed. Enable sync explicitly for this account.")
    }
    // No engine is running and put is fenced while these inventories are read.
    let modern = try await collectZone(Self.zoneID)
    let legacy = try await collectZone(CKRecordZone.ID(zoneName: "Chats"))
    guard (try await availableAccountRecordID()).recordName == account.recordName else {
      throw ChatCloudSyncError.unavailable("The iCloud account changed during the history upgrade.")
    }
    var candidate = try requireEnabledState()
    guard candidate.accountRecordName == account.recordName else {
      throw ChatCloudSyncError.unavailable("The iCloud account changed during the history upgrade.")
    }
    candidate.chats.removeAll()
    candidate.inbox.removeAll()
    for value in modern.values.sorted(by: { $0.id < $1.id }) {
      let file = try value.data.map(writeAsset)
      candidate.chats[value.id] = ChatCloudSyncEntry(id: value.id, revision: value.revision,
        digest: value.digest, deleted: value.deleted, assetFile: file,
        systemFields: value.systemFields.isEmpty ? nil : value.systemFields, dirty: false)
      candidate.inbox.append(ChatCloudSyncInboxItem(token: UUID().uuidString, id: value.id,
        assetFile: file, deleted: value.deleted, conflict: false,
        dedupeKey: "upgrade:v2:\(value.id):\(value.digest)", source: "v2"))
    }
    for value in legacy.values.sorted(by: { $0.id < $1.id }) {
      let file = try value.data.map(writeAsset)
      candidate.inbox.append(ChatCloudSyncInboxItem(token: UUID().uuidString, id: "chat:" + value.id,
        assetFile: file, deleted: value.deleted, conflict: false,
        dedupeKey: "upgrade:legacy:\(value.id):\(value.digest)", source: "legacy"))
    }
    // Pending v1 conflict copies may never have reached SQLite or the server.
    // Preserve their assets as migration input, without mutating the old store.
    let legacyDirectory = stateURL.deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("ChatCloudSync")
    let legacyURL = legacyDirectory.appendingPathComponent("state.json")
    if FileManager.default.fileExists(atPath: legacyURL.path) {
      let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
      let old = try decoder.decode(ChatCloudSyncState.self, from: Data(contentsOf: legacyURL))
      if old.accountRecordName == account.recordName {
        for entry in old.chats.values where entry.dirty && entry.deleted {
          candidate.inbox.insert(ChatCloudSyncInboxItem(token: UUID().uuidString,
            id: "chat:" + entry.id, assetFile: nil, deleted: true, conflict: false,
            dedupeKey: "upgrade:local-deletion:" + entry.id, source: "legacyDeletion"), at: 0)
        }
        for item in old.inbox where item.conflict && !item.deleted {
          guard let file = item.assetFile, Self.validAssetName(file) else {
            throw ChatCloudSyncError.persistence("A pending legacy snapshot is missing.")
          }
          let copied = try writeAsset(Self.readBounded(legacyDirectory.appendingPathComponent("Assets").appendingPathComponent(file)))
          candidate.inbox.append(ChatCloudSyncInboxItem(token: UUID().uuidString,
            id: "chat:" + item.id, assetFile: copied, deleted: false, conflict: item.conflict,
            dedupeKey: "upgrade:legacy-local:" + item.dedupeKey, source: "legacyLocal"))
        }
      }
    }
    candidate.inventoryReady = true
    candidate.error = nil
    try commit(candidate)
    runtimeError = nil
    await notifyChanged()
    return status()
  }

  private func collectZone(_ zone: CKRecordZone.ID) async throws -> [String: ChatCloudServerValue] {
    var values: [String: ChatCloudServerValue] = [:]
    var token: CKServerChangeToken?
    while true {
      do {
        let page = try await Self.container.privateCloudDatabase.recordZoneChanges(
          inZoneWith: zone, since: token, resultsLimit: 100)
        for result in page.modificationResultsByID.values {
          let value = try decode(result.get().record)
          values[value.id] = value
        }
        for deletion in page.deletions {
          let id = deletion.recordID.recordName
          if page.modificationResultsByID[deletion.recordID] != nil {
            do {
              values[id] = try decode(await Self.container.privateCloudDatabase.record(for: deletion.recordID))
              continue
            } catch let error as CKError where error.code == .unknownItem { }
          }
          values[id] = ChatCloudServerValue(id: id, revision: "deleted",
            digest: Self.deletedDigest, deleted: true, data: nil, systemFields: Data())
        }
        if zone == Self.zoneID {
          var observed = try requireEnabledState(); observed.zoneObserved = true; try commit(observed)
        }
        token = page.changeToken
        if !page.moreComing { return values }
      } catch let error as CKError where error.code == .zoneNotFound {
        // A zone that has never been created is a complete empty inventory.
        guard token == nil, values.isEmpty, zone != Self.zoneID || state?.zoneObserved != true else { throw error }
        return [:]
      }
    }
  }

  func finishMigration() async throws -> ChatCloudSyncStatus {
    try await validateCurrentAccount()
    var candidate = try requireEnabledState()
    guard candidate.inventoryReady == true, candidate.inbox.isEmpty else {
      throw ChatCloudSyncError.unavailable("Finish adopting the complete iCloud inventory before uploading local history.")
    }
    candidate.adoptionComplete = true
    try commit(candidate)
    startEngine()
    if candidate.engineCaughtUp != true {
      guard let current = engine else { throw ChatCloudSyncError.unavailable("iCloud sync could not start.") }
      try await current.fetchChanges(.init(scope: .zoneIDs([Self.zoneID])))
      guard engine === current else { throw ChatCloudSyncError.unavailable("iCloud fetching was interrupted.") }
      try await validateCurrentAccount()
      candidate = try requireEnabledState()
      guard candidate.error == nil else { throw ChatCloudSyncError.cloud(candidate.error!) }
      candidate.engineCaughtUp = true
      try commit(candidate)
    }
    candidate = try requireEnabledState()
    // The first engine fetch can add newer snapshots; Dart adopts those before
    // this second call opens the record-send fence.
    if !candidate.inbox.isEmpty { return status() }
    candidate.migrationComplete = true
    try commit(candidate)
    await notifyChanged()
    return status()
  }

  private func validateCurrentAccount() async throws {
    let before = try requireEnabledState()
    let account = try await availableAccountRecordID()
    guard (try requireEnabledState()).accountRecordName == before.accountRecordName,
          account.recordName == before.accountRecordName else {
      var candidate = try requireState()
      candidate.enabled = false
      candidate.error = "The iCloud account changed. Local chats were kept. Enable sync explicitly for the current account."
      candidate.quarantinedInbox.append(contentsOf: candidate.inbox)
      candidate.inbox.removeAll()
      candidate.inventoryReady = false
      candidate.adoptionComplete = false
      candidate.engineCaughtUp = false
      candidate.migrationComplete = false
      try commit(candidate)
      let previous = engine; engine = nil
      await previous?.cancelOperations()
      await notifyChanged()
      throw ChatCloudSyncError.unavailable(candidate.error!)
    }
  }

  func accountMayHaveChanged() async {
    guard state?.enabled == true else { return }
    do { try await validateCurrentAccount() }
    catch { try? await record(error) }
  }

  func sync() async throws -> ChatCloudSyncStatus {
    var candidate = try requireEnabledState()
    candidate.error = nil
    try commit(candidate)
    runtimeError = nil
    do {
      if engine == nil { try await resumeEngineForCurrentAccount() }
      guard let engine else {
        throw ChatCloudSyncError.unavailable(
          "Chat sync could not start."
        )
      }
      try await engine.fetchChanges(.init(scope: .zoneIDs([Self.zoneID])))
      try await engine.sendChanges()
      if status().error == nil {
        candidate = try requireEnabledState()
        candidate.lastSync = Date()
        try commit(candidate)
      }
      await notifyChanged()
      return status()
    } catch {
      try await record(error)
      throw error
    }
  }

  func nextChange() async throws -> [String: Any]? {
    if state?.migrationComplete != true { try await validateCurrentAccount() }
    let candidate = try requireEnabledState()
    guard let item = candidate.inbox.first else { return nil }
    let json: Any
    if let assetFile = item.assetFile {
      let data = try readAsset(assetFile)
      guard let value = String(data: data, encoding: .utf8) else {
        throw ChatCloudSyncError.persistence(
          "A pending chat sync snapshot is not valid UTF-8."
        )
      }
      json = value
    } else {
      json = NSNull()
    }
    return [
      "token": item.token,
      "id": item.id,
      "json": json,
      "deleted": item.deleted,
      "conflict": item.conflict,
      "source": item.source ?? (candidate.migrationComplete == true ? "current" : "v2"),
      "accountScope": Self.digest(Data((candidate.accountRecordName ?? "").utf8)),
    ]
  }

  func acknowledge(token: String) async throws {
    guard !token.isEmpty, token.utf8.count <= 512 else {
      throw ChatCloudSyncError.invalidArguments(
        "Acknowledgement token is invalid."
      )
    }
    var candidate = try requireEnabledState()
    guard let index = candidate.inbox.firstIndex(where: { $0.token == token })
    else {
      return
    }
    let file = candidate.inbox[index].assetFile
    candidate.inbox.remove(at: index)
    try commit(candidate)
    removeAssetIfUnreferenced(file)
    await notifyChanged()
  }

  private func resumeEngineForCurrentAccount() async throws {
    var candidate = try requireEnabledState()
    let account: CKRecord.ID
    do {
      account = try await availableAccountRecordID()
    } catch {
      candidate.error = error.localizedDescription
      try commit(candidate)
      let previousEngine = engine
      engine = nil
      await previousEngine?.cancelOperations()
      await notifyChanged()
      throw error
    }
    guard candidate.accountRecordName == account.recordName else {
      candidate.enabled = false
      candidate.error =
        "The iCloud account changed. Chat sync was disabled; local chats were kept. Enable sync explicitly for the current account."
      try commit(candidate)
      let previousEngine = engine
      engine = nil
      await previousEngine?.cancelOperations()
      await notifyChanged()
      throw ChatCloudSyncError.unavailable(candidate.error!)
    }
    startEngine()
  }

  private func availableAccountRecordID() async throws -> CKRecord.ID {
    let accountStatus = try await Self.container.accountStatus()
    guard accountStatus == .available else {
      let message = switch accountStatus {
      case .noAccount:
        "Sign in to iCloud before enabling chat sync."
      case .restricted:
        "This device restricts iCloud access."
      case .couldNotDetermine:
        "The iCloud account status could not be determined."
      case .temporarilyUnavailable:
        "iCloud is temporarily unavailable."
      case .available:
        ""
      @unknown default:
        "The iCloud account is unavailable."
      }
      throw ChatCloudSyncError.unavailable(message)
    }
    return try await Self.container.userRecordID()
  }

  private func startEngine() {
    guard engine == nil, let state, state.enabled, state.migrationComplete == true || state.adoptionComplete == true else { return }
    var configuration = CKSyncEngine.Configuration(
      database: Self.container.privateCloudDatabase,
      stateSerialization: state.engineState,
      delegate: self
    )
    configuration.automaticallySync = true
    configuration.subscriptionID = "MobileLlamaChatsV2"
    let syncEngine = CKSyncEngine(configuration)
    engine = syncEngine
    if state.engineState == nil {
      syncEngine.state.add(
        pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneName: Self.zoneName))]
      )
    }
    let dirtyRecords = state.chats.values
      .filter(\.dirty)
      .map { CKSyncEngine.PendingRecordZoneChange.saveRecord(Self.recordID($0.id)) }
    syncEngine.state.add(pendingRecordZoneChanges: dirtyRecords)
  }

  func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
    guard engine === syncEngine else { return }
    do {
      switch event {
      case .stateUpdate(let event):
        var candidate = try requireState()
        candidate.engineState = event.stateSerialization
        try commit(candidate)
      case .accountChange(let event):
        try await handleAccountChange(event, syncEngine: syncEngine)
      case .fetchedDatabaseChanges(let event):
        try await handleFetchedDatabaseChanges(event, syncEngine: syncEngine)
      case .fetchedRecordZoneChanges(let event):
        try await handleFetchedRecordZoneChanges(event, syncEngine: syncEngine)
      case .sentDatabaseChanges(let event):
        try await handleSentDatabaseChanges(event)
      case .sentRecordZoneChanges(let event):
        try await handleSentRecordZoneChanges(event, syncEngine: syncEngine)
      case .willFetchChanges, .willFetchRecordZoneChanges,
           .didFetchRecordZoneChanges, .didFetchChanges,
           .willSendChanges, .didSendChanges:
        break
      @unknown default:
        break
      }
    } catch {
      switch event {
      case .fetchedDatabaseChanges, .fetchedRecordZoneChanges:
        engine = nil
        Self.cancelOutsideDelegate(syncEngine)
      default:
        break
      }
      try? await record(error)
    }
  }

  func nextFetchChangesOptions(_ context: CKSyncEngine.FetchChangesContext, syncEngine: CKSyncEngine) async -> CKSyncEngine.FetchChangesOptions {
    var options = context.options
    options.scope = .zoneIDs([Self.zoneID])
    return options
  }

  func nextRecordZoneChangeBatch(
    _ context: CKSyncEngine.SendChangesContext,
    syncEngine: CKSyncEngine
  ) async -> CKSyncEngine.RecordZoneChangeBatch? {
    guard engine === syncEngine, state?.migrationComplete == true else { return nil }
    let changes = syncEngine.state.pendingRecordZoneChanges.filter {
      context.options.scope.contains($0)
    }
    guard !changes.isEmpty else { return nil }
    do {
      var candidate = try requireEnabledState()
      var records: [CKRecord] = []
      var removals: [CKSyncEngine.PendingRecordZoneChange] = []
      for change in changes {
        switch change {
        case .saveRecord(let recordID):
          guard var entry = candidate.chats[recordID.recordName], entry.dirty else {
            removals.append(change)
            continue
          }
          let record = try record(for: entry)
          if let assetFile = entry.assetFile {
            entry.inFlightAssets[entry.revision] = assetFile
            candidate.chats[entry.id] = entry
          }
          records.append(record)
        case .deleteRecord:
          removals.append(change)
        @unknown default:
          removals.append(change)
        }
      }
      try commit(candidate)
      syncEngine.state.remove(pendingRecordZoneChanges: removals)
      return CKSyncEngine.RecordZoneChangeBatch(recordsToSave: records)
    } catch {
      try? await record(error)
      return nil
    }
  }

  private func handleAccountChange(
    _ event: CKSyncEngine.Event.AccountChange,
    syncEngine: CKSyncEngine
  ) async throws {
    var candidate = try requireState()
    let recordName: String?
    switch event.changeType {
    case .signIn(let currentUser):
      recordName = currentUser.recordName
    case .signOut:
      recordName = nil
    case .switchAccounts(_, let currentUser):
      recordName = currentUser.recordName
    @unknown default:
      recordName = nil
    }
    guard recordName == candidate.accountRecordName else {
      candidate.enabled = false
      candidate.error =
        "The iCloud account changed. Chat sync was disabled; local chats were kept. Enable sync explicitly for the current account."
      try commit(candidate)
      engine = nil
      Self.cancelOutsideDelegate(syncEngine)
      await notifyChanged()
      return
    }
  }

  private func handleFetchedDatabaseChanges(
    _ event: CKSyncEngine.Event.FetchedDatabaseChanges,
    syncEngine: CKSyncEngine
  ) async throws {
    guard event.deletions.contains(where: { $0.zoneID == Self.zoneID }) else {
      return
    }
    var candidate = try requireState()
    candidate.enabled = false
    candidate.error =
      "The iCloud Chats zone was removed. Sync stopped before changing local chats. Enable sync after reconciling the account."
    try commit(candidate)
    engine = nil
    Self.cancelOutsideDelegate(syncEngine)
    await notifyChanged()
  }

  private func handleFetchedRecordZoneChanges(
    _ event: CKSyncEngine.Event.FetchedRecordZoneChanges,
    syncEngine: CKSyncEngine
  ) async throws {
    for modification in event.modifications {
      guard modification.record.recordID.zoneID == Self.zoneID else { continue }
      let value = try decode(modification.record)
      try await acceptServerValue(value, syncEngine: syncEngine)
    }
    for deletion in event.deletions {
      guard deletion.recordID.zoneID == Self.zoneID else { continue }
      try await acceptPhysicalDeletion(
        id: deletion.recordID.recordName,
        syncEngine: syncEngine
      )
    }
  }

  private func handleSentDatabaseChanges(
    _ event: CKSyncEngine.Event.SentDatabaseChanges
  ) async throws {
    if event.savedZones.contains(where: { $0.zoneID == Self.zoneID }) {
      var observed = try requireState(); observed.zoneObserved = true; observed.error = nil; try commit(observed)
    }
    guard let failed = event.failedZoneSaves.first(where: {
      $0.zone.zoneID == Self.zoneID
    }) else {
      return
    }
    var candidate = try requireState()
    candidate.error = Self.cloudMessage(failed.error)
    try commit(candidate)
    await notifyChanged()
  }

  private func handleSentRecordZoneChanges(
    _ event: CKSyncEngine.Event.SentRecordZoneChanges,
    syncEngine: CKSyncEngine
  ) async throws {
    var candidate = try requireState()
    var assetsToCheck = Set<String>()
    for savedRecord in event.savedRecords {
      let id = savedRecord.recordID.recordName
      guard let entry = candidate.chats[id] else { continue }
      let sentRevision = savedRecord["revision"] as? String
      let applied = ChatCloudSyncStateLogic.applyingSentAcknowledgement(
        revision: sentRevision,
        systemFields: try Self.systemFields(savedRecord),
        to: entry
      )
      if let asset = applied.releasedAsset {
        assetsToCheck.insert(asset)
      }
      candidate.chats[id] = applied.entry
    }
    try commit(candidate)

    for failure in event.failedRecordSaves {
      let id = failure.record.recordID.recordName
      switch failure.error.code {
      case .serverRecordChanged:
        do {
          let serverRecord = try await syncEngine.database.record(
            for: failure.record.recordID
          )
          let value = try decode(serverRecord)
          try await acceptServerValue(value, syncEngine: syncEngine)
        } catch {
          try await record(
            ChatCloudSyncError.cloud(
              "A conflicting server chat could not be downloaded: \(error.localizedDescription)"
            )
          )
        }
      case .zoneNotFound:
        if state?.zoneObserved == true {
          var stopped = try requireState(); stopped.enabled = false
          stopped.error = "The iCloud history zone was removed. Local chats were kept."
          try commit(stopped); engine = nil; Self.cancelOutsideDelegate(syncEngine)
        } else {
          syncEngine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneName: Self.zoneName))])
          syncEngine.state.add(pendingRecordZoneChanges: [.saveRecord(failure.record.recordID)])
        }
      case .unknownItem:
        // A server-deleted existing record must never be recreated under its
        // deleted identity. acceptPhysicalDeletion retains a dirty local copy.
        try await acceptPhysicalDeletion(id: id, syncEngine: syncEngine)
      case .networkFailure, .networkUnavailable, .zoneBusy,
           .serviceUnavailable, .notAuthenticated, .operationCancelled:
        var retry = try requireState()
        retry.error = Self.cloudMessage(failure.error)
        try commit(retry)
      default:
        var retry = try requireState()
        retry.error = Self.cloudMessage(failure.error)
        retry.chats[id]?.dirty = true
        try commit(retry)
        syncEngine.state.add(
          pendingRecordZoneChanges: [.saveRecord(failure.record.recordID)]
        )
      }
    }

    candidate = try requireState()
    for id in candidate.chats.keys {
      if candidate.chats[id]?.dirty == true {
        syncEngine.state.add(
          pendingRecordZoneChanges: [.saveRecord(Self.recordID(id))]
        )
      }
    }
    if event.failedRecordSaves.isEmpty {
      candidate.error = nil
      try commit(candidate)
    }
    for asset in assetsToCheck { removeAssetIfUnreferenced(asset) }
    await notifyChanged()
  }

  private func acceptServerValue(
    _ value: ChatCloudServerValue,
    syncEngine: CKSyncEngine
  ) async throws {
    var candidate = try requireEnabledState()
    let existing = candidate.chats[value.id]
    if let existing,
       existing.revision == value.revision,
       existing.digest == value.digest,
       existing.deleted == value.deleted {
      var acknowledged = existing
      acknowledged.systemFields = value.systemFields
      acknowledged.dirty = false
      candidate.chats[value.id] = acknowledged
      try commit(candidate)
      syncEngine.state.remove(
        pendingRecordZoneChanges: [.saveRecord(Self.recordID(value.id))]
      )
      await notifyChanged()
      return
    }

    if let existing, existing.dirty {
      ChatCloudSyncStateLogic.preserveConflict(
        entry: existing,
        serverRevision: value.revision,
        state: &candidate
      )
    }

    let serverFile = try value.data.map(writeAsset)
    candidate.chats[value.id] = ChatCloudSyncEntry(
      id: value.id,
      revision: value.revision,
      digest: value.digest,
      deleted: value.deleted,
      assetFile: serverFile,
      systemFields: value.systemFields,
      dirty: false
    )
    let ordinaryKey = "server:\(value.id):\(value.revision)"
    if !candidate.inbox.contains(where: { $0.dedupeKey == ordinaryKey }) {
      candidate.inbox.append(
        ChatCloudSyncInboxItem(
          token: UUID().uuidString,
          id: value.id,
          assetFile: serverFile,
          deleted: value.deleted,
          conflict: false,
          dedupeKey: ordinaryKey
        )
      )
    }
    try commit(candidate)
    syncEngine.state.remove(
      pendingRecordZoneChanges: [.saveRecord(Self.recordID(value.id))]
    )
    if let oldFile = existing?.assetFile { removeAssetIfUnreferenced(oldFile) }
    await notifyChanged()
  }

  private func acceptPhysicalDeletion(
    id: String,
    syncEngine: CKSyncEngine
  ) async throws {
    try Self.validateID(id)
    var candidate = try requireEnabledState()
    let existing = candidate.chats[id]
    if let existing, existing.dirty {
      ChatCloudSyncStateLogic.preserveConflict(
        entry: existing,
        serverRevision: "physical-deletion",
        state: &candidate
      )
    }
    let revision = "physical-" + UUID().uuidString
    candidate.chats[id] = ChatCloudSyncEntry(
      id: id,
      revision: revision,
      digest: Self.deletedDigest,
      deleted: true,
      assetFile: nil,
      systemFields: nil,
      dirty: false
    )
    let key = "physical:\(id)"
    if !candidate.inbox.contains(where: { $0.dedupeKey == key }) {
      candidate.inbox.append(
        ChatCloudSyncInboxItem(
          token: UUID().uuidString,
          id: id,
          assetFile: nil,
          deleted: true,
          conflict: false,
          dedupeKey: key
        )
      )
    }
    try commit(candidate)
    syncEngine.state.remove(
      pendingRecordZoneChanges: [.saveRecord(Self.recordID(id))]
    )
    if let oldFile = existing?.assetFile { removeAssetIfUnreferenced(oldFile) }
    await notifyChanged()
  }

  private func decode(_ record: CKRecord) throws -> ChatCloudServerValue {
    let isLegacy = record.recordID.zoneID.zoneName == "Chats"
    let expectedType = record.recordID.recordName.hasPrefix("folder:") && !isLegacy ? "Folder" : "Chat"
    guard record.recordType == expectedType else {
      throw ChatCloudSyncError.cloud("CloudKit returned an unexpected record type.")
    }
    guard
      let id = record[isLegacy ? "conversationID" : "entityID"] as? String,
      id == record.recordID.recordName
    else {
      throw ChatCloudSyncError.cloud("CloudKit returned an invalid chat identifier.")
    }
    try Self.validateID(id)
    guard let revision = record["revision"] as? String, !revision.isEmpty else {
      throw ChatCloudSyncError.cloud("CloudKit returned a chat without a revision.")
    }
    let deleted = (record["deleted"] as? NSNumber)?.boolValue ?? false
    let data: Data?
    let digest: String
    if deleted {
      data = nil
      digest = Self.deletedDigest
    } else {
      guard
        let asset = record["payload"] as? CKAsset,
        let fileURL = asset.fileURL
      else {
        throw ChatCloudSyncError.cloud(
          "CloudKit returned a chat without its snapshot."
        )
      }
      let value = try Self.readBounded(fileURL)
      guard String(data: value, encoding: .utf8) != nil else {
        throw ChatCloudSyncError.cloud(
          "CloudKit returned a chat snapshot that is not valid UTF-8."
        )
      }
      data = value
      digest = Self.digest(value)
    }
    return ChatCloudServerValue(
      id: id,
      revision: revision,
      digest: digest,
      deleted: deleted,
      data: data,
      systemFields: try Self.systemFields(record)
    )
  }

  private func record(for entry: ChatCloudSyncEntry) throws -> CKRecord {
    let record: CKRecord
    if let systemFields = entry.systemFields {
      record = try Self.record(from: systemFields)
    } else {
      record = CKRecord(
        recordType: entry.id.hasPrefix("folder:") ? "Folder" : "Chat",
        recordID: Self.recordID(entry.id)
      )
    }
    record["entityID"] = entry.id as CKRecordValue
    record["revision"] = entry.revision as CKRecordValue
    record["deleted"] = NSNumber(value: entry.deleted)
    if entry.deleted {
      record["payload"] = nil
    } else {
      guard let assetFile = entry.assetFile else {
        throw ChatCloudSyncError.persistence(
          "A pending chat snapshot file is missing."
        )
      }
      let url = assetURL(assetFile)
      guard FileManager.default.fileExists(atPath: url.path) else {
        throw ChatCloudSyncError.persistence(
          "A pending chat snapshot file is missing."
        )
      }
      record["payload"] = CKAsset(fileURL: url)
    }
    return record
  }

  private func requireState() throws -> ChatCloudSyncState {
    guard let state else {
      throw ChatCloudSyncError.persistence(
        loadError ?? "Chat sync state is unavailable."
      )
    }
    return state
  }

  private func requireEnabledState() throws -> ChatCloudSyncState {
    let state = try requireState()
    guard state.enabled else {
      throw ChatCloudSyncError.unavailable("Enable chat sync first.")
    }
    return state
  }

  private func commit(_ candidate: ChatCloudSyncState) throws {
    try Self.write(candidate, to: stateURL)
    state = candidate
  }

  private static func write(_ state: ChatCloudSyncState, to url: URL) throws {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode(state)
    try data.write(to: url, options: .atomic)
  }

  private func record(_ error: Error) async throws {
    runtimeError = error.localizedDescription
    if var candidate = state {
      candidate.error = error.localizedDescription
      try commit(candidate)
    }
    await notifyChanged()
  }

  private func writeAsset(_ data: Data) throws -> String {
    guard data.count <= Self.maxSnapshotBytes else {
      throw ChatCloudSyncError.persistence(
        "A chat sync snapshot exceeds 128 MiB."
      )
    }
    let name = UUID().uuidString + ".json"
    try data.write(to: assetURL(name), options: [.atomic, .completeFileProtection])
    return name
  }

  private func readAsset(_ name: String) throws -> Data {
    guard Self.validAssetName(name) else {
      throw ChatCloudSyncError.persistence(
        "A chat sync snapshot path is invalid."
      )
    }
    return try Self.readBounded(assetURL(name))
  }

  private func assetURL(_ name: String) -> URL {
    assetsDirectory.appendingPathComponent(name, isDirectory: false)
  }

  private func removeAssetIfUnreferenced(_ name: String?) {
    guard let name, !referencedAssets().contains(name) else { return }
    try? FileManager.default.removeItem(at: assetURL(name))
  }

  private func referencedAssets() -> Set<String> {
    guard let state else { return [] }
    var values = Set(state.chats.values.compactMap(\.assetFile))
    for entry in state.chats.values {
      values.formUnion(entry.inFlightAssets.values)
    }
    values.formUnion(state.inbox.compactMap(\.assetFile))
    values.formUnion(state.quarantinedInbox.compactMap(\.assetFile))
    return values
  }

  private static func cleanupUnreferencedAssets(
    state: ChatCloudSyncState,
    assetsDirectory: URL
  ) {
    var referenced = Set(state.chats.values.compactMap(\.assetFile))
    referenced.formUnion(state.inbox.compactMap(\.assetFile))
    referenced.formUnion(state.quarantinedInbox.compactMap(\.assetFile))
    guard let files = try? FileManager.default.contentsOfDirectory(
      at: assetsDirectory,
      includingPropertiesForKeys: nil
    ) else {
      return
    }
    for file in files where !referenced.contains(file.lastPathComponent) {
      try? FileManager.default.removeItem(at: file)
    }
  }

  private static func validateID(_ id: String) throws {
    guard
      !id.isEmpty,
      id == id.trimmingCharacters(in: .whitespacesAndNewlines),
      id.utf8.count <= maxIDBytes,
      !id.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    else {
      throw ChatCloudSyncError.invalidArguments(
        "Chat IDs must be non-empty and no more than 512 bytes."
      )
    }
  }

  private static func validAssetName(_ value: String) -> Bool {
    value.count == 41
      && value.hasSuffix(".json")
      && UUID(uuidString: String(value.dropLast(5))) != nil
  }

  private static func readBounded(_ url: URL) throws -> Data {
    let values = try url.resourceValues(forKeys: [.fileSizeKey])
    if let size = values.fileSize, size > maxSnapshotBytes {
      throw ChatCloudSyncError.cloud(
        "A chat sync snapshot exceeds 128 MiB."
      )
    }
    let data = try Data(contentsOf: url)
    guard data.count <= maxSnapshotBytes else {
      throw ChatCloudSyncError.cloud(
        "A chat sync snapshot exceeds 128 MiB."
      )
    }
    return data
  }

  private static func digest(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  private static let deletedDigest = "deleted"
  private static var zoneID: CKRecordZone.ID {
    CKRecordZone.ID(zoneName: zoneName)
  }

  private static func recordID(_ id: String) -> CKRecord.ID {
    CKRecord.ID(recordName: id, zoneID: zoneID)
  }

  private static func systemFields(_ record: CKRecord) throws -> Data {
    let archiver = NSKeyedArchiver(requiringSecureCoding: true)
    record.encodeSystemFields(with: archiver)
    archiver.finishEncoding()
    return archiver.encodedData
  }

  private static func record(from data: Data) throws -> CKRecord {
    let unarchiver = try NSKeyedUnarchiver(forReadingFrom: data)
    unarchiver.requiresSecureCoding = true
    defer { unarchiver.finishDecoding() }
    guard let record = CKRecord(coder: unarchiver) else {
      throw ChatCloudSyncError.persistence(
        "Stored CloudKit record fields are invalid."
      )
    }
    return record
  }

  private static func cloudMessage(_ error: CKError) -> String {
    switch error.code {
    case .notAuthenticated:
      "Sign in to iCloud to continue chat sync."
    case .networkFailure, .networkUnavailable:
      "Chat sync is waiting for a network connection."
    case .quotaExceeded:
      "The iCloud storage quota is full."
    case .zoneNotFound:
      "The iCloud Chats zone is unavailable."
    case .serviceUnavailable, .zoneBusy:
      "iCloud is temporarily unavailable."
    default:
      "iCloud could not sync a chat: \(error.localizedDescription)"
    }
  }

  private nonisolated static func cancelOutsideDelegate(
    _ syncEngine: CKSyncEngine
  ) {
    Task.detached(priority: .utility) {
      await syncEngine.cancelOperations()
    }
  }
}
