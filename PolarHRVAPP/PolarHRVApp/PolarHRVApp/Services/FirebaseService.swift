// Services/FirebaseService.swift

import Foundation
import Firebase
import FirebaseAuth
import FirebaseDatabase
import Combine

class FirebaseService: ObservableObject {
    static let shared = FirebaseService()
    
    @Published var isAuthenticated = false
    @Published var currentUser: User?
    
    private let auth = Auth.auth()
    private let database = Database.database()
    
    private init() {
        // Listen to authentication state changes
        auth.addStateDidChangeListener { [weak self] _, user in
            self?.currentUser = user
            self?.isAuthenticated = user != nil
        }
    }
    
    // MARK: - Authentication
    
    func signIn(email: String, password: String) -> AnyPublisher<User, Error> {
        Future { promise in
            self.auth.signIn(withEmail: email, password: password) { result, error in
                if let error = error {
                    promise(.failure(error))
                } else if let user = result?.user {
                    promise(.success(user))
                } else {
                    promise(.failure(NSError(domain: "Auth", code: -1, userInfo: [NSLocalizedDescriptionKey: "Unknown error"])))
                }
            }
        }
        .eraseToAnyPublisher()
    }
    
    func signUp(email: String, password: String) -> AnyPublisher<User, Error> {
        Future { promise in
            self.auth.createUser(withEmail: email, password: password) { result, error in
                if let error = error {
                    promise(.failure(error))
                } else if let user = result?.user {
                    // Create user record in database
                    let userRef = self.database.reference().child("users").child(user.uid)
                    let userData: [String: Any] = [
                        "email": email,
                        "userId": user.uid,
                        "createdAt": ServerValue.timestamp()
                    ]
                    
                    userRef.setValue(userData) { error, _ in
                        if let error = error {
                            promise(.failure(error))
                        } else {
                            promise(.success(user))
                        }
                    }
                } else {
                    promise(.failure(NSError(domain: "Auth", code: -1, userInfo: [NSLocalizedDescriptionKey: "Unknown error"])))
                }
            }
        }
        .eraseToAnyPublisher()
    }
    
    func signOut() {
        try? auth.signOut()
    }
    
    // MARK: - Database Operations
    
    func saveHRVSession(_ session: HRVSession) -> AnyPublisher<String, Error> {
        Future { promise in
            guard let userId = self.currentUser?.uid else {
                promise(.failure(NSError(domain: "Firebase", code: -1, userInfo: [NSLocalizedDescriptionKey: "User not authenticated"])))
                return
            }
            
            let sessionRef = self.database.reference()
                .child("sessions")
                .child(userId)
                .childByAutoId()
            
            sessionRef.setValue(session.toDictionary()) { error, _ in
                if let error = error {
                    promise(.failure(error))
                } else {
                    promise(.success(sessionRef.key ?? ""))
                }
            }
        }
        .eraseToAnyPublisher()
    }
    
    func fetchSessionCount() -> AnyPublisher<Int, Error> {
        Future { promise in
            guard let userId = self.currentUser?.uid else {
                promise(.failure(NSError(domain: "Firebase", code: -1, userInfo: [NSLocalizedDescriptionKey: "User not authenticated"])))
                return
            }
            
            self.database.reference()
                .child("sessions")
                .child(userId)
                .observeSingleEvent(of: .value) { snapshot in
                    let count = snapshot.childrenCount
                    promise(.success(Int(count)))
                } withCancel: { error in
                    promise(.failure(error))
                }
        }
        .eraseToAnyPublisher()
    }
    
    func fetchSessions(limit: Int = 100) -> AnyPublisher<[HRVSession], Error> {
        Future { promise in
            guard let userId = self.currentUser?.uid else {
                promise(.failure(NSError(domain: "Firebase", code: -1, userInfo: [NSLocalizedDescriptionKey: "User not authenticated"])))
                return
            }
            
            self.database.reference()
                .child("sessions")
                .child(userId)
                .queryLimited(toLast: UInt(limit))
                .observeSingleEvent(of: .value) { snapshot in
                    var sessions: [HRVSession] = []
                    
                    for child in snapshot.children {
                        if let snapshot = child as? DataSnapshot,
                           let dict = snapshot.value as? [String: Any],
                           let data = try? JSONSerialization.data(withJSONObject: dict),
                           let session = try? JSONDecoder().decode(HRVSession.self, from: data) {
                            sessions.append(session)
                        }
                    }
                    
                    promise(.success(sessions))
                } withCancel: { error in
                    promise(.failure(error))
                }
        }
        .eraseToAnyPublisher()
    }
}
