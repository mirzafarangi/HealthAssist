# HRV Metrics Analysis Platform

## Project Overview

This project represents a Heart Rate Variability (HRV) analysis platform designed for continuous cardiovascular metrics monitoring and analysis. The system collects, processes, and visualizes HRV data from a Polar H10 heart rate sensor, providing scientific-grade insights into autonomic nervous system function and recovery dynamics.

Unlike commercial platforms that obscure their algorithms and interpretation methods, this project implements an open, customizable approach to HRV analysis—providing complete transparency while maintaining clinical validity. The system is built on established physiological principles while incorporating modern data science methods for validation and interpretation.

The platform consists of three integrated components:

1. **iOS App (PolarHRVApp)**: A custom-built application that connects directly to the Polar H10 sensor, recording raw RR intervals and implementing configurable data collection protocols
2. **Backend API (hrv-api)**: A robust processing engine that validates signal integrity, calculates different HRV metrics, and applies physiological interpretation models
3. **HealthAssist Dashboard**: A data visualization platform that presents metrics with context-aware insights, trend analysis, and predictive modeling

<details>
<summary><h2>iOS App Architecture</h2></summary>

### Core Functionality

The custom iOS app serves as the data acquisition component, establishing a direct Bluetooth Low Energy (BLE) connection with the Polar H10 heart rate sensor to capture raw RR intervals. The app features:

#### Connection Management

The `BluetoothManager` class handles all aspects of BLE communication with the Polar H10:

- Discovers and connects to the sensor
- Retrieves device information (model, firmware, battery level)
- Processes real-time heart rate and RR interval data
- Maintains connection integrity during background operation
- Detects and flags motion artifacts that might compromise data quality

#### Configurable Recording System

The recording system is designed around two key parameters:

- **N (Interval Between Recordings)**: Time between recording sessions (configurable from 2-10 minutes)
- **M (Recording Duration)**: Length of each recording session (configurable from 3-5 minutes)

This implementation provides flexibility for various monitoring protocols:

1. **Single Recording**: Manual capture of specific moments or events
2. **Auto Recording**: Continuous monitoring for extended periods (e.g., overnight sleep monitoring)

The recording parameters were carefully chosen based on HRV research standards:
- M minimum of 3 minutes: Ensures sufficient data capture for accurate frequency domain analysis
- M maximum of 5 minutes: Balances detail with practicality for frequent measurements
- N minimum of 2 minutes: Prevents excessive battery drain while maintaining temporal resolution
- N maximum of 10 minutes: Allows for extended monitoring without missing significant state changes

#### Contextual Tagging System

Each recording session is tagged with physiological context information to enable state-specific interpretation of HRV metrics:

| Tag | Description | Physiological State |
|-----|-------------|---------------------|
| **Sleep** | Nocturnal rest periods | Parasympathetic dominance, used for baseline establishment |
| **Rest** | Awake but passive (reading, watching) | Moderate parasympathetic activity |
| **Active** | Light physical activity (walking, cleaning) | Balanced autonomic activity |
| **Engaged** | Cognitive or physical effort (work, exercise) | Sympathetic dominance |
| **Experiment** | Custom interventions | User-defined protocols for personal exploration |

The tagging system is crucial because HRV metrics must be interpreted differently based on physiological context—what's "good" during sleep may be concerning during exercise, and vice versa.

#### Background Operation

The `BackgroundTaskManager` implements iOS background execution strategies to ensure continuous operation even when the app is not in the foreground:

- Registers background tasks with the system
- Implements task refresh cycles to prevent termination
- Maintains Bluetooth connections during background operation
- Ensures reliable data collection during overnight recordings

#### Data Flow Process

1. User configures recording parameters:
   - Sets M (recording duration)
   - Sets N (interval between recordings)
   - Selects appropriate contextual tag

2. User initiates recording:
   - For single recording: App records for M minutes, then processes and sends data
   - For auto recording: App records for M minutes, waits N minutes, then repeats

3. During each recording session:
   - RR intervals are collected from Polar H10
   - Motion artifacts are detected and flagged
   - Session metadata (timestamp, heart rate, device info) is compiled

4. At session completion:
   - Data is formatted as a structured JSON payload
   - Payload is transmitted to the API endpoint
   - Results are stored and session count is updated
   - If in auto-recording mode, timer for next session is initiated

```
Data Payload Example:
{
  "user_id": "user.email@example.com",
  "device_info": {
    "model": "Polar H10",
    "firmwareVersion": "2.1.9"
  },
  "recordingSessionId": "session_1234567890",
  "timestamp": "2025-03-27T09:30:00Z",
  "rrIntervals": [812, 805, 798, 790, ...],
  "heartRate": 74,
  "motionArtifacts": false,
  "tags": ["Sleep"]
}
```

This architecture ensures reliable, context-aware data collection while maintaining battery efficiency and maximizing user flexibility.

</details>

<details>
<summary><h2>HRV API & Processing Engine</h2></summary>

### Data Processing Pipeline

The API represents the analytical core of the platform, applying rigorous validation and scientific processing to raw HRV data. The processing pipeline encompasses several key stages:

#### 1. Signal Validation & Quality Assessment

To ensure scientific validity, the system applies a variety validation protocols:

##### RR Interval Range Filtering
- **Acceptable Range**: 300-2000ms
- **Physiological Basis**: 
  - <300ms (>200 BPM): Typically indicates ectopic beats or sensor noise
  - >2000ms (<30 BPM): Indicates extreme bradycardia or signal loss
- **Implementation**: Values outside range are flagged for removal

##### Statistical Outlier Detection
- **Method**: Z-score clipping (|z| > 3) or IQR-based outlier detection
- **Physiological Basis**: Identifies non-physiological jumps in heart rhythm
- **Implementation**: Configurable, defaults to z-score method

##### Motion Artifact Handling
- **Detection Source**: Polar H10 integrated accelerometer
- **Physiological Basis**: Movement creates muscle electrical activity that interferes with ECG signal
- **Implementation**: Sessions with detected motion can be flagged or rejected based on severity

##### Session Viability Criteria
For a recording session to be considered valid:
- Minimum 30 RR intervals required (ensures statistical significance)
- At least 90% of RR intervals must be within acceptable range
- Duration must be approximately 45-75 seconds (calculated from RR sum)

##### Quality Scoring
Each session receives a normalized quality score:
```python
quality_score = 1 - (num_outliers / total_rr)
```

Quality assessment categories:
- **Excellent**: >0.95 (Clean signal, high confidence)
- **Acceptable**: 0.80-0.95 (Minor noise, valid for all metrics)
- **Borderline**: 0.60-0.80 (Significant noise, use with caution)
- **Poor**: <0.60 (Invalid data, not suitable for analysis)

#### 2. HRV Metrics Calculation

Once data is validated, the system calculates the following essential metrics:

##### Time-Domain Metrics

| Metric | Formula | Implementation | Physiological Interpretation |
|--------|---------|----------------|------------------------------|
| **RMSSD** | √(mean[(RRₙ₊₁-RRₙ)²]) | `np.sqrt(np.mean(np.diff(rr)**2))` | Primary vagal tone indicator, reflects parasympathetic activity |
| **SDNN** | √(mean[(RRᵢ-mean(RR))²]) | `np.std(rr)` | Overall HRV, reflects total variability including sympathetic and parasympathetic components |
| **pNN50** | (count of intervals >50ms / total pairs) × 100 | `np.sum(np.abs(np.diff(rr)) > 50) / len(rr - 1) * 100` | Another measure of parasympathetic activity |
| **mean_rr** | mean(RR) | `np.mean(rr)` | Inverse of heart rate, reflects overall cardiac pacing |
| **cv_rr** | (SDNN / mean_rr) × 100 | `(np.std(rr) / np.mean(rr)) * 100` | Normalized measure of overall variability |

##### Frequency-Domain Metrics

| Metric | Method | Implementation | Physiological Interpretation |
|--------|--------|----------------|------------------------------|
| **lfPower** | Power in 0.04-0.15 Hz band | Lomb-Scargle periodogram | Mixed sympathetic and parasympathetic, baroreflex influence |
| **hfPower** | Power in 0.15-0.40 Hz band | Lomb-Scargle periodogram | Primarily parasympathetic activity, respiratory influence |
| **lfHfRatio** | lfPower / hfPower | Direct calculation | Often interpreted as sympathetic/parasympathetic balance |
| **breathingRate** | Peak frequency in HF band × 60 | Peak detection in HF band | Estimated respiratory rate, helps interpret autonomic dynamics |

The Lomb-Scargle periodogram is used instead of Fast Fourier Transform (FFT) because it handles unevenly sampled data (RR intervals) without requiring interpolation, maintaining signal integrity.

```python
# Frequency domain calculation (simplified)
from scipy.signal import lombscargle

def calculate_frequency_domain(rr_intervals):
    # Convert RR intervals to time series
    rr_times = np.cumsum(rr_intervals) / 1000  # convert to seconds
    rr_times = rr_times - rr_times[0]  # start at 0
    
    # Remove mean from the RR series
    rr_detrended = rr_intervals - np.mean(rr_intervals)
    
    # Define frequency range
    frequencies = np.linspace(0.01, 0.5, 1000)  # 0.01 to 0.5 Hz
    
    # Calculate Lomb-Scargle periodogram
    power = lombscargle(rr_times, rr_detrended, frequencies * 2 * np.pi)
    
    # Calculate power in specific bands
    lf_power = np.trapz(power[(frequencies >= 0.04) & (frequencies <= 0.15)])
    hf_power = np.trapz(power[(frequencies >= 0.15) & (frequencies <= 0.40)])
    lf_hf_ratio = lf_power / hf_power if hf_power > 0 else 0
    
    # Find breathing rate (peak in HF band)
    hf_mask = (frequencies >= 0.15) & (frequencies <= 0.40)
    if np.any(hf_mask):
        hf_peak = frequencies[hf_mask][np.argmax(power[hf_mask])]
        breathing_rate = hf_peak * 60  # convert to breaths per minute
    else:
        breathing_rate = None
    
    return {
        'lfPower': lf_power,
        'hfPower': hf_power,
        'lfHfRatio': lf_hf_ratio,
        'breathingRate': breathing_rate
    }
```

#### 3. Physiological Interpretation Models

The API implements interpretation groupings based on functional categories:

1. **Parasympathetic Indicators**: rmssd, pnn50, hfPower - Vagal activity markers
2. **Sympathetic Influence**: lfPower, lfHfRatio, HR - Stress response indicators
3. **Autonomic Balance**: sdnn, cv_rr, lfHfRatio - Overall nervous system coordination
4. **Respiratory Dynamics**: breathingRate, hfPower - Respiratory modulation of HRV
5. **Signal Quality Assessment**: quality_score, motion artifacts - Data reliability indicators

Each grouping has specific normative ranges and interpretation guidance based on the session's contextual tag, enabling physiologically appropriate insights.

#### 4. Data Storage and API Responses

The processed data is stored in a PostgreSQL database with a structured schema:

- **Sessions Table**: Records session metadata (timestamp, tag, quality metrics)
- **RR Intervals Table**: Stores raw and filtered RR intervals
- **Metrics Table**: Contains all calculated HRV metrics
- **Interpretation Table**: Stores derived interpretations and insights

API responses are structured to include:
- Status information (success/error, validation details)
- Session metadata (tags, timestamp, quality assessment)
- Calculated metrics (time-domain, frequency-domain)
- Interpretation groupings with contextual insights

This processing ensures scientifically valid HRV analysis with appropriate physiological context.

</details>

<details>
<summary><h2>HealthAssist Dashboard</h2></summary>

### Dashboard Architecture

The HealthAssist Dashboard provides a visualization and analysis platform for interpreting HRV data. It's designed as a modular system with the cardiovascular metrics module currently implemented and additional health domains planned for future integration.

#### Modular Design

The dashboard is structured with a tab-based interface that separates different analysis views:

1. **Record Summary**: Overview of all collected data with filtering and exploration tools
2. **Daily Analytics**: In-depth analysis of daily metrics with focus on night-time (sleep) recordings
3. **Trend Analysis**: Long-term pattern visualization with baseline development tracking

#### Night Metrics Analysis

The night metrics analysis is the cornerstone of the dashboard, leveraging sleep recordings to establish baselines and track recovery. Sleep is the "golden time" for HRV recording because:

1. Minimal motion artifacts and external stressors
2. Consistent physiological state for baseline comparison
3. Strong correlation between sleep HRV and overall health status

##### Night Metrics Calculation Methodology

For each night, the system:

1. **Identifies Sleep Records**: Extracts all records tagged with "Sleep" for the night
2. **Applies Temporal Filtering**: Groups by date and processes each night independently
3. **Calculates Consolidated Metrics**:
   - **Resting Heart Rate (RHR)**: Uses lowest 10th percentile of HR values during sleep
   - **HRV (RMSSD)**: Mean RMSSD during sleep period
   - **Sleep-Stage Approximation**: Applies algorithm to detect Deep, REM, and Light sleep based on HRV patterns
   - **Breathing Rate**: Mean breathing rate during sleep

```python
# Example of night metrics calculation (simplified)
def calculate_night_metrics(sleep_records):
    # Group by date
    sleep_by_date = sleep_records.groupby('date')
    
    night_metrics = []
    for date, day_records in sleep_by_date:
        # Get lowest 10% heart rate as RHR
        rhr = day_records['heartRate'].quantile(0.1)
        
        # Calculate mean HRV
        hrv = day_records['rmssd'].mean()
        
        # Calculate other metrics
        sdnn = day_records['sdnn'].mean()
        lf_hf = day_records['lfHfRatio'].mean()
        breathing_rate = day_records['breathingRate'].mean()
        
        # Calculate deep sleep approximation using lowest HR periods
        sws_records = extract_sws_periods(day_records)
        deep_sleep_hrv = sws_records['rmssd'].mean()
        
        night_metrics.append({
            'date': date,
            'rhr': rhr,
            'hrv': hrv,
            'sdnn': sdnn,
            'lf_hf': lf_hf,
            'breathing_rate': breathing_rate,
            'deep_sleep_hrv': deep_sleep_hrv
        })
    
    return pd.DataFrame(night_metrics)
```

##### Sleep Stage Detection Methodology

The dashboard implements a proprietary algorithm to approximate sleep stages from HRV data:

1. **Deep Sleep Detection**:
   - Filters for periods with lowest heart rate (bottom 20%)
   - Requires elevated HRV (top 30% of RMSSD)
   - Requires low LF/HF ratio (<1.0) indicating parasympathetic dominance

2. **REM Sleep Detection**:
   - Identifies periods with elevated heart rate (above mean)
   - Requires decreased HRV (bottom 30% of RMSSD)
   - Requires elevated LF/HF ratio (>2.0) indicating mixed autonomic activity

3. **Light Sleep**:
   - All remaining sleep periods that aren't classified as Deep or REM

This implementation approximates the commercial algorithms used in devices like Oura Ring and Whoop, which also derive sleep stages from autonomic nervous system dynamics rather than EEG readings.

#### Baseline Calculation System

The dashboard implements a sophisticated baseline calculation system to personalize interpretations:

##### Dynamic Baseline Methodology

Unlike static population norms, the system uses a rolling adaptive baseline that evolves as more data is collected:

1. **Initial Baseline**: First night's recordings serve as the initial baseline
2. **Accumulation Phase**: Baselines are recalculated daily incorporating all previous data
3. **Stabilization**: After approximately 14 days, baselines typically stabilize
4. **Contextual Weighting**: Sleep baselines use only sleep-tagged records

```python
def calculate_dynamic_baselines(df, days=14):
    # Get latest date in data
    latest_date = df['date'].max()
    cutoff_date = latest_date - timedelta(days=days)
    
    # Filter data for baseline period
    baseline_df = df[df['date'] >= cutoff_date]
    
    # Filter for sleep data
    sleep_data = baseline_df[baseline_df['tags'].apply(lambda x: 'Sleep' in x)]
    
    # Calculate baselines
    baselines = {}
    
    if not sleep_data.empty:
        # HRV baseline (median of values)
        baselines['hrv'] = sleep_data['rmssd'].median()
        
        # RHR baseline (mean of lowest 5% of values)
        baselines['rhr'] = sleep_data['heartRate'].quantile(0.05)
        
        # Breathing rate baseline
        baselines['breathing_rate'] = sleep_data['breathingRate'].median()
        
        # Other baselines...
    
    return baselines
```

##### Baseline Convergence Analysis

The dashboard tracks how quickly baselines stabilize through a convergence analysis:

1. Measures the difference between daily values and their evolving baselines
2. Normalizes these differences to track convergence over time
3. Provides a visualization of baseline stabilization to indicate when interpretations become reliable

#### Recovery Score Calculation

One of the most valuable features is the Recovery Score, which integrates multiple metrics to assess overall recovery status:

```python
def calculate_recovery_score(night_data, baselines):
    for i, row in night_data.iterrows():
        # Get required metrics
        rmssd = row['rmssd']
        rhr = row['rhr']
        duration = row['duration_minutes']
        lf_hf = row['lf_hf_ratio']
        
        # Get corresponding baselines
        baseline_rmssd = baselines.get('hrv', rmssd)
        baseline_rhr = baselines.get('rhr', rhr)
        
        # Component scores (0-1 scale)
        # HRV score: higher RMSSD = better recovery
        hrv_score = min(rmssd / baseline_rmssd, 1.2) if baseline_rmssd > 0 else 0.5
        
        # RHR score: lower HR = better recovery
        rhr_score = min(baseline_rhr / rhr, 1.2) if baseline_rhr > 0 and rhr > 0 else 0.5
        
        # Sleep quality components
        duration_score = min(duration / 420, 1.0)  # Cap at 7 hours
        lfhf_penalty = 1.0 if lf_hf < 2 else 0.8 if lf_hf < 4 else 0.5
        
        # Sleep quality score (0-100)
        sleep_quality = (
            0.4 * hrv_score +
            0.3 * (baseline_rhr / rhr if rhr > 0 else 0.5) +
            0.2 * duration_score +
            0.1 * lfhf_penalty
        ) * 100
        
        # Final recovery score (0-100)
        recovery_score = (
            0.5 * hrv_score +
            0.3 * rhr_score +
            0.2 * (sleep_quality / 100)
        ) * 100
        
        # Store results
        night_data.at[i, 'sleep_quality'] = round(sleep_quality, 1)
        night_data.at[i, 'recovery_score'] = round(recovery_score, 1)
```

The recovery score translates complex HRV data into actionable insights:
- **0-33**: Low recovery, focus on rest and rejuvenation
- **34-66**: Moderate recovery, maintain normal activity levels
- **67-100**: High recovery, optimal for training or performance

#### Stress Index Calculation

The dashboard also calculates a Stress Index to quantify autonomic nervous system load:

```python
def calculate_stress_index(hr, baseline_rhr, hrv, baseline_hrv):
    # Calculate HR component (0-1.5 scale)
    hr_ratio = hr / baseline_rhr
    hr_component = min(1.5, max(0, (hr_ratio - 0.8) * 2))
    
    # Calculate HRV component (0-1.5 scale, inverted)
    hrv_ratio = hrv / baseline_hrv
    hrv_component = min(1.5, max(0, (1 - hrv_ratio) * 2))
    
    # Combine components (0-3 scale)
    stress_index = hr_component + hrv_component
    
    return round(min(3.0, max(0.0, stress_index)), 1)
```

The stress index provides another perspective on autonomic balance:
- **0-0.8**: Low stress, parasympathetic dominance
- **0.8-1.8**: Moderate stress, balanced autonomic activity
- **1.8-3.0**: High stress, sympathetic dominance

These analytical features transform raw HRV data into meaningful health insights comparable to commercial systems like Whoop and Oura, while maintaining complete transparency about the underlying calculations.

</details>

<details>
<summary><h2>Device & Platform Comparisons</h2></summary>

### Comparative Analysis with Commercial Platforms

This project implements methodologies that align with commercial HRV monitoring platforms while providing complete transparency and customizability. Here's how key aspects compare:

#### HRV Measurement Methods

| Platform | Primary Metric | Recording Duration | Preferred Time | Key Advantage |
|----------|---------------|-------------------|----------------|---------------|
| **This Project** | RMSSD | 3-5 minutes | Sleep & Controlled test | Flexible recording protocol, raw data access |
| **Whoop** | RMSSD (branded as "recovery") | Variable (entire sleep) | Last SWS before waking | Continuous monitoring during sleep |
| **Apple Watch** | SDNN | 60 seconds | Passive recording | Convenience, integration with Health app |
| **Oura Ring** | RMSSD & HF power | Entire night | Full night analysis | Seamless nighttime measurement |

#### Sleep Stage Detection Comparison

| Platform | Deep Sleep Detection | REM Sleep Detection | Light Sleep Detection |
|----------|---------------------|---------------------|----------------------|
| **This Project** | HR ≤ 20th percentile<br>RMSSD ≥ 80th percentile<br>LF/HF < 1.0 | HR > mean<br>RMSSD ≤ 30th percentile<br>LF/HF > 2.0 | Remaining sleep periods |
| **Whoop** | Proprietary algorithm using HR deceleration + HRV elevation | Proprietary algorithm using respiratory rate + HR variability | Proprietary with HR volatility marker |
| **Apple Watch** | Motion + HR (accelerometer based) | Motion + HR variability | Accelerometer-based primarily |
| **Oura Ring** | HRV + temperature + motion | HR instability + temperature | Multiple signals with blackbox algorithm |

#### Recovery Score Calculation

| Platform | Primary Components | Scale | Uniqueness |
|----------|-------------------|-------|------------|
| **This Project** | HRV vs baseline (50%)<br>RHR vs baseline (30%)<br>Sleep quality (20%) | 0-100 | Fully transparent algorithm, customizable |
| **Whoop** | HRV (proprietary weighting)<br>RHR<br>Sleep quality & duration<br>Sleep debt | 0-100 | Includes prior day strain in calculation |
| **Apple Watch** | No dedicated recovery score | - | Focuses on "readiness" concept instead |
| **Oura Ring** | HRV, RHR, body temperature, sleep timing, previous activity | 0-100 | Includes temperature & sleep timing |

#### Uniqueness of This Platform

1. **Full Transparency**: Unlike commercial platforms, this project provides complete visibility into every algorithm and calculation.

2. **Raw Data Access**: Users have access to all raw RR intervals, enabling custom analyses and research.

3. **Contextual Tagging**: By implementing a rich tagging system, the platform provides context-appropriate HRV interpretation that most commercial platforms lack.

4. **Customizable Algorithms**: All analysis parameters can be modified to suit individual needs or research requirements.

5. **Continuous Improvement**: The open nature allows incorporation of the latest HRV research findings without waiting for commercial release cycles.

6. **Validation Metrics**: Quality scores and validation steps ensure scientific validity of all measurements.

7. **Dynamic Baseline Visualization**: Unique visualization of how baselines evolve over time helps users understand their adaptation process.

This project bridges the gap between consumer-grade HRV monitors with black-box algorithms and research-grade HRV analysis systems with prohibitive complexity. It provides scientific rigor with user-friendly interfaces while maintaining complete transparency.

</details>

<details>
<summary><h2>Scientific Foundations & Research Context</h2></summary>

### Heart Rate Variability Science

This project is built upon established scientific principles in the field of heart rate variability research. Here's an overview of the key scientific foundations:

#### Autonomic Nervous System Dynamics

HRV serves as a window into autonomic nervous system function:

- **Parasympathetic (Vagal) Influence**: Increases beat-to-beat variability through acetylcholine release from the vagus nerve, slowing the sinoatrial node
- **Sympathetic Influence**: Decreases variability through epinephrine and norepinephrine, accelerating the sinoatrial node
- **Respiratory Sinus Arrhythmia (RSA)**: Natural variation in heart rate that occurs during the breathing cycle, primarily regulated by vagal tone

These physiological mechanisms are why different HRV metrics provide insights into different aspects of nervous system function.

#### HRV Metrics Scientific Basis

The metrics implemented in this project reflect specific physiological processes:

- **RMSSD**: Quantifies high-frequency, beat-to-beat variability, primarily reflecting vagal tone and parasympathetic activity. Not significantly affected by respiratory influences, making it robust for short recordings.

- **SDNN**: Represents all cyclic components responsible for variability, including both sympathetic and parasympathetic influences. More affected by recording duration than RMSSD.

- **pNN50**: Another parasympathetic marker that measures the percentage of successive RR intervals that differ by more than 50ms, less commonly used in clinical research but included for completeness.

- **LF Power (0.04-0.15 Hz)**: Controversial metric with mixed contribution from sympathetic, parasympathetic, and baroreflex activity. Most valuable when assessed alongside other metrics.

- **HF Power (0.15-0.40 Hz)**: Predominantly reflects parasympathetic activity associated with respiratory frequency.

- **LF/HF Ratio**: Originally proposed as a sympathovagal balance marker, now understood to be more complex. Still useful for within-subject comparisons but requires careful interpretation.

Research has consistently shown that these metrics provide valuable insights into autonomic regulation when properly contextualized.

#### Sleep and Recovery Science

The project's focus on nighttime recordings aligns with research showing that sleep represents the optimal window for HRV assessment:

- **Parasympathetic Dominance**: Sleep, particularly deep sleep, is characterized by parasympathetic dominance and sympathetic withdrawal
- **Circadian Influence**: HRV follows circadian patterns, with highest values typically occurring during deep sleep
- **Recovery Processes**: Key physiological recovery processes (hormonal, neural, immunological) occur during sleep and are reflected in HRV patterns
- **Research Validity**: Sleep-based HRV measures show stronger correlations with health outcomes than daytime measures in multiple studies

The sleep stage approximation implemented in this project is based on autonomic nervous system patterns associated with different sleep stages:

- **Deep Sleep (SWS)**: Characterized by parasympathetic dominance, high HRV, and low, stable heart rate
- **REM Sleep**: Features mixed autonomic activity with occasional sympathetic bursts
- **Light Sleep**: Shows intermediate HRV with transitional autonomic patterns

These patterns allow for reasonable sleep stage approximation through HRV analysis alone, though not as accurate as polysomnography with EEG.

#### References

The algorithms and interpretations in this project are informed by key research in the field:

1. Task Force of the European Society of Cardiology and the North American Society of Pacing and Electrophysiology. (1996). Heart rate variability: standards of measurement, physiological interpretation and clinical use. Circulation, 93(5), 1043-1065.

2. Shaffer, F., & Ginsberg, J. P. (2017). An overview of heart rate variability metrics and norms. Frontiers in public health, 5, 258.

3. Buchheit, M. (2014). Monitoring training status with HR measures: do all roads lead to Rome? Frontiers in physiology, 5, 73.

4. Kleiger, R. E., Stein, P. K., & Bigger Jr, J. T. (2005). Heart rate variability: measurement and clinical utility. Annals of Noninvasive Electrocardiology, 10(1), 88-101.

5. Herzig, D., Testorelli, M., Olstad, D. S., Erlacher, D., Achermann, P., Eser, P., & Wilhelm, M. (2017). Heart-rate variability during deep sleep in world-class alpine skiers: a time-efficient alternative to morning orthostatic heart-rate measurements. International journal of sports physiology and performance, 12(5), 648-654.

This project strives to maintain alignment with current scientific understanding while implementing practical solutions for daily HRV monitoring and interpretation.

</details>

<details>
<summary><h2>Technical Implementation</h2></summary>

### Project Structure & Implementation Details

The project is organized into three main components with specific technical implementations:

#### iOS App Implementation

The iOS app is built with Swift and SwiftUI, leveraging several key frameworks:

- **Core Bluetooth**: For BLE communication with Polar H10
- **Combine**: For reactive programming patterns
- **SwiftUI**: For the modern declarative UI
- **Core Foundation**: For background task management

Key classes and their responsibilities:

```
├── Managers
│   ├── BluetoothManager.swift    # BLE connection and data handling
│   ├── RecordingManager.swift    # Recording session management
│   ├── BackgroundTaskManager.swift  # Background operation handling
│   └── UserManager.swift         # User authentication
├── Services
│   └── APIService.swift          # API communication
└── Views
    └── ContentView.swift         # Main UI components
```

The app implements several iOS-specific optimizations:

- Background mode configurations in Info.plist
- Battery optimization techniques
- Proper BLE connection state management
- Error handling and reconnection logic

#### API Implementation

The API is built with Python using FastAPI framework and SQLAlchemy ORM:

```
├── app
│   ├── api
│   │   └── session_handler.py    # API endpoints for session management
│   ├── core
│   │   ├── processor.py          # Core HRV calculation engine
│   │   ├── validator.py          # Signal validation functions
│   │   ├── metrics.py            # HRV metrics implementation
│   │   └── indexes.py            # Metric categorization
│   ├── models
│   │   ├── schemas.py            # Pydantic schemas for validation
│   │   ├── session.py            # Session data models
│   │   └── sql_models.py         # SQLAlchemy database models
│   └── constants
│       └── interpretations.py    # Metric interpretation constants
```

#### Contact
Created by - Atriom Circle, Applied Intelligence Practice - For questions or support, please contact: [a.beheshti@posteo.de](mailto:a.beheshti@posteo.de)
