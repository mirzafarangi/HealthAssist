// Views/ContentView.swift

import SwiftUI
import Combine

struct ContentView: View {
    @StateObject private var firebaseService = FirebaseService.shared
    @StateObject private var bluetoothManager = BluetoothManager()
    @StateObject private var recordingManager: RecordingManager
    
    init() {
        let firebase = FirebaseService.shared
        let bluetooth = BluetoothManager()
        _recordingManager = StateObject(wrappedValue: RecordingManager(
            bluetoothManager: bluetooth,
            firebaseService: firebase
        ))
    }
    
    var body: some View {
        if firebaseService.isAuthenticated {
            MainView(
                bluetoothManager: bluetoothManager,
                recordingManager: recordingManager,
                firebaseService: firebaseService
            )
        } else {
            AuthenticationView(firebaseService: firebaseService)
        }
    }
}

// MARK: - Authentication View

struct AuthenticationView: View {
    @ObservedObject var firebaseService: FirebaseService
    @State private var email = ""
    @State private var password = ""
    @State private var isSignUp = false
    @State private var isLoading = false
    @State private var errorMessage: String?
    
    var body: some View {
        NavigationView {
            VStack(spacing: 30) {
                // Logo/Header
                VStack(spacing: 10) {
                    Image(systemName: "heart.text.square.fill")
                        .resizable()
                        .frame(width: 80, height: 80)
                        .foregroundColor(.red)
                    
                    Text("HRV Recorder")
                        .font(.largeTitle)
                        .fontWeight(.bold)
                    
                    Text("Polar H10 Heart Rate Variability")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                .padding(.top, 50)
                
                // Form
                VStack(spacing: 20) {
                    TextField("Email", text: $email)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                        .keyboardType(.emailAddress)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                    
                    SecureField("Password", text: $password)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                    
                    if let error = errorMessage {
                        Text(error)
                            .foregroundColor(.red)
                            .font(.caption)
                            .multilineTextAlignment(.center)
                    }
                    
                    // Action Buttons
                    VStack(spacing: 15) {
                        Button(action: performAction) {
                            if isLoading {
                                ProgressView()
                                    .progressViewStyle(CircularProgressViewStyle(tint: .white))
                            } else {
                                Text(isSignUp ? "Sign Up" : "Sign In")
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(isFormValid ? Color.blue : Color.gray)
                        .foregroundColor(.white)
                        .cornerRadius(10)
                        .disabled(!isFormValid || isLoading)
                        
                        Button(action: { isSignUp.toggle() }) {
                            Text(isSignUp ? "Already have an account? Sign In" : "Don't have an account? Sign Up")
                                .font(.footnote)
                                .foregroundColor(.blue)
                        }
                    }
                }
                .padding(.horizontal, 30)
                
                Spacer()
            }
            .navigationBarHidden(true)
        }
    }
    
    private var isFormValid: Bool {
        !email.isEmpty && !password.isEmpty && password.count >= 6
    }
    
    private func performAction() {
        errorMessage = nil
        isLoading = true
        
        let publisher = isSignUp
            ? firebaseService.signUp(email: email, password: password)
            : firebaseService.signIn(email: email, password: password)
        
        publisher
            .receive(on: DispatchQueue.main)
            .sink(
                receiveCompletion: { completion in
                    isLoading = false
                    if case .failure(let error) = completion {
                        errorMessage = error.localizedDescription
                    }
                },
                receiveValue: { _ in
                    // Success - view will automatically update
                }
            )
            .store(in: &cancellables)
    }
    
    @State private var cancellables = Set<AnyCancellable>()
}

// MARK: - Main View

struct MainView: View {
    @ObservedObject var bluetoothManager: BluetoothManager
    @ObservedObject var recordingManager: RecordingManager
    @ObservedObject var firebaseService: FirebaseService
    @State private var showingTagInfo = false
    
    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 20) {
                    // Connection Status Card
                    ConnectionStatusCard(bluetoothManager: bluetoothManager)
                    
                    if bluetoothManager.connectionState == .connected {
                        // Recording Configuration
                        RecordingConfigurationCard(
                            recordingManager: recordingManager,
                            showingTagInfo: $showingTagInfo
                        )
                        
                        // Recording Control
                        RecordingControlCard(
                            bluetoothManager: bluetoothManager,
                            recordingManager: recordingManager
                        )
                        
                        // Session Statistics
                        SessionStatisticsCard(recordingManager: recordingManager)
                    } else {
                        // Connection Required Card
                        ConnectionRequiredCard(bluetoothManager: bluetoothManager)
                    }
                }
                .padding()
            }
            .navigationTitle("HRV Recorder")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        Button(action: { recordingManager.fetchSessionCount() }) {
                            Label("Refresh Sessions", systemImage: "arrow.clockwise")
                        }
                        
                        Divider()
                        
                        Button(action: { firebaseService.signOut() }) {
                            Label("Sign Out", systemImage: "rectangle.portrait.and.arrow.right")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
            .sheet(isPresented: $showingTagInfo) {
                TagInformationView()
            }
        }
    }
}

// MARK: - Component Views

struct ConnectionStatusCard: View {
    @ObservedObject var bluetoothManager: BluetoothManager
    
    var body: some View {
        VStack(spacing: 15) {
            HStack {
                Image(systemName: connectionIcon)
                    .foregroundColor(connectionColor)
                    .font(.title2)
                
                VStack(alignment: .leading) {
                    Text("Polar H10")
                        .font(.headline)
                    Text(bluetoothManager.connectionState.rawValue)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                Spacer()
                
                if bluetoothManager.connectionState == .connected {
                    VStack(alignment: .trailing) {
                        HStack {
                            Image(systemName: "heart.fill")
                                .foregroundColor(.red)
                            Text("\(bluetoothManager.heartRate) BPM")
                                .fontWeight(.semibold)
                        }
                        
                        HStack {
                            Image(systemName: batteryIcon)
                                .foregroundColor(batteryColor)
                            Text("\(bluetoothManager.batteryLevel)%")
                                .font(.caption)
                        }
                    }
                }
            }
            
            if let error = bluetoothManager.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.red)
                    .multilineTextAlignment(.center)
            }
        }
        .padding()
        .background(Color(.systemBackground))
        .cornerRadius(12)
        .shadow(color: Color.black.opacity(0.1), radius: 5)
    }
    
    private var connectionIcon: String {
        switch bluetoothManager.connectionState {
        case .connected: return "checkmark.circle.fill"
        case .connecting, .scanning: return "antenna.radiowaves.left.and.right"
        case .disconnected: return "xmark.circle"
        case .failed: return "exclamationmark.triangle"
        }
    }
    
    private var connectionColor: Color {
        switch bluetoothManager.connectionState {
        case .connected: return .green
        case .connecting, .scanning: return .orange
        case .disconnected: return .gray
        case .failed: return .red
        }
    }
    
    private var batteryIcon: String {
        if bluetoothManager.batteryLevel > 80 {
            return "battery.100"
        } else if bluetoothManager.batteryLevel > 50 {
            return "battery.75"
        } else if bluetoothManager.batteryLevel > 25 {
            return "battery.50"
        } else if bluetoothManager.batteryLevel > 10 {
            return "battery.25"
        } else {
            return "battery.0"
        }
    }
    
    private var batteryColor: Color {
        if bluetoothManager.batteryLevel > 50 {
            return .green
        } else if bluetoothManager.batteryLevel > 20 {
            return .yellow
        } else {
            return .red
        }
    }
}

struct ConnectionRequiredCard: View {
    @ObservedObject var bluetoothManager: BluetoothManager
    
    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "sensor.tag.radiowaves.forward")
                .font(.system(size: 60))
                .foregroundColor(.blue)
            
            Text("Connect Your Polar H10")
                .font(.title2)
                .fontWeight(.semibold)
            
            Text("Make sure your Polar H10 is powered on and nearby")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            
            Button(action: { bluetoothManager.startScanning() }) {
                if bluetoothManager.isScanning {
                    HStack {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle(tint: .white))
                            .scaleEffect(0.8)
                        Text("Scanning...")
                    }
                } else {
                    Text("Connect Device")
                }
            }
            .frame(maxWidth: .infinity)
            .padding()
            .background(Color.blue)
            .foregroundColor(.white)
            .cornerRadius(10)
            .disabled(bluetoothManager.connectionState == .connecting)
        }
        .padding()
        .background(Color(.systemBackground))
        .cornerRadius(12)
        .shadow(color: Color.black.opacity(0.1), radius: 5)
    }
}

struct RecordingConfigurationCard: View {
    @ObservedObject var recordingManager: RecordingManager
    @Binding var showingTagInfo: Bool
    
    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack {
                Text("Recording Configuration")
                    .font(.headline)
                Spacer()
                Button(action: { showingTagInfo = true }) {
                    Image(systemName: "info.circle")
                        .foregroundColor(.blue)
                }
            }
            
            // Tag Selection
            VStack(alignment: .leading, spacing: 8) {
                Text("Recording Type")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                
                Menu {
                    ForEach(RecordingTag.allCases, id: \.self) { tag in
                        Button(action: { recordingManager.selectedTag = tag }) {
                            VStack(alignment: .leading) {
                                Text(tag.displayName)
                                Text(tag.description)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(recordingManager.selectedTag.displayName)
                                .foregroundColor(.primary)
                            Text(recordingManager.selectedTag.description)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.down")
                            .foregroundColor(.secondary)
                    }
                    .padding()
                    .background(Color(.systemGray6))
                    .cornerRadius(8)
                }
                .disabled(recordingManager.isRecording)
            }
            
            // Duration Selection (if applicable)
            if recordingManager.selectedTag != .sleep {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Duration (minutes)")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    
                    HStack {
                        if recordingManager.selectedTag.allowsCustomDuration {
                            Slider(
                                value: Binding(
                                    get: { Double(recordingManager.recordingDuration) },
                                    set: { recordingManager.recordingDuration = Int($0) }
                                ),
                                in: 1...7,
                                step: 1
                            )
                            .disabled(recordingManager.isRecording)
                            
                            Text("\(recordingManager.recordingDuration) min")
                                .frame(width: 60)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(Color(.systemGray6))
                                .cornerRadius(6)
                        } else {
                            Text("7 min (fixed)")
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(Color(.systemGray6))
                                .cornerRadius(6)
                        }
                    }
                    
                    if let warning = recordingManager.durationWarning {
                        Text(warning)
                            .font(.caption)
                            .foregroundColor(.orange)
                    }
                }
            } else {
                Text("Duration: Until manually stopped")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .padding(.vertical, 5)
            }
            
            // Paired session indicator
            if recordingManager.selectedTag == .experimentPairedPost && recordingManager.pairedSessionId != nil {
                HStack {
                    Image(systemName: "link")
                        .foregroundColor(.blue)
                    Text("This will be paired with your previous Pre recording")
                        .font(.caption)
                        .foregroundColor(.blue)
                }
                .padding(.top, 5)
            }
        }
        .padding()
        .background(Color(.systemBackground))
        .cornerRadius(12)
        .shadow(color: Color.black.opacity(0.1), radius: 5)
    }
}

struct RecordingControlCard: View {
    @ObservedObject var bluetoothManager: BluetoothManager
    @ObservedObject var recordingManager: RecordingManager
    
    var body: some View {
        VStack(spacing: 15) {
            if recordingManager.isRecording {
                // Recording in progress
                VStack(spacing: 10) {
                    HStack {
                        Circle()
                            .fill(Color.red)
                            .frame(width: 12, height: 12)
                        Text("Recording in Progress")
                            .font(.headline)
                            .foregroundColor(.red)
                    }
                    
                    Text(recordingManager.recordingMessage)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    
                    // Progress indicator (for non-sleep recordings)
                    if recordingManager.selectedTag != .sleep {
                        let progress = Double(recordingManager.recordingSecondsElapsed) / Double(recordingManager.recordingDuration * 60)
                        ProgressView(value: progress)
                            .progressViewStyle(LinearProgressViewStyle(tint: .red))
                            .padding(.vertical, 5)
                    }
                    
                    // Stop button (only for sleep)
                    if recordingManager.selectedTag == .sleep {
                        Button(action: { recordingManager.stopRecording() }) {
                            Text("Stop Recording")
                                .frame(maxWidth: .infinity)
                                .padding()
                                .background(Color.red)
                                .foregroundColor(.white)
                                .cornerRadius(10)
                        }
                    }
                }
            } else if recordingManager.isLoading {
                // Processing
                VStack(spacing: 10) {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle())
                    Text(recordingManager.recordingMessage)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
            } else {
                // Ready to record
                Button(action: { recordingManager.startRecording() }) {
                    HStack {
                        Image(systemName: "record.circle")
                        Text("Start Recording")
                    }
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.green)
                    .foregroundColor(.white)
                    .cornerRadius(10)
                }
                .disabled(bluetoothManager.connectionState != .connected)
                
                if !recordingManager.recordingMessage.isEmpty {
                    Text(recordingManager.recordingMessage)
                        .font(.caption)
                        .foregroundColor(.green)
                }
            }
            
            if let error = recordingManager.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.red)
                    .multilineTextAlignment(.center)
            }
        }
        .padding()
        .background(Color(.systemBackground))
        .cornerRadius(12)
        .shadow(color: Color.black.opacity(0.1), radius: 5)
    }
}

struct SessionStatisticsCard: View {
    @ObservedObject var recordingManager: RecordingManager
    
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Session Statistics")
                    .font(.headline)
                Spacer()
                Button(action: { recordingManager.fetchSessionCount() }) {
                    Image(systemName: "arrow.clockwise")
                        .font(.caption)
                }
            }
            
            HStack {
                Image(systemName: "chart.bar.doc.horizontal")
                    .foregroundColor(.blue)
                Text("Total Sessions:")
                    .foregroundColor(.secondary)
                Spacer()
                Text("\(recordingManager.sessionCount)")
                    .font(.title2)
                    .fontWeight(.semibold)
            }
        }
        .padding()
        .background(Color(.systemBackground))
        .cornerRadius(12)
        .shadow(color: Color.black.opacity(0.1), radius: 5)
    }
}

struct TagInformationView: View {
    @Environment(\.presentationMode) var presentationMode
    
    var body: some View {
        NavigationView {
            List {
                ForEach(RecordingTag.allCases, id: \.self) { tag in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(tag.displayName)
                            .font(.headline)
                        Text(tag.rawValue)
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text(tag.description)
                            .font(.subheadline)
                        if tag == .sleep {
                            Text("Duration: Continuous (until stopped)")
                                .font(.caption)
                                .foregroundColor(.blue)
                        } else {
                            Text("Duration: \(tag.defaultDuration) minutes (adjustable 1-7)")
                                .font(.caption)
                                .foregroundColor(.blue)
                        }
                    }
                    .padding(.vertical, 5)
                }
            }
            .navigationTitle("Recording Types")
            .navigationBarItems(
                trailing: Button("Done") {
                    presentationMode.wrappedValue.dismiss()
                }
            )
        }
    }
}
