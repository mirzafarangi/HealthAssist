// Managers/RecordingManager.swift

import Foundation
import Combine
import os.log

class RecordingManager: ObservableObject {
    private let logger = Logger(subsystem: "com.hrvmetrics.polarh10", category: "RecordingManager")
    private var cancellables = Set<AnyCancellable>()
    private let bluetoothManager: BluetoothManager
    private let firebaseService: FirebaseService
    
    // Recording settings
    @Published var selectedTag: RecordingTag = .rest
    @Published var recordingDuration: Int = 7 // M: minutes per recording (1-7)
    @Published var durationWarning: String?
    @Published var pairedSessionId: String? // For pre/post pairing
    
    // Recording state
    @Published var isRecording: Bool = false
    @Published var recordingSecondsElapsed: Int = 0
    @Published var recordingMessage: String = ""
    @Published var errorMessage: String?
    @Published var sessionCount: Int = 0
    @Published var isLoading: Bool = false
    
    // Current recording data
    private var currentRRIntervals: [Int] = []
    private var recordingTimer: Timer?
    private var recordingStartTime: Date?
    
    init(bluetoothManager: BluetoothManager, firebaseService: FirebaseService) {
        self.bluetoothManager = bluetoothManager
        self.firebaseService = firebaseService
        
        // Fetch session count on initialization
        fetchSessionCount()
        
        // Monitor tag changes to update duration
        $selectedTag
            .sink { [weak self] tag in
                self?.recordingDuration = tag.defaultDuration == -1 ? 7 : tag.defaultDuration
                self?.durationWarning = nil
            }
            .store(in: &cancellables)
    }
    
    // MARK: - Public Methods
    
    func startRecording() {
        // Validate prerequisites
        guard validateRecordingPrerequisites() else { return }
        
        // Validate duration for non-sleep tags
        if selectedTag.allowsCustomDuration {
            if recordingDuration < 1 || recordingDuration > 7 {
                errorMessage = "Duration must be between 1 and 7 minutes"
                return
            }
            
            if recordingDuration < 7 {
                durationWarning = "Recording for less than 7 minutes may affect analysis quality"
            }
        }
        
        // Initialize recording
        isRecording = true
        recordingSecondsElapsed = 0
        recordingStartTime = Date()
        errorMessage = nil
        currentRRIntervals = []
        
        // Clear previous RR intervals
        bluetoothManager.rrIntervals = []
        
        // Update message based on tag
        if selectedTag == .sleep {
            recordingMessage = "Recording sleep session... Tap 'Stop' when you wake up"
        } else {
            let totalSeconds = recordingDuration * 60
            recordingMessage = "Recording: \(formatTime(totalSeconds - recordingSecondsElapsed)) remaining"
        }
        
        // Start recording timer
        startRecordingTimer()
        
        // Enable background task for sleep recording
        if selectedTag == .sleep {
            BackgroundTaskManager.shared.beginBackgroundTask(withName: "SleepRecording")
        }
        
        logger.info("Started recording with tag: \(self.selectedTag.rawValue), duration: \(self.recordingDuration) minutes")
    }
    
    func stopRecording() {
        guard isRecording else { return }
        
        // For sleep tag or manual stop
        if selectedTag == .sleep || recordingSecondsElapsed > 0 {
            finishRecording()
        }
    }
    
    func cancelRecording() {
        guard isRecording else { return }
        
        recordingTimer?.invalidate()
        recordingTimer = nil
        
        isRecording = false
        recordingMessage = "Recording cancelled"
        recordingSecondsElapsed = 0
        currentRRIntervals = []
        
        // End background task if active
        if selectedTag == .sleep {
            BackgroundTaskManager.shared.endBackgroundTask()
        }
        
        logger.info("Recording cancelled by user")
    }
    
    func fetchSessionCount() {
        firebaseService.fetchSessionCount()
            .receive(on: DispatchQueue.main)
            .sink(
                receiveCompletion: { [weak self] completion in
                    if case .failure(let error) = completion {
                        self?.logger.error("Failed to fetch session count: \(error.localizedDescription)")
                    }
                },
                receiveValue: { [weak self] count in
                    self?.sessionCount = count
                    self?.logger.info("Updated session count to: \(count)")
                }
            )
            .store(in: &cancellables)
    }
    
    // MARK: - Private Methods
    
    private func validateRecordingPrerequisites() -> Bool {
        // Check authentication
        guard firebaseService.isAuthenticated else {
            errorMessage = "Please sign in before recording"
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
    
    private func startRecordingTimer() {
        recordingTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            
            self.recordingSecondsElapsed += 1
            
            // Check for connection loss
            if self.bluetoothManager.connectionState != .connected {
                self.handleConnectionLoss()
                return
            }
            
            // Update message and check completion
            if self.selectedTag == .sleep {
                // Sleep continues until manually stopped
                self.recordingMessage = "Recording sleep: \(self.formatTime(self.recordingSecondsElapsed)) elapsed"
            } else {
                // Fixed duration recordings
                let totalSeconds = self.recordingDuration * 60
                let remaining = totalSeconds - self.recordingSecondsElapsed
                
                if remaining > 0 {
                    self.recordingMessage = "Recording: \(self.formatTime(remaining)) remaining"
                } else {
                    // Recording complete
                    self.finishRecording()
                }
            }
        }
        
        if let timer = recordingTimer {
            RunLoop.current.add(timer, forMode: .common)
        }
    }
    
    private func handleConnectionLoss() {
        recordingTimer?.invalidate()
        recordingTimer = nil
        
        isRecording = false
        recordingMessage = "Recording failed: Connection lost"
        errorMessage = "Bluetooth connection lost. Recording discarded."
        currentRRIntervals = []
        
        // End background task if active
        if selectedTag == .sleep {
            BackgroundTaskManager.shared.endBackgroundTask()
        }
        
        logger.error("Recording failed due to connection loss")
    }
    
    private func finishRecording() {
        recordingTimer?.invalidate()
        recordingTimer = nil
        
        // Capture current RR intervals
        currentRRIntervals = bluetoothManager.rrIntervals
        
        // Validate we have data
        guard !currentRRIntervals.isEmpty else {
            isRecording = false
            recordingMessage = "Recording failed: No data collected"
            errorMessage = "No heart rate data was collected. Please ensure the sensor is properly positioned."
            logger.error("No RR intervals collected during recording")
            
            // End background task if active
            if selectedTag == .sleep {
                BackgroundTaskManager.shared.endBackgroundTask()
            }
            
            return
        }
        
        isRecording = false
        isLoading = true
        recordingMessage = "Processing and saving recording..."
        
        saveRecording()
    }
    
    private func saveRecording() {
        guard let user = firebaseService.currentUser,
              let startTime = recordingStartTime else {
            errorMessage = "Unable to save recording: User not authenticated"
            isLoading = false
            return
        }
        
        let endTime = Date()
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        let dateString = dateFormatter.string(from: startTime)
        
        // Create session data
        let sessionId = UUID().uuidString
        let session = HRVSession(
            sessionId: sessionId,
            userId: user.uid,
            userEmail: user.email ?? "unknown",
            date: dateString,
            startTime: ISO8601DateFormatter().string(from: startTime),
            endTime: ISO8601DateFormatter().string(from: endTime),
            tag: selectedTag.rawValue,
            pairedId: pairedSessionId,
            deviceInfo: HRVSession.DeviceInfo(
                model: bluetoothManager.deviceInfo.model,
                firmwareVersion: bluetoothManager.deviceInfo.firmwareRevision
            ),
            rrIntervals: currentRRIntervals,
            heartRate: bluetoothManager.heartRate,
            duration: recordingSecondsElapsed,
            notes: nil
        )
        
        // Store session ID for pairing if this is a pre-event recording
        if selectedTag == .experimentPairedPre {
            pairedSessionId = sessionId
        } else if selectedTag == .experimentPairedPost {
            // Clear paired ID after post recording
            pairedSessionId = nil
        }
        
        logger.info("Saving session: \(sessionId), RR count: \(self.currentRRIntervals.count), duration: \(self.recordingSecondsElapsed)s")
        
        // Save to Firebase
        firebaseService.saveHRVSession(session)
            .receive(on: DispatchQueue.main)
            .sink(
                receiveCompletion: { [weak self] completion in
                    self?.isLoading = false
                    
                    // End background task if active
                    if self?.selectedTag == .sleep {
                        BackgroundTaskManager.shared.endBackgroundTask()
                    }
                    
                    if case .failure(let error) = completion {
                        self?.errorMessage = "Failed to save recording: \(error.localizedDescription)"
                        self?.recordingMessage = "Recording failed to save"
                        self?.logger.error("Failed to save recording: \(error.localizedDescription)")
                    }
                },
                receiveValue: { [weak self] sessionKey in
                    self?.isLoading = false
                    self?.recordingMessage = "Recording saved successfully"
                    self?.errorMessage = nil
                    self?.fetchSessionCount()
                    self?.logger.info("Recording saved successfully: \(sessionKey)")
                    
                    // Clear the message after 3 seconds
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                        self?.recordingMessage = ""
                    }
                }
            )
            .store(in: &cancellables)
    }
    
    private func formatTime(_ seconds: Int) -> String {
        if seconds < 3600 {
            // Less than an hour: MM:SS
            let minutes = seconds / 60
            let remainingSeconds = seconds % 60
            return String(format: "%d:%02d", minutes, remainingSeconds)
        } else {
            // More than an hour: HH:MM:SS
            let hours = seconds / 3600
            let minutes = (seconds % 3600) / 60
            let remainingSeconds = seconds % 60
            return String(format: "%d:%02d:%02d", hours, minutes, remainingSeconds)
        }
    }
}
