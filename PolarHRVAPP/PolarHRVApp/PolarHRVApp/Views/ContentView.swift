// ContentView.swift

import SwiftUI


struct ContentView: View {
    @ObservedObject var userManager: UserManager
    @ObservedObject var bluetoothManager: BluetoothManager
    @ObservedObject var recordingManager: RecordingManager
 
    var body: some View {
        if userManager.isLoggedIn {
            MainView(
                userManager: userManager,
                bluetoothManager: bluetoothManager,
                recordingManager: recordingManager
            )
        } else {
            RegistrationView(userManager: userManager)
        }
    }
}

struct RegistrationView: View {
    @ObservedObject var userManager: UserManager
    @State private var email = ""
    @State private var isPrivacyExpanded = false
    
    var body: some View {
        VStack(spacing: 30) {
            // Header
            Text("HRV Metrics Analysis")
                .font(.largeTitle)
                .fontWeight(.bold)
                .padding(.top, 50)
            
            // Registration Form
            VStack(alignment: .leading, spacing: 20) {
                Text("Enter your email to participate in the study:")
                    .font(.headline)
                
                TextField("Email", text: $email)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                    .keyboardType(.emailAddress)
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
                
                // Privacy Disclosure
                DisclosureGroup(
                    isExpanded: $isPrivacyExpanded,
                    content: {
                        Text("By registering, you consent to participate in the HRV Metrics Analysis study. Your heart rate variability data will be collected and analyzed for research purposes. All data is stored securely and anonymized for analysis.")
                            .font(.subheadline)
                            .padding(.vertical, 10)
                    },
                    label: {
                        Text("Privacy Information")
                            .foregroundColor(.blue)
                    }
                )
                .padding(.vertical, 10)
                
                if let errorMessage = userManager.errorMessage {
                    Text(errorMessage)
                        .foregroundColor(.red)
                        .font(.subheadline)
                }
                
                // Register Button
                Button(action: {
                    userManager.register(email: email)
                }) {
                    Text("Register & Enter")
                        .font(.headline)
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.blue)
                        .cornerRadius(10)
                }
                .disabled(email.isEmpty)
            }
            .padding()
            .background(Color(.systemBackground))
            .cornerRadius(12)
            .shadow(radius: 5)
            .padding(.horizontal, 20)
            
            Spacer()
        }
        .padding()
        .background(Color(.systemGray6).ignoresSafeArea())
    }
}

struct MainView: View {
    @ObservedObject var userManager: UserManager
    @ObservedObject var bluetoothManager: BluetoothManager
    @ObservedObject var recordingManager: RecordingManager
    
    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 20) {
                    // SECTION 1: Connection Status
                    connectionStatusSection
                    
                    Divider()
                    
                    // SECTION 2: Connection Controls
                    connectionControlsSection
                    
                    if bluetoothManager.connectionState == .connected {
                        Divider()
                        
                        // SECTION 3: Device Information
                        deviceInfoSection
                        
                        Divider()
                        
                        // SECTION 4: Recording Configuration
                        recordingConfigSection
                        
                        Divider()
                        
                        // SECTION 5: Recording Controls
                        recordingControlsSection
                        
                        Divider()
                        
                        // SECTION 6: Recording Status
                        recordingStatusSection
                    }
                }
                .padding()
            }
            .navigationTitle("Polar H10 Connection")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: {
                        userManager.logout()
                    }) {
                        Image(systemName: "rectangle.portrait.and.arrow.right")
                    }
                }
            }
            .onAppear {
                // If not yet connected, start scanning automatically
                if bluetoothManager.connectionState == .disconnected {
                    bluetoothManager.startScanning()
                }
                recordingManager.fetchSessionCount()
            }
        }
    }
    
    // MARK: - Section Views
    
    private var connectionStatusSection: some View {
        VStack(spacing: 10) {
            HStack {
                Text("Status:")
                    .font(.headline)
                
                Text(bluetoothManager.connectionState.rawValue)
                    .foregroundColor(statusColor)
                    .fontWeight(.bold)
                
                if bluetoothManager.isScanning {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle())
                        .scaleEffect(0.8)
                }
            }
            
            if bluetoothManager.connectionState == .connected {
                HStack {
                    Image(systemName: "heart.fill")
                        .foregroundColor(.red)
                    Text("Heart Rate: \(bluetoothManager.heartRate) BPM")
                        .fontWeight(.bold)
                }
                
                HStack {
                    Image(systemName: "battery.100")
                        .foregroundColor(batteryColor)
                    Text("Battery: \(bluetoothManager.batteryLevel)%")
                }
            }
            
            if let errorMessage = bluetoothManager.errorMessage {
                Text(errorMessage)
                    .foregroundColor(.red)
                    .font(.footnote)
            }
        }
        .padding()
        .background(Color(.systemGray6))
        .cornerRadius(10)
    }
    
    private var connectionControlsSection: some View {
        HStack(spacing: 20) {
            Button(action: {
                bluetoothManager.startScanning()
            }) {
                Text("Connect")
                    .frame(minWidth: 100)
                    .padding()
                    .background(Color.blue)
                    .foregroundColor(.white)
                    .cornerRadius(8)
            }
            .disabled(bluetoothManager.connectionState == .scanning ||
                      bluetoothManager.connectionState == .connecting ||
                      bluetoothManager.connectionState == .connected)
            
            if bluetoothManager.connectionState == .connected {
                Button(action: {
                    // Don't disconnect if recording is active
                    if !recordingManager.isRecording && !recordingManager.isAutoRecording {
                        bluetoothManager.disconnect()
                    }
                }) {
                    Text("Disconnect")
                        .frame(minWidth: 100)
                        .padding()
                        .background(recordingManager.isRecording || recordingManager.isAutoRecording ? Color.gray : Color.red)
                        .foregroundColor(.white)
                        .cornerRadius(8)
                }
                .disabled(recordingManager.isRecording || recordingManager.isAutoRecording)
            }
        }
    }
    
    private var deviceInfoSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Device Information")
                .font(.headline)
            
            Group {
                infoRow(label: "Manufacturer", value: bluetoothManager.deviceInfo.manufacturer)
                infoRow(label: "Model", value: bluetoothManager.deviceInfo.model)
                infoRow(label: "Serial", value: bluetoothManager.deviceInfo.serialNumber)
                infoRow(label: "Firmware", value: bluetoothManager.deviceInfo.firmwareRevision)
                infoRow(label: "Hardware", value: bluetoothManager.deviceInfo.hardwareRevision)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color(.systemGray6))
        .cornerRadius(10)
    }
    
    private var recordingConfigSection: some View {
        VStack(alignment: .leading, spacing: 15) {
            Text("Recording Configuration")
                .font(.headline)
            
            HStack {
                Text("N:")
                    .fontWeight(.semibold)
                
                Text("Minutes between recordings")
                    .font(.footnote)
                    .foregroundColor(.secondary)
                
                Spacer()
                
                Picker("", selection: $recordingManager.intervalBetweenRecordings) {
                    ForEach(2...10, id: \.self) { value in
                        Text("\(value)").tag(value)
                    }
                }
                .frame(width: 100)
                .clipped()
                .disabled(recordingManager.isAutoRecording)
            }
            
            HStack {
                Text("M:")
                    .fontWeight(.semibold)
                
                Text("Minutes per recording")
                    .font(.footnote)
                    .foregroundColor(.secondary)
                
                Spacer()
                
                Picker("", selection: $recordingManager.recordingDuration) {
                    ForEach(3...5, id: \.self) { value in
                        Text("\(value)").tag(value)
                    }
                }
                .frame(width: 100)
                .clipped()
                .disabled(recordingManager.isAutoRecording)
            }
            
            HStack {
                Text("Tag:")
                    .fontWeight(.semibold)
                
                Spacer()
                
                Picker("", selection: $recordingManager.selectedTag) {
                    ForEach(recordingManager.availableTags, id: \.self) { tag in
                        Text(tag).tag(tag)
                    }
                }
                .disabled(recordingManager.isRecording || recordingManager.isAutoRecording)
            }
        }
        .padding()
        .background(Color(.systemGray6))
        .cornerRadius(10)
    }
    
    private var recordingControlsSection: some View {
        VStack(spacing: 15) {
            if !recordingManager.isAutoRecording {
                // Single recording mode
                Button(action: {
                    recordingManager.startSingleRecording()
                }) {
                    Text("Start Single Recording")
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.green)
                        .foregroundColor(.white)
                        .cornerRadius(10)
                }
                .disabled(recordingManager.isRecording || !isDeviceReady)
            }
            
            if recordingManager.isRecording && !recordingManager.isAutoRecording {
                Button(action: {
                    recordingManager.cancelRecording()
                }) {
                    Text("Cancel Recording")
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.orange)
                        .foregroundColor(.white)
                        .cornerRadius(10)
                }
            }
            
            // Auto recording controls
            if !recordingManager.isAutoRecording {
                Button(action: {
                    recordingManager.startAutoRecording()
                }) {
                    Text("Start Auto Recording")
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.blue)
                        .foregroundColor(.white)
                        .cornerRadius(10)
                }
                .disabled(!isDeviceReady || recordingManager.isRecording)
            } else {
                Button(action: {
                    recordingManager.stopAutoRecording()
                }) {
                    Text("Stop Auto Recording")
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.red)
                        .foregroundColor(.white)
                        .cornerRadius(10)
                }
            }
            
            if let errorMessage = recordingManager.errorMessage {
                Text(errorMessage)
                    .foregroundColor(.red)
                    .font(.footnote)
                    .padding(.top, 5)
            }
        }
        .padding()
        .background(Color(.systemGray6))
        .cornerRadius(10)
    }
    
    private var recordingStatusSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Recording Status")
                    .font(.headline)
                
                Spacer()
                
                // Session count display with refresh indicator
                HStack {
                    Image(systemName: "list.bullet.clipboard")
                    Text("Sessions: \(recordingManager.sessionCount)")
                    Button(action: {
                        recordingManager.fetchSessionCount()
                    }) {
                        Image(systemName: recordingManager.isRefreshingCount ? "hourglass" : "arrow.clockwise")
                            .font(.caption)
                    }
                }
                .foregroundColor(.secondary)
                .font(.subheadline)
            }
            
            // Buffer status display
            if recordingManager.bufferedSessionCount > 0 {
                HStack {
                    Image(systemName: "tray.full.fill")
                        .foregroundColor(.orange)
                    Text("Buffered: \(recordingManager.bufferedSessionCount)")
                    Button(action: {
                        recordingManager.syncBufferedSessions()
                    }) {
                        Image(systemName: "arrow.clockwise.circle")
                            .font(.caption)
                    }
                }
                .foregroundColor(.orange)
                .font(.subheadline)
                .padding(.top, 4)
            }
            
            // Recovery mode indicator
            if recordingManager.isRecoveryMode {
                HStack {
                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .foregroundColor(.yellow)
                    Text("Recovery mode active")
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle())
                        .scaleEffect(0.6)
                }
                .foregroundColor(.yellow)
                .font(.subheadline)
                .padding(.top, 4)
            }
            
            if !recordingManager.recordingMessage.isEmpty {
                Text(recordingManager.recordingMessage)
                    .foregroundColor(.blue)
                    .padding(.top, 5)
            }
            
            if recordingManager.isRecording {
                ProgressView(value: Float(recordingManager.recordingDuration * 60 - recordingManager.recordingSecondsLeft), total: Float(recordingManager.recordingDuration * 60))
                    .padding(.top, 5)
            } else if recordingManager.isAutoRecording && recordingManager.timeUntilNextRecording > 0 {
                ProgressView(value: Float(recordingManager.intervalBetweenRecordings * 60 - recordingManager.timeUntilNextRecording), total: Float(recordingManager.intervalBetweenRecordings * 60))
                    .padding(.top, 5)
            }
        }
        .padding()
        .background(Color(.systemGray6))
        .cornerRadius(10)
        .onAppear {
            // Refresh the count whenever this section appears
            recordingManager.fetchSessionCount()
        }
    }
    // MARK: - Helper Methods
    
    private func infoRow(label: String, value: String) -> some View {
        HStack {
            Text(label + ":")
                .fontWeight(.medium)
                .frame(width: 100, alignment: .leading)
            Text(value)
                .foregroundColor(.primary)
        }
    }
    
    private var statusColor: Color {
        switch bluetoothManager.connectionState {
        case .connected:
            return .green
        case .disconnected:
            return .gray
        case .scanning, .connecting:
            return .orange
        case .failed:
            return .red
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
    
    private var isDeviceReady: Bool {
        return bluetoothManager.connectionState == .connected
    }
}
