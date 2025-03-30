// DataBufferService.swift

import Foundation
import os.log

// Add this notification name
extension Notification.Name {
    static let dataBufferReady = Notification.Name("com.hrvmetrics.polarh10.DataBufferReady")
}

// Structure for buffered recording sessions
struct BufferedSession: Codable {
    let recordingData: HRVRecordingData
    let timestamp: Date
    let attemptCount: Int
    
    init(recordingData: HRVRecordingData, attemptCount: Int = 0) {
        self.recordingData = recordingData
        self.timestamp = Date()
        self.attemptCount = attemptCount
    }
}

class DataBufferService {
    private let logger = Logger(subsystem: "com.hrvmetrics.polarh10", category: "DataBufferService")
    private let userDefaultsKey = "buffered_sessions"
    private let maxBufferSize = 50 // Maximum number of sessions to buffer
    private let maxRetryAttempts = 3
    
    // Singleton pattern
    static let shared = DataBufferService()
    
    private init() {}
    
    // Add a session to the buffer
    func bufferSession(recordingData: HRVRecordingData) {
        logger.info("Buffering session: \(recordingData.recordingSessionId)")
        
        let session = BufferedSession(recordingData: recordingData)
        var bufferedSessions = fetchBufferedSessions()
        
        // Add new session to buffer
        bufferedSessions.append(session)
        
        // Trim buffer if needed
        if bufferedSessions.count > maxBufferSize {
            logger.warning("Buffer size exceeded, removing oldest sessions")
            bufferedSessions = Array(bufferedSessions.suffix(maxBufferSize))
        }
        
        saveBufferedSessions(bufferedSessions)
        
        // Notify that a session was buffered
        NotificationCenter.default.post(name: .dataBufferReady, object: nil)
    }
    
    // Update a buffered session (increment attempt count)
    func updateBufferedSession(at index: Int, withAttemptCount count: Int) {
        var bufferedSessions = fetchBufferedSessions()
        guard index < bufferedSessions.count else { return }
        
        let session = bufferedSessions[index]
        let updatedSession = BufferedSession(
            recordingData: session.recordingData,
            attemptCount: count
        )
        
        bufferedSessions[index] = updatedSession
        saveBufferedSessions(bufferedSessions)
    }
    
    // Remove a session from the buffer
    func removeBufferedSession(at index: Int) {
        var bufferedSessions = fetchBufferedSessions()
        guard index < bufferedSessions.count else { return }
        
        bufferedSessions.remove(at: index)
        saveBufferedSessions(bufferedSessions)
    }
    
    // Get all buffered sessions
    func fetchBufferedSessions() -> [BufferedSession] {
        guard let data = UserDefaults.standard.data(forKey: userDefaultsKey) else {
            return []
        }
        
        do {
            let sessions = try JSONDecoder().decode([BufferedSession].self, from: data)
            return sessions
        } catch {
            logger.error("Failed to decode buffered sessions: \(error.localizedDescription)")
            return []
        }
    }
    
    // Save buffered sessions
    private func saveBufferedSessions(_ sessions: [BufferedSession]) {
        do {
            let data = try JSONEncoder().encode(sessions)
            UserDefaults.standard.set(data, forKey: userDefaultsKey)
        } catch {
            logger.error("Failed to encode buffered sessions: \(error.localizedDescription)")
        }
    }
    
    // Check if there are buffered sessions
    func hasBufferedSessions() -> Bool {
        return !fetchBufferedSessions().isEmpty
    }
    
    // Get the total count of buffered sessions
    func getBufferedSessionCount() -> Int {
        return fetchBufferedSessions().count
    }
    
    // Clear all buffered sessions
    func clearAllBufferedSessions() {
        UserDefaults.standard.removeObject(forKey: userDefaultsKey)
        logger.info("Cleared all buffered sessions")
    }
    
    // Check if a session has reached max retry attempts
    func shouldRetrySession(at index: Int) -> Bool {
        let sessions = fetchBufferedSessions()
        guard index < sessions.count else { return false }
        
        return sessions[index].attemptCount < maxRetryAttempts
    }
}
