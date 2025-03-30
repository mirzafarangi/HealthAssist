// APIService.swift

import Foundation
import Combine

enum NetworkError: Error {
    case invalidURL
    case noData
    case decodingError
    case httpError(statusCode: Int, message: String)
    case unknownError(Error)
    
    var message: String {
        switch self {
        case .invalidURL:
            return "Invalid URL"
        case .noData:
            return "No data received"
        case .decodingError:
            return "Error decoding response"
        case .httpError(_, let message):
            return message
        case .unknownError(let error):
            return error.localizedDescription
        }
    }
}

class APIService {
    static let shared = APIService()
    private let baseURL = "https://hrv-api-86i0.onrender.com/api"
    
    private init() {}
    
    // MARK: - Send HRV Session Data to API
    func sendHRVData(hrvData: HRVRecordingData) -> AnyPublisher<APIResponse, NetworkError> {
        guard let url = URL(string: "\(baseURL)/hrv/session") else {
            return Fail(error: NetworkError.invalidURL).eraseToAnyPublisher()
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        
        do {
            // Special sanitization for the payload to prevent SQL errors
            // Create a mutable copy of the HRVRecordingData to sanitize it
            var sanitizedData = hrvData
            
            // Sanitize device model and firmware
            if let model = sanitizedData.device_info.model {
                sanitizedData.device_info.model = sanitizeString(model)
            }
            
            if let firmware = sanitizedData.device_info.firmwareVersion {
                sanitizedData.device_info.firmwareVersion = sanitizeString(firmware)
            }
            
            // Encode the sanitized data
            let jsonData = try JSONEncoder().encode(sanitizedData)
            
            // Log the payload for debugging
            if let jsonString = String(data: jsonData, encoding: .utf8) {
                print("API Request Payload: \(jsonString)")
            }
            
            request.httpBody = jsonData
            
            return URLSession.shared.dataTaskPublisher(for: request)
                .tryMap { data, response in
                    guard let httpResponse = response as? HTTPURLResponse else {
                        throw NetworkError.unknownError(NSError(domain: "No HTTP Response", code: 0))
                    }
                    
                    // Log the raw response for debugging
                    if let responseString = String(data: data, encoding: .utf8) {
                        print("API Response: \(responseString)")
                    }
                    
                    guard (200...299).contains(httpResponse.statusCode) else {
                        let errorText = String(data: data, encoding: .utf8) ?? "Unknown error"
                        throw NetworkError.httpError(statusCode: httpResponse.statusCode, message: errorText)
                    }
                    
                    return data
                }
                .decode(type: APIResponse.self, decoder: JSONDecoder())
                .mapError { error in
                    if let networkError = error as? NetworkError {
                        return networkError
                    } else if error is DecodingError {
                        print("Decoding error: \(error)")
                        return NetworkError.decodingError
                    } else {
                        print("Other error: \(error)")
                        return NetworkError.unknownError(error)
                    }
                }
                .eraseToAnyPublisher()
        } catch {
            print("Error preparing request: \(error)")
            return Fail(error: NetworkError.unknownError(error)).eraseToAnyPublisher()
        }
    }
    
    // MARK: - Get Session Count for User
    func getSessionCount(userId: String) -> AnyPublisher<Int, NetworkError> {
        guard let encodedUserId = userId.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else {
            print("Invalid user ID for encoding: \(userId)")
            return Fail(error: NetworkError.invalidURL).eraseToAnyPublisher()
        }
        
        // Add a higher limit parameter (adjust as needed based on your API's maximum)
        let url = URL(string: "\(baseURL)/hrv/sessions/user/\(encodedUserId)?limit=1000")
        
        guard let requestURL = url else {
            print("Failed to create URL for user ID: \(userId)")
            return Fail(error: NetworkError.invalidURL).eraseToAnyPublisher()
        }
        
        print("Fetching sessions for user: \(userId) with URL: \(requestURL.absoluteString)")
        
        var request = URLRequest(url: requestURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 30 // Increase timeout to 30 seconds
        
        return URLSession.shared.dataTaskPublisher(for: request)
            .tryMap { data, response in
                guard let httpResponse = response as? HTTPURLResponse else {
                    throw NetworkError.unknownError(NSError(domain: "No HTTP Response", code: 0))
                }
                
                print("Session count API response status: \(httpResponse.statusCode)")
                
                guard (200...299).contains(httpResponse.statusCode) else {
                    let errorText = String(data: data, encoding: .utf8) ?? "Unknown error"
                    throw NetworkError.httpError(statusCode: httpResponse.statusCode, message: errorText)
                }
                
                return data
            }
            .decode(type: [SessionSummary].self, decoder: JSONDecoder())
            .map { sessions in
                let count = sessions.count
                print("Decoded \(count) sessions for user \(userId)")
                return count
            }
            .catch { error -> AnyPublisher<Int, NetworkError> in
                print("Error in getSessionCount: \(error)")
                return Fail(error: error is NetworkError ? error as! NetworkError : NetworkError.unknownError(error)).eraseToAnyPublisher()
            }
            .eraseToAnyPublisher()
    }
    
    // MARK: - Test API Connection
    func testAPIConnection() -> AnyPublisher<Bool, NetworkError> {
        guard let url = URL(string: "\(baseURL)/hrv/database-stats") else {
            return Fail(error: NetworkError.invalidURL).eraseToAnyPublisher()
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        
        return URLSession.shared.dataTaskPublisher(for: request)
            .tryMap { data, response in
                guard let httpResponse = response as? HTTPURLResponse else {
                    throw NetworkError.unknownError(NSError(domain: "No HTTP Response", code: 0))
                }
                
                print("API test response status: \(httpResponse.statusCode)")
                if let responseString = String(data: data, encoding: .utf8) {
                    print("API test response: \(responseString)")
                }
                
                // Return true if status code is in 200-299 range
                return (200...299).contains(httpResponse.statusCode)
            }
            .catch { error -> AnyPublisher<Bool, NetworkError> in
                print("API test error: \(error)")
                return Just(false).setFailureType(to: NetworkError.self).eraseToAnyPublisher()
            }
            .eraseToAnyPublisher()
    }
    
    // MARK: - String Sanitization
    private func sanitizeString(_ input: String) -> String {
        // Remove NUL bytes (0x00) that would cause SQL errors
        let sanitized = input.replacingOccurrences(of: "\0", with: "")
        
        // Remove other potentially problematic characters
        let safeString = sanitized
            .replacingOccurrences(of: "'", with: "")  // Remove single quotes
            .replacingOccurrences(of: "\"", with: "") // Remove double quotes
            .trimmingCharacters(in: .whitespacesAndNewlines) // Trim whitespace
        
        return safeString
    }
}

// MARK: - API Models
struct HRVRecordingData: Codable {
    let user_id: String
    var device_info: DeviceInfo
    let recordingSessionId: String
    let timestamp: String
    let rrIntervals: [Int]
    let heartRate: Int
    let motionArtifacts: Bool
    let tags: [String]
    
    struct DeviceInfo: Codable {
        var model: String?
        var firmwareVersion: String?
    }
}

struct APIResponse: Codable {
    let status: String
    let message: String
    let data: ResponseData?
    
    struct ResponseData: Codable {
        let metadata: Metadata?
        let metrics: Metrics?
        
        struct Metadata: Codable {
            let timestamp: String
            let recordingSessionId: String
            let valid: Bool
            let quality_score: Double?
            let quality_label: String?
        }
        
        struct Metrics: Codable {
            let mean_rr: Double?
            let sdnn: Double?
            let rmssd: Double?
            let pnn50: Double?
            let lfPower: Double?
            let hfPower: Double?
            let lfHfRatio: Double?
        }
    }
}

struct SessionSummary: Codable {
    let id: String
    let recordingSessionId: String
    let timestamp: String
    let valid: Bool
    let tags: [String]
}
