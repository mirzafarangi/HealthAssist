// PolarHRVApp.swift

import SwiftUI

// Create a centralized coordinator class to hold our shared instances
final class AppCoordinator {
    // Singleton pattern for app-wide access
    static let shared = AppCoordinator()
    
    // Create our manager instances
    let userManager = UserManager()
    let bluetoothManager = BluetoothManager()
    lazy var recordingManager = RecordingManager(
        userManager: userManager,
        bluetoothManager: bluetoothManager
    )
    
    private init() {
        // Register background tasks
        setupBackgroundTasks()
    }
    
    private func setupBackgroundTasks() {
        BackgroundTaskManager.shared.registerPeriodicTask(name: "BluetoothConnection") {
            if self.bluetoothManager.connectionState == .connected {
                print("Background task: Maintaining Bluetooth connection")
            }
        }
        
        BackgroundTaskManager.shared.registerPeriodicTask(name: "DataSync") {
            print("Background task: Syncing buffered data")
            if DataBufferService.shared.hasBufferedSessions() {
                self.recordingManager.syncBufferedSessions()
            }
        }
        
        BackgroundTaskManager.shared.registerHeartbeatTask(name: "ConnectionMonitor") {
            if self.recordingManager.isAutoRecording {
                print("Heartbeat: Monitoring connection for auto-recording")
                
                if self.bluetoothManager.connectionState != .connected &&
                   !self.recordingManager.isRecoveryMode {
                    print("Heartbeat detected disconnection, enabling recovery")
                    NotificationCenter.default.post(name: .bluetoothDisconnected, object: nil)
                }
            }
        }
    }
}

@main
struct PolarHRVApp: App {
    // Use StateObjects to track the shared instances
    @StateObject private var userManager = AppCoordinator.shared.userManager
    @StateObject private var bluetoothManager = AppCoordinator.shared.bluetoothManager
    @StateObject private var recordingManager = AppCoordinator.shared.recordingManager
    
    var body: some Scene {
        WindowGroup {
            ContentView(
                userManager: userManager,
                bluetoothManager: bluetoothManager,
                recordingManager: recordingManager
            )
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
                // Refresh session count when app returns to foreground
                recordingManager.fetchSessionCount()
                
                // Try to sync any buffered sessions
                if DataBufferService.shared.hasBufferedSessions() {
                    recordingManager.syncBufferedSessions()
                }
            }
        }
    }
}
