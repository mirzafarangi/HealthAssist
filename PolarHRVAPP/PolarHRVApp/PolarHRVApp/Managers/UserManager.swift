// UserManager.swift

import Foundation
import Combine

class UserManager: ObservableObject {
    @Published var email: String = ""
    @Published var isLoggedIn: Bool = false
    @Published var errorMessage: String? = nil
    
    private let userDefaultsKey = "user_email"
    
    init() {
        // Check if user is already logged in
        if let savedEmail = UserDefaults.standard.string(forKey: userDefaultsKey), !savedEmail.isEmpty {
            self.email = savedEmail
            self.isLoggedIn = true
        }
    }
    
    func register(email: String) {
        // Validate email format
        guard isValidEmail(email) else {
            errorMessage = "Please enter a valid email address"
            return
        }
        
        // Clear error message
        errorMessage = nil
        
        // Save the email
        self.email = email
        UserDefaults.standard.set(email, forKey: userDefaultsKey)
        
        // Set logged in state
        self.isLoggedIn = true
    }
    
    func logout() {
        self.email = ""
        self.isLoggedIn = false
        UserDefaults.standard.removeObject(forKey: userDefaultsKey)
    }
    
    private func isValidEmail(_ email: String) -> Bool {
        let emailRegEx = "[A-Z0-9a-z._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,64}"
        let emailPred = NSPredicate(format:"SELF MATCHES %@", emailRegEx)
        return emailPred.evaluate(with: email)
    }
}
