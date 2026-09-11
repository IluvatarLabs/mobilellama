import Foundation
import XCTest
@testable import Runner

@available(iOS 17.0, *)
final class ChatCloudSyncStateTests: XCTestCase {
  func testDirtyLocalSnapshotIsPreservedOnceWhenServerRevisionDiffers() {
    var state = ChatCloudSyncState()
    let local = entry(
      revision: "local-revision",
      digest: "local-digest",
      assetFile: "00000000-0000-0000-0000-000000000001.json",
      dirty: true
    )

    XCTAssertTrue(
      ChatCloudSyncStateLogic.preserveConflict(
        entry: local,
        serverRevision: "server-revision",
        state: &state,
        token: "receipt-1",
        conflictID: "conflict-copy-1"
      )
    )
    XCTAssertFalse(
      ChatCloudSyncStateLogic.preserveConflict(
        entry: local,
        serverRevision: "server-revision",
        state: &state,
        token: "receipt-2",
        conflictID: "conflict-copy-2"
      )
    )

    XCTAssertEqual(state.inbox.count, 1)
    XCTAssertEqual(state.inbox[0].token, "receipt-1")
    XCTAssertEqual(state.inbox[0].id, "conflict-copy-1")
    XCTAssertEqual(state.inbox[0].assetFile, local.assetFile)
    XCTAssertTrue(state.inbox[0].conflict)
  }

  func testOlderSentAcknowledgementDoesNotClearNewerDirtyRevision() {
    let current = entry(
      revision: "newer-revision",
      digest: "newer-digest",
      assetFile: "00000000-0000-0000-0000-000000000002.json",
      dirty: true,
      inFlightAssets: [
        "older-revision": "00000000-0000-0000-0000-000000000003.json"
      ]
    )

    let applied = ChatCloudSyncStateLogic.applyingSentAcknowledgement(
      revision: "older-revision",
      systemFields: Data([1, 2, 3]),
      to: current
    )

    XCTAssertEqual(applied.entry.revision, "newer-revision")
    XCTAssertTrue(applied.entry.dirty)
    XCTAssertEqual(applied.entry.systemFields, Data([1, 2, 3]))
    XCTAssertTrue(applied.entry.inFlightAssets.isEmpty)
    XCTAssertEqual(
      applied.releasedAsset,
      "00000000-0000-0000-0000-000000000003.json"
    )
  }

  func testLocalPutDuringUnacknowledgedOrdinaryChangeBecomesConflictCopy() {
    var state = ChatCloudSyncState()
    state.chats["chat-1"] = entry(
      revision: "server-revision",
      digest: "server-digest",
      assetFile: "00000000-0000-0000-0000-000000000004.json",
      dirty: false
    )
    state.inbox = [
      ChatCloudSyncInboxItem(
        token: "server-receipt",
        id: "chat-1",
        assetFile: "00000000-0000-0000-0000-000000000004.json",
        deleted: false,
        conflict: false,
        dedupeKey: "server:chat-1:server-revision"
      )
    ]

    XCTAssertEqual(
      ChatCloudSyncStateLogic.localPutDecision(
        id: "chat-1",
        digest: "local-edit-digest",
        deleted: false,
        state: state
      ),
      .preserveConflict(
        dedupeKey: "pending:chat-1:false:local-edit-digest"
      )
    )
  }

  func testAccountSwitchQuarantinesInboxAndRequiresUnchangedChatWrite() {
    var state = ChatCloudSyncState()
    state.accountRecordName = "old-account"
    state.chats["chat-1"] = entry(
      revision: "old-account-revision",
      digest: "unchanged-digest",
      assetFile: "00000000-0000-0000-0000-000000000005.json",
      dirty: false
    )
    state.inbox = [
      ChatCloudSyncInboxItem(
        token: "old-account-receipt",
        id: "chat-2",
        assetFile: "00000000-0000-0000-0000-000000000006.json",
        deleted: false,
        conflict: false,
        dedupeKey: "server:chat-2:remote-revision"
      )
    ]

    XCTAssertTrue(
      ChatCloudSyncStateLogic.prepareForAccount(
        "new-account",
        state: &state
      )
    )

    XCTAssertEqual(state.accountRecordName, "new-account")
    XCTAssertTrue(state.chats.isEmpty)
    XCTAssertTrue(state.inbox.isEmpty)
    XCTAssertEqual(state.quarantinedInbox.map(\.token), ["old-account-receipt"])
    XCTAssertEqual(
      ChatCloudSyncStateLogic.localPutDecision(
        id: "chat-1",
        digest: "unchanged-digest",
        deleted: false,
        state: state
      ),
      .write
    )
  }

  private func entry(
    revision: String,
    digest: String,
    assetFile: String?,
    dirty: Bool,
    inFlightAssets: [String: String] = [:]
  ) -> ChatCloudSyncEntry {
    ChatCloudSyncEntry(
      id: "chat-1",
      revision: revision,
      digest: digest,
      deleted: false,
      assetFile: assetFile,
      systemFields: nil,
      dirty: dirty,
      inFlightAssets: inFlightAssets
    )
  }
}
