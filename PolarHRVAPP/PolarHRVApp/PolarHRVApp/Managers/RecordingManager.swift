// RecordingManager.swift

import Foundation
import Combine
import os.log

class RecordingManager: ObservableObject {
    private let logger = Logger(subsystem: "com.hrvmetrics.polarh10", category: "RecordingManager")
    private var cancellables = Set<AnyCancellable>()
    private let userManager: UserManager
    private let bluetoothManager: BluetoothManager
    
    // Session settings
    @Published var intervalBetweenRecordings: Int = 2 // N: minutes between recordings (default: 2 minutes)
    @Published var recordingDuration: Int = 3 // M: minutes per recording (default: 3 minutes)
    @Published var selectedTag: String = "Active" // Default tag
    
    // Available tags as per API requirements
    let availableTags = [
        "Sleep", "Rest", "Active", "Engaged", "Experiment"
    ]
    
    // Recording state
    @Published var isRecording: Bool = false
    @Published var isAutoRecording: Bool = false
    @Published var recordingSecondsLeft: Int = 0
    @Published var timeUntilNextRecording: Int = 0
    @Published var recordingMessage: String = ""
    @Published var errorMessage: String? = nil
    @Published var sessionCount: Int = 0
    @Published var isRefreshingCount: Bool = false
    
    // Recovery and buffer features
    @Published var isRecoveryMode: Bool = false
    @Published var bufferedSessionCount: Int = 0
    private var reconnectionTimer: Timer?
    private var syncTimer: Timer?
    private var lastActiveTag: String = "Active" // Store the last used tag
    
    // Timers
    private var recordingTimer: Timer?
    private var autoRecordingTimer: Timer?
    private var intervalTimer: Timer?
    
    // Current RR intervals collection
    private var currentRRIntervals: [Int] = []
    
    init(userManager: UserManager, bluetoothManager: BluetoothManager) {
        self.userManager = userManager
        self.bluetoothManager = bluetoothManager
        
        // Fetch session count on initialization
        fetchSessionCount()
        
        // Setup observation for Bluetooth events
        setupNotificationObservers()
        
        // Check for buffered sessions
        updateBufferedSessionCount()
        
        // Start a periodic sync timer
        startSyncTimer()
    }
    
    // MARK: - Notification Observers
    
    private func setupNotificationObservers() {
        // Register for Bluetooth disconnection notifications
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleBluetoothDisconnection),
            name: .bluetoothDisconnected,
            object: nil
        )
        
        // Register for Bluetooth reconnection notifications
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleBluetoothReconnection),
            name: .bluetoothReconnected,
            object: nil
        )
        
        // Register for Bluetooth reconnection failure notifications
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleReconnectFailure),
            name: .bluetoothReconnectFailed,
            object: nil
        )
        
        // Register for data buffer ready notifications
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleDataBufferReady),
            name: .dataBufferReady,
            object: nil
        )
    }
    
    @objc private func handleBluetoothDisconnection() {
        logger.warning("Bluetooth disconnected while recording active: \(self.isRecording || self.isAutoRecording)")
        
        // If we were recording, we need to take action
        if isRecording || isAutoRecording {
            // Save the last active tag
            lastActiveTag = selectedTag
            
            // If in middle of recording, save what we have
            if isRecording && !currentRRIntervals.isEmpty {
                logger.info("Saving partial recording data before disconnect")
                finishRecording(saveToBuffer: true)
            }
            
            // Enter recovery mode
            isRecoveryMode = true
            recordingMessage = "Connection lost. Attempting to recover..."
            
            // Enable auto reconnect
            bluetoothManager.enableAutoReconnect()
            
            // Start recovery timer that periodically checks if we're reconnected
            startReconnectionTimer()
        }
    }
    
    @objc private func handleBluetoothReconnection() {
        // If we're in recovery mode, resume recording
        if isRecoveryMode {
            logger.info("Bluetooth reconnected while in recovery mode")
            handleReconnectionSuccess()
        }
    }
    
    @objc private func handleReconnectFailure() {
        logger.warning("Bluetooth reconnection failed after multiple attempts")
        
        if isRecoveryMode {
            isRecoveryMode = false
            stopAutoRecording()
            recordingMessage = "Connection recovery failed. Recording stopped."
            errorMessage = "Unable to reconnect to Polar H10. Please check the device and try again."
        }
    }
    
    @objc private func handleDataBufferReady() {
        updateBufferedSessionCount()
        
        // If we're connected to the internet, try to sync immediately
        if isNetworkReachable() {
            syncBufferedSessions()
        }
    }
    
    // MARK: - Recovery Methods
    
    private func startReconnectionTimer() {
        reconnectionTimer?.invalidate()
        
        reconnectionTimer = Timer.scheduledTimer(withTimeInterval: 10.0, repeats: true) { [weak self] _ in
            guard let self = self, self.isRecoveryMode else { return }
            
            // Check if we've reconnected
            if self.bluetoothManager.connectionState == .connected {
                self.logger.info("Reconnected to device, resuming recording")
                self.handleReconnectionSuccess()
            }
        }
        
        if let timer = reconnectionTimer {
            RunLoop.current.add(timer, forMode: .common)
        }
    }
    
    private func stopReconnectionTimer() {
        reconnectionTimer?.invalidate()
        reconnectionTimer = nil
    }
    
    private func handleReconnectionSuccess() {
        // Stop the recovery mode
        isRecoveryMode = false
        stopReconnectionTimer()
        
        // If we were auto-recording, restart it with the last tag
        if isAutoRecording {
            selectedTag = lastActiveTag
            recordingMessage = "Connection restored. Resuming auto-recording with tag: \(selectedTag)"
            
            // Small delay to ensure services are discovered
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                guard let self = self else { return }
                self.startNextAutoRecordingSession()
            }
        } else {
            recordingMessage = "Connection restored. Ready to record."
        }
    }
    
    // MARK: - Buffer Management
    
    private func startSyncTimer() {
        syncTimer?.invalidate()
        
        // Try to sync buffered data every 5 minutes
        syncTimer = Timer.scheduledTimer(withTimeInterval: 300.0, repeats: true) { [weak self] _ in
            self?.syncBufferedSessions()
        }
        
        if let timer = syncTimer {
            RunLoop.current.add(timer, forMode: .common)
        }
    }
    
    private func updateBufferedSessionCount() {
        bufferedSessionCount = DataBufferService.shared.getBufferedSessionCount()
    }
    
    private func saveRecordingToBuffer() {
        // Ensure we have the necessary data
        guard userManager.isLoggedIn && !currentRRIntervals.isEmpty else {
            errorMessage = "Cannot save recording: missing data"
            return
        }
        
        // Create a unique session ID with timestamp
        let sessionId = "session_\(Int(Date().timeIntervalSince1970))"
        
        // Sanitize device info to prevent NUL byte issues
        let firmwareVersion = bluetoothManager.deviceInfo.firmwareRevision.replacingOccurrences(of: "\0", with: "")
        let modelName = bluetoothManager.deviceInfo.model.replacingOccurrences(of: "\0", with: "")
        
        // Create request data
        let recordingData = HRVRecordingData(
            user_id: userManager.email,
            device_info: HRVRecordingData.DeviceInfo(
                model: modelName,
                firmwareVersion: firmwareVersion
            ),
            recordingSessionId: sessionId,
            timestamp: ISO8601DateFormatter().string(from: Date()),
            rrIntervals: self.currentRRIntervals,
            heartRate: bluetoothManager.heartRate,
            motionArtifacts: false,
            tags: [selectedTag]
        )
        
        // Buffer the session data
        DataBufferService.shared.bufferSession(recordingData: recordingData)
        
        // Update the UI
        updateBufferedSessionCount()
        recordingMessage = "Recording saved to local buffer"
        logger.info("Recording saved to local buffer: \(sessionId)")
    }
    
    // MARK: - Network Connectivity
    
    private func isNetworkReachable() -> Bool {
        // A simple check - in a real app you might want to use a more robust network check
        let url = URL(string: "https://www.apple.com")!
        var success = false
        let semaphore = DispatchSemaphore(value: 0)
        
        let task = URLSession.shared.dataTask(with: url) { _, response, _ in
            if let httpResponse = response as? HTTPURLResponse,
               (200...299).contains(httpResponse.statusCode) {
                success = true
            }
            semaphore.signal()
        }
        
        task.resume()
        _ = semaphore.wait(timeout: .now() + 5.0)
        
        return success
    }
    
    // MARK: - Public Methods
    
    // Start a single recording session
    func startSingleRecording() {
        guard validateRecordingPrerequisites() else { return }
        
        // Calculate duration in seconds
        let durationInSeconds = recordingDuration * 60
        
        // Initialize recording
        isRecording = true
        recordingSecondsLeft = durationInSeconds
        recordingMessage = "Recording: \(formatTimeRemaining(recordingSecondsLeft))"
        errorMessage = nil
        
        // Clear any previous RR intervals before starting
        bluetoothManager.rrIntervals = []
        currentRRIntervals = []
        
        // Start the recording timer
        recordingTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            
            if self.recordingSecondsLeft > 0 {
                self.recordingSecondsLeft -= 1
                self.recordingMessage = "Recording: \(self.formatTimeRemaining(self.recordingSecondsLeft))"
            } else {
                // Capture the collected RR intervals
                self.currentRRIntervals = self.bluetoothManager.rrIntervals
                
                // Finish the recording
                self.finishRecording()
            }
        }
        
        // Ensure the timer works in background
        if let timer = recordingTimer {
            RunLoop.current.add(timer, forMode: .common)
        }
    }
    
    // Cancel the current recording
    func cancelRecording() {
        recordingTimer?.invalidate()
        recordingTimer = nil
        
        isRecording = false
        recordingMessage = "Recording cancelled"
        recordingSecondsLeft = 0
        currentRRIntervals = []
    }
    
    // Start automatic recording
    func startAutoRecording() {
        guard validateRecordingPrerequisites() else { return }
        
        // Validate interval and duration settings
        guard intervalBetweenRecordings >= 2 && intervalBetweenRecordings <= 10 else {
            errorMessage = "Interval (N) must be between 2 and 10 minutes"
            return
        }
        
        guard recordingDuration >= 3 && recordingDuration <= 5 else {
            errorMessage = "Duration (M) must be between 3 and 5 minutes"
            return
        }
        
        // Save the active tag
        lastActiveTag = selectedTag
        
        isAutoRecording = true
        errorMessage = nil
        recordingMessage = "Auto-recording will begin in 5 seconds"
        
        // Enable auto-reconnect for Bluetooth
        bluetoothManager.enableAutoReconnect()
        
        // Register with background task manager to keep recording in background
        BackgroundTaskManager.shared.beginBackgroundTask(withName: "HRVAutoRecording")
        
        // Start the first recording after a brief delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { [weak self] in
            guard let self = self, self.isAutoRecording else { return }
            self.startNextAutoRecordingSession()
        }
    }
    
    // Stop automatic recording
    func stopAutoRecording() {
        recordingTimer?.invalidate()
        recordingTimer = nil
        
        autoRecordingTimer?.invalidate()
        autoRecordingTimer = nil
        
        intervalTimer?.invalidate()
        intervalTimer = nil
        
        isAutoRecording = false
        isRecording = false
        isRecoveryMode = false
        recordingMessage = "Auto-recording stopped"
        
        // Disable auto-reconnect for Bluetooth
        bluetoothManager.disableAutoReconnect()
        
        // End background task
        BackgroundTaskManager.shared.endBackgroundTask()
        
        // Try to sync any buffered sessions
        syncBufferedSessions()
    }
    
    // Sync buffered sessions to the server
    func syncBufferedSessions() {
        let bufferedSessions = DataBufferService.shared.fetchBufferedSessions()
        
        guard !bufferedSessions.isEmpty else { return }
        
        logger.info("Attempting to sync \(bufferedSessions.count) buffered sessions")
        
        // Try to sync the first session
        syncNextBufferedSession(index: 0)
    }
    
    // Fetch the current session count for the user
    func fetchSessionCount() {
        guard userManager.isLoggedIn else {
            sessionCount = 0
            return
        }
        
        print("Fetching session count for user: \(userManager.email)")
        isRefreshingCount = true
        
        APIService.shared.getSessionCount(userId: userManager.email)
            .receive(on: DispatchQueue.main)
            .sink(
                receiveCompletion: { [weak self] completion in
                    self?.isRefreshingCount = false
                    if case .failure(let error) = completion {
                        self?.logger.error("Failed to fetch session count: \(error.message)")
                        print("Session count fetch error: \(error.message)")
                        if self?.sessionCount == 0 {
                            // Only show a fallback message if we don't have any count yet
                            self?.errorMessage = "Unable to connect to server. Using local count."
                        }
                    }
                },
                receiveValue: { [weak self] count in
                    self?.isRefreshingCount = false
                    self?.sessionCount = count
                    print("Updated session count to: \(count)")
                    self?.logger.info("Updated session count to: \(count)")
                }
            )
            .store(in: &cancellables)
    }
    
    // Force refresh session count
    func refreshSessionCount() {
        fetchSessionCount()
    }
    
    // MARK: - Private Methods
    
    private func validateRecordingPrerequisites() -> Bool {
        // Check if user is logged in
        guard userManager.isLoggedIn else {
            errorMessage = "Please log in before recording"
            return false
        }
        
        // Check bluetooth connection
        guard bluetoothManager.connectionState == .connected else {
            errorMessage = "Polar H10 not connected. Please connect first."
            return false
        }
        
        // Check if already recording
        guard !isRecording else {
            errorMessage = "Already recording"
            return false
        }
        
        return true
    }
    
    private func finishRecording(saveToBuffer: Bool = false) {
        recordingTimer?.invalidate()
        recordingTimer = nil
        
        isRecording = false
        
        if saveToBuffer {
            recordingMessage = "Saving recording to local buffer..."
            saveRecordingToBuffer()
        } else {
            recordingMessage = "Processing recording..."
            sendRecordingToAPI()
        }
    }
    
    private func startNextAutoRecordingSession() {
        guard isAutoRecording else { return }
        
        // Clear any existing timers
        recordingTimer?.invalidate()
        recordingTimer = nil
        
        // Start a new recording
        isRecording = true
        let durationInSeconds = recordingDuration * 60
        recordingSecondsLeft = durationInSeconds
        recordingMessage = "Auto-recording: \(formatTimeRemaining(recordingSecondsLeft))"
        
        // Clear previous RR intervals
        bluetoothManager.rrIntervals = []
        currentRRIntervals = []
        
        // Create recording timer
        recordingTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self = self, self.isAutoRecording else { return }
            
            if self.recordingSecondsLeft > 0 {
                self.recordingSecondsLeft -= 1
                self.recordingMessage = "Auto-recording: \(self.formatTimeRemaining(self.recordingSecondsLeft))"
            } else {
                // Capture the RR intervals and finish this recording
                self.currentRRIntervals = self.bluetoothManager.rrIntervals
                self.finishAutoRecordingSession()
            }
        }
        
        // Ensure the timer works in background
        if let timer = recordingTimer {
            RunLoop.current.add(timer, forMode: .common)
        }
    }
    
    private func finishAutoRecordingSession() {
        // Clean up recording timer
        recordingTimer?.invalidate()
        recordingTimer = nil
        
        isRecording = false
        
        // Check connection state
        if bluetoothManager.connectionState == .connected {
            recordingMessage = "Processing auto-recording..."
            
            // Send data to API
            sendRecordingToAPI { [weak self] success in
                guard let self = self, self.isAutoRecording else { return }
                
                if success {
                    // Schedule the next recording after the interval
                    self.scheduleNextAutoRecording()
                } else {
                    // If failed, save to buffer and continue
                    self.saveRecordingToBuffer()
                    self.scheduleNextAutoRecording()
                }
            }
        } else {
            // We're disconnected, save to buffer
            recordingMessage = "Connection unavailable. Saving recording to buffer..."
            saveRecordingToBuffer()
            
            // Try to reconnect if not already in recovery mode
            if !isRecoveryMode {
                isRecoveryMode = true
                bluetoothManager.enableAutoReconnect()
                startReconnectionTimer()
            }
        }
    }
    
    private func scheduleNextAutoRecording() {
        // Set the time until next recording (in seconds)
        timeUntilNextRecording = intervalBetweenRecordings * 60
        recordingMessage = "Next auto-recording in: \(formatTimeRemaining(timeUntilNextRecording))"
        
        // Create interval timer to countdown to next recording
        intervalTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self = self, self.isAutoRecording else { return }
            
            if self.timeUntilNextRecording > 0 {
                self.timeUntilNextRecording -= 1
                self.recordingMessage = "Next auto-recording in: \(self.formatTimeRemaining(self.timeUntilNextRecording))"
            } else {
                // Time's up - start the next recording
                self.intervalTimer?.invalidate()
                self.intervalTimer = nil
                self.startNextAutoRecordingSession()
            }
        }
        
        // Ensure the timer works in background
        if let timer = intervalTimer {
            RunLoop.current.add(timer, forMode: .common)
        }
    }
    
    private func syncNextBufferedSession(index: Int) {
        let bufferedSessions = DataBufferService.shared.fetchBufferedSessions()
        
        guard index < bufferedSessions.count else {
            // No more sessions to sync
            updateBufferedSessionCount()
            return
        }
        
        let session = bufferedSessions[index]
        
        // Check if we should retry this session
        if !DataBufferService.shared.shouldRetrySession(at: index) {
            logger.warning("Session \(session.recordingData.recordingSessionId) reached max retry attempts, skipping")
            // Skip to next session
            syncNextBufferedSession(index: index + 1)
            return
        }
        
        // Update attempt count
        DataBufferService.shared.updateBufferedSession(at: index, withAttemptCount: session.attemptCount + 1)
        
        // Try to send to API
        APIService.shared.sendHRVData(hrvData: session.recordingData)
            .receive(on: DispatchQueue.main)
            .sink(
                receiveCompletion: { [weak self] completionResult in
                    if case .failure(let error) = completionResult {
                        self?.logger.error("Failed to sync buffered session: \(error.message)")
                        
                        // Move on to the next session
                        self?.syncNextBufferedSession(index: index + 1)
                    }
                },
                receiveValue: { [weak self] response in
                    guard let self = self else { return }
                    
                    if response.status == "success" {
                        self.logger.info("Successfully synced buffered session")
                        
                        // Remove the successfully synced session
                        DataBufferService.shared.removeBufferedSession(at: index)
                        
                        // Update session count
                        self.fetchSessionCount()
                        
                        // Continue with next session (index stays the same since we removed one)
                        self.syncNextBufferedSession(index: index)
                    } else {
                        self.logger.error("API returned error for buffered session: \(response.message)")
                        
                        // Move on to the next session
                        self.syncNextBufferedSession(index: index + 1)
                    }
                }
            )
            .store(in: &cancellables)
    }
    
    private func sendRecordingToAPI(completion: ((Bool) -> Void)? = nil) {
        // Ensure we have the necessary data
        guard userManager.isLoggedIn,
              !self.currentRRIntervals.isEmpty,
              bluetoothManager.connectionState == .connected else {
            errorMessage = "Cannot send recording: missing data"
            completion?(false)
            return
        }
        
        // Create a unique session ID with timestamp
        let sessionId = "session_\(Int(Date().timeIntervalSince1970))"
        
        // Sanitize device info to prevent NUL byte issues
        let firmwareVersion = bluetoothManager.deviceInfo.firmwareRevision.replacingOccurrences(of: "\0", with: "")
        let modelName = bluetoothManager.deviceInfo.model.replacingOccurrences(of: "\0", with: "")
        
        // Create request data
        let recordingData = HRVRecordingData(
            user_id: userManager.email,
            device_info: HRVRecordingData.DeviceInfo(
                model: modelName,
                firmwareVersion: firmwareVersion
            ),
            recordingSessionId: sessionId,
            timestamp: ISO8601DateFormatter().string(from: Date()),
            rrIntervals: self.currentRRIntervals,
            heartRate: bluetoothManager.heartRate,
            motionArtifacts: false,
            tags: [selectedTag] // Single tag as per requirements
        )
        
        // Add debug info
        print("=== DEBUG INFO ===")
        print("Device Model: \(recordingData.device_info.model ?? "Unknown")")
        print("Firmware: \(recordingData.device_info.firmwareVersion ?? "Unknown")")
        print("RR Intervals: \(recordingData.rrIntervals.prefix(5))... (total: \(recordingData.rrIntervals.count))")
        print("==================")
        
        // Log the data we're sending
        logger.info("Sending recording data: \(sessionId)")
        logger.info("Device: \(modelName), Firmware: \(firmwareVersion)")
        logger.info("RR Intervals count: \(self.currentRRIntervals.count)")
        
        // Send to API
        APIService.shared.sendHRVData(hrvData: recordingData)
            .receive(on: DispatchQueue.main)
            .sink(
                receiveCompletion: { [weak self] completionResult in
                    if case .failure(let error) = completionResult {
                        self?.errorMessage = "API Error: \(error.message)"
                        self?.recordingMessage = "Recording failed to send"
                        self?.logger.error("API error: \(error.message)")
                        completion?(false)
                    }
                },
                receiveValue: { [weak self] response in
                    guard let self = self else { return }
                    
                    if response.status == "success" {
                        self.recordingMessage = "Recording saved successfully"
                        // Get latest count after successful submission
                        self.fetchSessionCount()
                        self.errorMessage = nil
                        self.logger.info("Recording saved successfully")
                        completion?(true)
                    } else {
                        self.errorMessage = "API returned error: \(response.message)"
                        self.recordingMessage = "Recording failed"
                        self.logger.error("API returned error: \(response.message)")
                        completion?(false)
                    }
                }
            )
            .store(in: &cancellables)
    }
    
    private func formatTimeRemaining(_ seconds: Int) -> String {
        let minutes = seconds / 60
        let remainingSeconds = seconds % 60
        return String(format: "%d:%02d", minutes, remainingSeconds)
    }
}
