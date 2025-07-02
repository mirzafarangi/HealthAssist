// Models/HRVModels.swift

import Foundation

// Recording tag enum with associated properties
enum RecordingTag: String, CaseIterable {
    case rest = "Rest"
    case experimentPairedPre = "Experiment_Paired_Pre"
    case experimentPairedPost = "Experiment_Paired_Post"
    case experimentDuration = "Experiment_Duration"
    case breathWorkout = "Breath_Workout"
    case sleep = "Sleep"
    
    var defaultDuration: Int {
        switch self {
        case .rest, .experimentPairedPre, .experimentPairedPost, .breathWorkout:
            return 7
        case .experimentDuration:
            return 7 // Default, but flexible
        case .sleep:
            return -1 // Continuous until stopped
        }
    }
    
    var allowsCustomDuration: Bool {
        return self != .sleep
    }
    
    var displayName: String {
        switch self {
        case .rest: return "Morning Rest"
        case .experimentPairedPre: return "Before Event"
        case .experimentPairedPost: return "After Event"
        case .experimentDuration: return "During Activity"
        case .breathWorkout: return "Breath Control"
        case .sleep: return "Sleep"
        }
    }
    
    var description: String {
        switch self {
        case .rest: return "Baseline check, chronic trend monitoring"
        case .experimentPairedPre: return "Pre-event nervous system snapshot"
        case .experimentPairedPost: return "Immediate effect measurement"
        case .experimentDuration: return "Continuous load assessment"
        case .breathWorkout: return "HF assessment during breathing"
        case .sleep: return "Overnight recovery and stress detection"
        }
    }
}

// HRV Session data model
struct HRVSession: Codable {
    let sessionId: String
    let userId: String
    let userEmail: String
    let date: String // YYYY-MM-DD format
    let startTime: String // ISO 8601
    let endTime: String // ISO 8601
    let tag: String
    let pairedId: String? // For pre/post pairing
    let deviceInfo: DeviceInfo
    let rrIntervals: [Int]
    let heartRate: Int
    let duration: Int // in seconds
    let notes: String?
    
    struct DeviceInfo: Codable {
        let model: String
        let firmwareVersion: String
    }
    
    // Convert to dictionary for Firebase
    func toDictionary() -> [String: Any] {
        var dict: [String: Any] = [
            "sessionId": sessionId,
            "userId": userId,
            "userEmail": userEmail,
            "date": date,
            "startTime": startTime,
            "endTime": endTime,
            "tag": tag,
            "deviceInfo": [
                "model": deviceInfo.model,
                "firmwareVersion": deviceInfo.firmwareVersion
            ],
            "rrIntervals": rrIntervals,
            "heartRate": heartRate,
            "duration": duration
        ]
        
        if let pairedId = pairedId {
            dict["pairedId"] = pairedId
        }
        
        if let notes = notes {
            dict["notes"] = notes
        }
        
        return dict
    }
}
