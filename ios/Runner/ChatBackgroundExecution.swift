import Flutter
import UIKit

/// Owns one finite UIKit background task for each active chat run.
final class ChatBackgroundExecutionBridge {
  init(application: UIApplication, messenger: FlutterBinaryMessenger) {
    self.application = application
    channel = FlutterMethodChannel(
      name: "app.mobollama/chat_background_execution",
      binaryMessenger: messenger
    )
    channel.setMethodCallHandler { [weak self] call, result in
      self?.handle(call: call, result: result)
    }
  }

  deinit {
    channel.setMethodCallHandler(nil)
    endAll()
  }

  private final class Lease {
    var identifier: UIBackgroundTaskIdentifier = .invalid
  }

  private let application: UIApplication
  private let channel: FlutterMethodChannel
  private var leases: [String: Lease] = [:]

  private func handle(call: FlutterMethodCall, result: @escaping FlutterResult) {
    dispatchPrecondition(condition: .onQueue(.main))
    switch call.method {
    case "begin":
      guard let runID = validatedRunID(call.arguments) else {
        result(
          FlutterError(
            code: "invalid_arguments",
            message: "Expected a non-empty runId of at most 256 characters.",
            details: nil
          )
        )
        return
      }
      begin(runID: runID, result: result)
    case "end":
      guard let runID = validatedRunID(call.arguments) else {
        result(
          FlutterError(
            code: "invalid_arguments",
            message: "Expected a non-empty runId of at most 256 characters.",
            details: nil
          )
        )
        return
      }
      end(runID: runID)
      result(nil)
    case "dispose":
      endAll()
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func begin(runID: String, result: @escaping FlutterResult) {
    guard leases[runID] == nil else {
      result(
        FlutterError(
          code: "duplicate_run",
          message: "Background execution already began for this chat run.",
          details: nil
        )
      )
      return
    }

    let lease = Lease()
    let identifier = application.beginBackgroundTask(withName: "Chat response") {
      [weak self, weak lease] in
      guard let self, let lease else { return }
      self.expire(runID: runID, lease: lease)
    }
    guard identifier != .invalid else {
      result(
        FlutterError(
          code: "background_unavailable",
          message: "iOS did not grant background execution time.",
          details: nil
        )
      )
      return
    }

    lease.identifier = identifier
    leases[runID] = lease
    result(nil)
  }

  private func expire(runID: String, lease: Lease) {
    dispatchPrecondition(condition: .onQueue(.main))
    guard leases[runID] === lease else { return }
    leases.removeValue(forKey: runID)
    end(lease: lease)
    channel.invokeMethod("expired", arguments: ["runId": runID])
  }

  private func end(runID: String) {
    guard let lease = leases.removeValue(forKey: runID) else { return }
    end(lease: lease)
  }

  private func endAll() {
    let current = Array(leases.values)
    leases.removeAll()
    for lease in current {
      end(lease: lease)
    }
  }

  private func end(lease: Lease) {
    guard lease.identifier != .invalid else { return }
    application.endBackgroundTask(lease.identifier)
    lease.identifier = .invalid
  }

  private func validatedRunID(_ arguments: Any?) -> String? {
    guard
      let values = arguments as? [String: Any],
      let runID = values["runId"] as? String,
      !runID.isEmpty,
      runID == runID.trimmingCharacters(in: .whitespacesAndNewlines),
      runID.count <= 256
    else {
      return nil
    }
    return runID
  }
}
