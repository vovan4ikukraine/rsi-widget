import Flutter
import UIKit
import FirebaseCore
import WidgetKit

@main
@objc class AppDelegate: FlutterAppDelegate {
  private let CHANNEL = "com.example.rsi_widget/widget"
  private let APP_GROUP_ID = "group.com.example.rsi_widget"
  
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    // Initialize Firebase
    FirebaseApp.configure()
    
    // Setup method channel for widget updates
    guard let controller = window?.rootViewController as? FlutterViewController else {
      GeneratedPluginRegistrant.register(with: self)
      return super.application(application, didFinishLaunchingWithOptions: launchOptions)
    }
    
    let channel = FlutterMethodChannel(name: CHANNEL, binaryMessenger: controller.binaryMessenger)
    
    channel.setMethodCallHandler { [weak self] (call: FlutterMethodCall, result: @escaping FlutterResult) in
      guard let self = self else {
        result(FlutterMethodNotImplemented)
        return
      }
      
      switch call.method {
      case "saveToAppGroup":
        self.saveToAppGroup(call: call, result: result)
      case "reloadWidgetTimeline":
        self.reloadWidgetTimeline(result: result)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    
    GeneratedPluginRegistrant.register(with: self)
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }
  
  private func saveToAppGroup(call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard let args = call.arguments as? [String: Any],
          let sharedDefaults = UserDefaults(suiteName: APP_GROUP_ID) else {
      result(FlutterError(code: "ERROR", message: "Failed to access App Group", details: nil))
      return
    }
    
    if let watchlistData = args["watchlistData"] as? String {
      sharedDefaults.set(watchlistData, forKey: "watchlist_data")
    }
    
    if let timeframe = args["timeframe"] as? String {
      sharedDefaults.set(timeframe, forKey: "timeframe")
    }
    
    if let rsiPeriod = args["rsiPeriod"] as? Int {
      sharedDefaults.set(rsiPeriod, forKey: "rsi_widget_period")
      sharedDefaults.set(rsiPeriod, forKey: "rsi_period")
    }
    
    if let indicator = args["indicator"] as? String {
      sharedDefaults.set(indicator, forKey: "widget_indicator")
    }
    
    if let indicatorParams = args["indicatorParams"] as? String {
      sharedDefaults.set(indicatorParams, forKey: "widget_indicator_params")
    } else {
      sharedDefaults.removeObject(forKey: "widget_indicator_params")
    }
    
    if let watchlistSymbols = args["watchlistSymbols"] as? [String] {
      if let symbolsData = try? JSONSerialization.data(withJSONObject: watchlistSymbols),
         let symbolsString = String(data: symbolsData, encoding: .utf8) {
        sharedDefaults.set(symbolsString, forKey: "watchlist_symbols")
      }
    }
    
    sharedDefaults.synchronize()
    result(true)
  }
  
  private func reloadWidgetTimeline(result: @escaping FlutterResult) {
    WidgetCenter.shared.reloadTimelines(ofKind: "RSIWidget")
    result(true)
  }
}
