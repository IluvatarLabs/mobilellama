import Flutter
import Network
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private var chatCloudSyncBridge: ChatCloudSyncBridge?
  private var chatBackgroundExecutionBridge: ChatBackgroundExecutionBridge?
  private var localNetworkChannel: FlutterMethodChannel?
  private var localNetworkProbe: LocalNetworkProbe?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)

    let messenger = engineBridge.applicationRegistrar.messenger()
    chatCloudSyncBridge = ChatCloudSyncBridge(
      application: UIApplication.shared,
      messenger: messenger
    )
    chatBackgroundExecutionBridge = ChatBackgroundExecutionBridge(
      application: UIApplication.shared,
      messenger: messenger
    )

    let channel = FlutterMethodChannel(
      name: "app.mobollama/local_network",
      binaryMessenger: messenger
    )
    channel.setMethodCallHandler { [weak self] call, result in
      guard call.method == "prepare" else {
        result(FlutterMethodNotImplemented)
        return
      }
      guard let self else {
        result(
          FlutterError(
            code: "local_network_unavailable",
            message: "Local network preparation is unavailable.",
            details: nil
          )
        )
        return
      }
      self.prepareLocalNetwork(call: call, result: result)
    }
    localNetworkChannel = channel
  }

  private func prepareLocalNetwork(call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard localNetworkProbe == nil else {
      result(
        FlutterError(
          code: "local_network_busy",
          message: "Local network preparation is already in progress.",
          details: nil
        )
      )
      return
    }
    guard
      let arguments = call.arguments as? [String: Any],
      let hostValue = arguments["host"] as? String,
      let portValue = arguments["port"] as? Int
    else {
      result(
        FlutterError(
          code: "invalid_arguments",
          message: "Expected a host string and port integer.",
          details: nil
        )
      )
      return
    }

    let host = hostValue.trimmingCharacters(in: .whitespacesAndNewlines)
    guard
      !host.isEmpty,
      host == hostValue,
      (1...65_535).contains(portValue),
      let port = NWEndpoint.Port(rawValue: UInt16(portValue))
    else {
      result(
        FlutterError(
          code: "invalid_arguments",
          message: "Host must be non-empty and port must be between 1 and 65535.",
          details: nil
        )
      )
      return
    }

#if targetEnvironment(simulator)
    result(nil)
    return
#endif

    let probe = LocalNetworkProbe(host: NWEndpoint.Host(host), port: port) {
      [weak self] outcome in
      DispatchQueue.main.async {
        self?.localNetworkProbe = nil
        switch outcome {
        case .ready:
          result(nil)
        case .failed(let code, let message):
          result(FlutterError(code: code, message: message, details: nil))
        }
      }
    }
    localNetworkProbe = probe
    probe.start()
  }
}

private enum LocalNetworkProbeOutcome {
  case ready
  case failed(code: String, message: String)
}

private final class LocalNetworkProbe {
  init(
    host: NWEndpoint.Host,
    port: NWEndpoint.Port,
    completion: @escaping (LocalNetworkProbeOutcome) -> Void
  ) {
    connection = NWConnection(host: host, port: port, using: .tcp)
    self.completion = completion
  }

  private let queue = DispatchQueue(label: "app.mobollama.local-network")
  private var connection: NWConnection?
  private var timeoutWorkItem: DispatchWorkItem?
  private var completion: ((LocalNetworkProbeOutcome) -> Void)?
  private var finished = false

  func start() {
    guard let connection else { return }
    connection.stateUpdateHandler = { [weak self] state in
      self?.handle(state)
    }
    connection.start(queue: queue)

    let timeoutWorkItem = DispatchWorkItem { [weak self] in
      self?.finish(
        .failed(
          code: "local_network_timeout",
          message: "Local network preparation timed out."
        )
      )
    }
    self.timeoutWorkItem = timeoutWorkItem
    queue.asyncAfter(deadline: .now() + 10, execute: timeoutWorkItem)
  }

  private func handle(_ state: NWConnection.State) {
    switch state {
    case .ready:
      finish(.ready)
    case .failed(let error):
      finish(
        .failed(
          code: "local_network_failed",
          message: "Local network preparation failed: \(error.localizedDescription)"
        )
      )
    case .cancelled:
      finish(
        .failed(
          code: "local_network_cancelled",
          message: "Local network preparation was cancelled."
        )
      )
    case .setup, .preparing, .waiting:
      break
    @unknown default:
      break
    }
  }

  private func finish(_ outcome: LocalNetworkProbeOutcome) {
    guard !finished else { return }
    finished = true
    timeoutWorkItem?.cancel()
    timeoutWorkItem = nil
    connection?.stateUpdateHandler = nil
    connection?.cancel()
    connection = nil
    let completion = completion
    self.completion = nil
    completion?(outcome)
  }
}
