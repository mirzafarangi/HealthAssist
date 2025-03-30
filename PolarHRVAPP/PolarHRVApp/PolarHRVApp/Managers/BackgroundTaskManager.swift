// BackgroundTaskManager.swift

import Foundation
import UIKit
import os.log

class BackgroundTaskManager {
    private let logger = Logger(subsystem: "com.hrvmetrics.polarh10", category: "BackgroundTaskManager")
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var isBackgroundTaskRunning = false
    private var backgroundTimer: Timer?
    private var heartbeatTimer: Timer?
    
    // App background state tracking
    private var lastBackgroundEntryTime: Date?
    private var isAppInBackground = false
    
    // Track the tasks to ensure they keep running
    private var registeredTasks: [String: () -> Void] = [:]
    
    // Timing constants
    private let refreshInterval: TimeInterval = 60.0
    private let heartbeatInterval: TimeInterval = 15.0
    
    // Singleton pattern
    static let shared = BackgroundTaskManager()
    
    private init() {
        // Set up notification observers for app state changes
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAppBackgrounding),
            name: UIApplication.didEnterBackgroundNotification,
            object: nil
        )
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAppForegrounding),
            name: UIApplication.willEnterForegroundNotification,
            object: nil
        )
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
        stopAllTimers()
    }
    
    @objc private func handleAppBackgrounding() {
        // App is going to background - make sure tasks keep running
        logger.info("App entering background - ensuring background tasks continue")
        isAppInBackground = true
        lastBackgroundEntryTime = Date()
        
        // Start the heartbeat timer for more frequent check-ins
        startHeartbeatTimer()
        
        refreshBackgroundTask()
    }
    
    @objc private func handleAppForegrounding() {
        // App is coming to foreground
        logger.info("App entering foreground")
        isAppInBackground = false
        
        // Stop the heartbeat timer when in foreground
        stopHeartbeatTimer()
        
        // Calculate how long the app was in background
        if let entryTime = lastBackgroundEntryTime {
            let backgroundDuration = Date().timeIntervalSince(entryTime)
            logger.info("App was in background for \(Int(backgroundDuration)) seconds")
        }
    }
    
    func beginBackgroundTask(withName name: String, task: (() -> Void)? = nil) {
        if let task = task {
            registeredTasks[name] = task
        }
        
        guard !isBackgroundTaskRunning else {
            logger.info("Background task already running")
            return
        }
        
        logger.info("Beginning background task: \(name)")
        
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
            self?.endBackgroundTask()
        }
        
        isBackgroundTaskRunning = true
        
        if backgroundTask == .invalid {
            logger.error("Failed to start background task")
            isBackgroundTaskRunning = false
            return
        }
        
        // Start timer to periodically refresh the background task
        startBackgroundTaskRefreshTimer()
    }
    
    func endBackgroundTask() {
        guard isBackgroundTaskRunning && backgroundTask != .invalid else {
            return
        }
        
        logger.info("Ending background task")
        stopAllTimers()
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
        isBackgroundTaskRunning = false
    }
    
    private func stopAllTimers() {
        backgroundTimer?.invalidate()
        backgroundTimer = nil
        
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
    }
    
    private func startBackgroundTaskRefreshTimer() {
        // Cancel any existing timer
        backgroundTimer?.invalidate()
        
        // Create a timer that will periodically refresh the background task
        backgroundTimer = Timer.scheduledTimer(withTimeInterval: refreshInterval, repeats: true) { [weak self] _ in
            self?.refreshBackgroundTask()
        }
        
        if let timer = backgroundTimer {
            RunLoop.current.add(timer, forMode: .common)
        }
    }
    
    private func startHeartbeatTimer() {
        // Cancel any existing timer
        heartbeatTimer?.invalidate()
        
        // Create a faster heartbeat timer for background mode
        heartbeatTimer = Timer.scheduledTimer(withTimeInterval: heartbeatInterval, repeats: true) { [weak self] _ in
            self?.performHeartbeat()
        }
        
        if let timer = heartbeatTimer {
            RunLoop.current.add(timer, forMode: .common)
        }
        
        logger.info("Background heartbeat timer started")
    }
    
    private func stopHeartbeatTimer() {
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
        logger.info("Background heartbeat timer stopped")
    }
    
    private func performHeartbeat() {
        guard isAppInBackground else { return }
        
        logger.info("Background heartbeat - keeping connection alive")
        
        // Refresh the background task to prevent expiration
        refreshBackgroundTask()
        
        // Execute heartbeat-specific tasks if needed
        for (name, task) in registeredTasks {
            if name.contains("Heartbeat") {
                logger.info("Executing heartbeat task: \(name)")
                task()
            }
        }
    }
    
    private func refreshBackgroundTask() {
        // End the current background task and start a new one
        if isBackgroundTaskRunning && backgroundTask != .invalid {
            let oldTask = backgroundTask
            
            // Start a new task before ending the old one
            backgroundTask = UIApplication.shared.beginBackgroundTask { [weak self] in
                self?.endBackgroundTask()
            }
            
            // End the old task
            UIApplication.shared.endBackgroundTask(oldTask)
            
            if backgroundTask == .invalid {
                logger.error("Failed to refresh background task")
                isBackgroundTaskRunning = false
                
                // Try to restart after a short delay if still in background
                if isAppInBackground {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                        self?.beginBackgroundTask(withName: "RecoveryTask")
                    }
                }
            } else {
                logger.info("Background task refreshed successfully")
                
                // Execute any registered tasks
                for (name, task) in registeredTasks {
                    if !name.contains("Heartbeat") || isAppInBackground {
                        logger.info("Executing registered background task: \(name)")
                        task()
                    }
                }
            }
        }
    }
    
    // Register a periodic task that will be executed in the background
    func registerPeriodicTask(name: String, task: @escaping () -> Void) {
        registeredTasks[name] = task
        logger.info("Registered periodic task: \(name)")
    }
    
    // Register a heartbeat task that runs more frequently in background
    func registerHeartbeatTask(name: String, task: @escaping () -> Void) {
        let heartbeatName = "Heartbeat_\(name)"
        registeredTasks[heartbeatName] = task
        logger.info("Registered heartbeat task: \(heartbeatName)")
    }
    
    // Unregister a task
    func unregisterTask(name: String) {
        registeredTasks.removeValue(forKey: name)
        logger.info("Unregistered task: \(name)")
    }
}
