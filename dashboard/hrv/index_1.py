import streamlit as st
import pandas as pd
import numpy as np
import plotly.express as px
import plotly.graph_objects as go
from sqlalchemy import create_engine, text
from datetime import datetime, timedelta
import io
from PIL import Image
import matplotlib.pyplot as plt
import pytz

# Database connection
def get_db_engine():
    """Create and return a database engine."""
    try:
        DATABASE_URL = "postgresql://ashkan:qQdSL2BnknLZ3JUn8fcJCZ49fY6aRyKn@dpg-cvhtllqqgecs73d4r9a0-a.frankfurt-postgres.render.com/hrv_records_db"
        engine = create_engine(DATABASE_URL)
        # Test connection
        with engine.connect() as conn:
            conn.execute(text("SELECT 1"))
        return engine, None
    except Exception as e:
        return None, str(e)

def get_hrv_data():
    """Fetch HRV data from the database."""
    engine, error = get_db_engine()
    if error:
        st.error(f"Database connection error: {error}")
        return pd.DataFrame()
    
    query_text = """
    SELECT 
        s.timestamp,
        s.recording_session_id as "recordingSessionId",
        s.heart_rate as "heartRate",
        m.mean_rr,
        m.sdnn,
        m.rmssd,
        m.pnn50,
        m.cv_rr,
        m.rr_count,
        m.lf_power as "lfPower",
        m.hf_power as "hfPower",
        m.lf_hf_ratio as "lfHfRatio",
        m.breathing_rate as "breathingRate",
        s.valid_rr_percentage,
        s.quality_score,
        s.outlier_count,
        s.filter_method,
        s.valid,
        array_agg(t.name) as tags
    FROM 
        hrv_sessions s
    LEFT JOIN 
        hrv_metrics m ON s.id = m.session_id
    LEFT JOIN 
        session_tags st ON s.id = st.session_id
    LEFT JOIN 
        tags t ON st.tag_id = t.id
    GROUP BY 
        s.id, s.timestamp, s.recording_session_id, s.heart_rate, m.mean_rr, m.sdnn, m.rmssd, 
        m.pnn50, m.cv_rr, m.rr_count, m.lf_power, m.hf_power, m.lf_hf_ratio, m.breathing_rate,
        s.valid_rr_percentage, s.quality_score, s.outlier_count, s.filter_method, s.valid
    ORDER BY 
        s.timestamp DESC
    """
    
    try:
        query = text(query_text)
        with engine.connect() as conn:
            df = pd.read_sql_query(query, conn)
            
            # Format timestamp
            df['timestamp'] = pd.to_datetime(df['timestamp'], utc=True)
            
            # Convert UTC timestamps to Berlin timezone
            berlin_tz = pytz.timezone('Europe/Berlin')
            df['timestamp'] = df['timestamp'].dt.tz_convert(berlin_tz)
            
            # Extract date for date-based analysis
            df['date'] = df['timestamp'].dt.date
            
            return df
    except Exception as e:
        st.error(f"Error fetching HRV data: {str(e)}")
        return pd.DataFrame()

def calculate_night_metrics(df):
    """
    Calculate night metrics from Sleep data.
    """
    sleep_df = df[df['tags'].apply(lambda x: 'Sleep' in x if isinstance(x, list) else False)]
    
    if sleep_df.empty:
        return pd.DataFrame()
        
    # Group by date
    sleep_df['date'] = sleep_df['timestamp'].dt.date
    sleep_grouped = sleep_df.groupby('date')
    
    # Create night metrics
    night_metrics = []
    
    for date, group in sleep_grouped:
        # For each night, calculate consolidated metrics
        mean_rr = group['mean_rr'].mean()
        mean_hr = 60000 / mean_rr if not pd.isna(mean_rr) and mean_rr > 0 else np.nan
        
        # Use lowest 10th percentile for RHR
        if len(group) >= 3:
            rhr = group['heartRate'].quantile(0.1)
        else:
            rhr = group['heartRate'].min()
            
        # HRV metrics
        sdnn = group['sdnn'].mean()
        rmssd = group['rmssd'].mean()
        pnn50 = group['pnn50'].mean()
        cv_rr = group['cv_rr'].mean()
        
        # Frequency domain metrics
        lf_power = group['lfPower'].mean()
        hf_power = group['hfPower'].mean()
        lf_hf_ratio = group['lfHfRatio'].mean()
        breathing_rate = group['breathingRate'].mean()
        
        # Quality metrics
        session_quality = group['quality_score'].mean()
        
        # Calculate duration in minutes
        # Calculate actual sleep duration from timestamps
        start_time = group['timestamp'].min()
        end_time = group['timestamp'].max()
        duration_minutes = (end_time - start_time).total_seconds() / 60.0
        
        # Add to night metrics list
        night_metrics.append({
            'date': date,
            'mean_rr': mean_rr,
            'sdnn': sdnn,
            'rmssd': rmssd,
            'pnn50': pnn50,
            'cv_rr': cv_rr,
            'lf_power': lf_power,
            'hf_power': hf_power,
            'lf_hf_ratio': lf_hf_ratio,
            'breathing_rate': breathing_rate,
            'mean_hr': mean_hr,
            'rhr': rhr,
            'session_quality': session_quality,
            'record_count': len(group),
            'duration_minutes': duration_minutes
        })
    
    # Create night data DataFrame
    night_data = pd.DataFrame(night_metrics)
    
    return night_data

def calculate_baselines(df, days=14):
    """Calculate baseline metrics from the last N days."""
    if df.empty:
        return {}
    
    # Get latest date in the data
    latest_date = df['date'].max()
    cutoff_date = latest_date - timedelta(days=days)
    
    # Filter data for baseline period
    baseline_df = df[df['date'] >= cutoff_date]
    
    # Get sleep sessions
    sleep_sessions = baseline_df[baseline_df['tags'].apply(
        lambda x: 'Sleep' in x if isinstance(x, list) else False
    )]
    
    # Calculate sleep baselines
    baselines = {}
    
    if not sleep_sessions.empty:
        # HRV baseline (median of rmssd values)
        baselines['hrv'] = sleep_sessions['rmssd'].median()
        
        # RHR baseline (mean of lowest 5 rhr values)
        baselines['rhr'] = sleep_sessions['heartRate'].quantile(0.1)
        
        # SDNN baseline
        baselines['sdnn'] = sleep_sessions['sdnn'].median()
        
        # Breathing rate baseline
        baselines['breathing_rate'] = sleep_sessions['breathingRate'].median()
        
        # Heart rate baseline (all records)
        baselines['hr'] = baseline_df['heartRate'].mean()
        
        # LF/HF baseline
        baselines['lf_hf_ratio'] = sleep_sessions['lfHfRatio'].median()
    
    return baselines

def calculate_recovery_score(night_data, baselines):
    if night_data.empty or not baselines:
        return night_data

    night_data_with_recovery = night_data.copy()
    night_data_with_recovery['recovery_score'] = np.nan

    for i, row in night_data_with_recovery.iterrows():
        # ----- Safe defaults -----
        rmssd = row.get('rmssd', np.nan)
        rhr = row.get('rhr', np.nan)
        avg_hr = row.get('mean_hr', np.nan)
        duration = row.get('duration_minutes', 0)
        lf_hf = row.get('lf_hf_ratio', np.nan)

        baseline_rmssd = baselines.get('hrv', rmssd)
        baseline_rhr = baselines.get('rhr', rhr)
        baseline_hr = baselines.get('hr', avg_hr)

        # ----- Score Components -----

        # HRV Score
        hrv_score = min(rmssd / baseline_rmssd, 1.0) if baseline_rmssd > 0 and rmssd > 0 else 0.5

        # RHR Score
        rhr_score = min(baseline_rhr / rhr, 1.0) if baseline_rhr > 0 and rhr > 0 else 0.5

        # Sleep Quality Components
        rmssd_score = hrv_score
        hr_drop_score = (baseline_hr - avg_hr) / baseline_hr if baseline_hr > 0 else 0
        duration_score = min(duration / 420, 1.0)  # 7h max
        lfhf_penalty = 1.0 if lf_hf < 2 else 0.8 if lf_hf < 4 else 0.5

        sleep_quality = (
            0.4 * rmssd_score +
            0.3 * hr_drop_score +
            0.2 * duration_score +
            0.1 * lfhf_penalty
        ) * 100

        # Cap at [0, 100]
        sleep_quality = max(0, min(100, sleep_quality))

        # Final Recovery Score (scaled to 100)
        recovery_score = (
            0.5 * hrv_score +
            0.3 * rhr_score +
            0.2 * (sleep_quality / 100)
        ) * 100

        recovery_score = max(0, min(100, recovery_score))

        # Store results
        night_data_with_recovery.at[i, 'sleep_quality'] = round(sleep_quality, 1)
        night_data_with_recovery.at[i, 'recovery_score'] = round(recovery_score, 1)

    return night_data_with_recovery

def detect_sleep_stages(sleep_df):
    """
    Detect sleep stages for sleep records.
    
    Args:
        sleep_df: DataFrame with sleep records
        
    Returns:
        DataFrame with sleep stage labels
    """
    if sleep_df.empty:
        return sleep_df
    
    # Calculate percentiles for this night
    hr_percentiles = sleep_df['heartRate'].quantile([0.2, 0.5, 0.8])
    rmssd_percentiles = sleep_df['rmssd'].quantile([0.3, 0.5, 0.8])
    mean_hr = sleep_df['heartRate'].mean()
    
    # Copy the dataframe to avoid modifying the original
    result_df = sleep_df.copy()
    
    # Apply sleep stage detection
    stages = []
    
    for _, row in result_df.iterrows():
        hr = row['heartRate']
        rmssd = row['rmssd']
        lf_hf = row['lfHfRatio']
        
        # Skip if missing values
        if pd.isna(hr) or pd.isna(rmssd) or pd.isna(lf_hf):
            stages.append('Unknown')
            continue
        
        # Deep Sleep criteria
        if (hr <= hr_percentiles[0.2] and
            rmssd >= rmssd_percentiles[0.8] and
            lf_hf < 1.0):
            stages.append('Deep')
        # REM Sleep criteria
        elif (hr > mean_hr and
              rmssd <= rmssd_percentiles[0.3] and
              lf_hf > 2.0):
            stages.append('REM')
        # Everything else = Light
        else:
            stages.append('Light')
    
    result_df['sleep_stage'] = stages
    
    return result_df

def create_daily_report(night_data, baselines):
    """
    Create a daily report for the latest day.
    
    Args:
        night_data: DataFrame with night metrics
        baselines: Dict with baseline values
        
    Returns:
        Dict with daily report data
    """
    if night_data.empty:
        return {}
    
    # Get latest day
    latest_day = night_data.sort_values('date', ascending=False).iloc[0]
    
    # Format date
    date_str = latest_day['date'].strftime('%Y-%m-%d')
    
    # Create report
    report = {
        "date": date_str,
        "hr": {
            "value": round(latest_day['mean_hr'] if not pd.isna(latest_day['mean_hr']) else 0, 1),
            "baseline": round(baselines.get('hr', 0), 1),
            "change": f"{(latest_day['mean_hr'] / baselines.get('hr', 1) - 1) * 100:.1f}%" if not pd.isna(latest_day['mean_hr']) and baselines.get('hr', 0) > 0 else "N/A"
        },
        "hrv": {
            "rmssd": round(latest_day['rmssd'] if not pd.isna(latest_day['rmssd']) else 0, 1),
            "baseline": round(baselines.get('hrv', 0), 1),
            "score": round(latest_day['rmssd'] / baselines.get('hrv', 1) if not pd.isna(latest_day['rmssd']) and baselines.get('hrv', 0) > 0 else 0, 2)
        },
        "rhr": {
            "value": round(latest_day['rhr'] if not pd.isna(latest_day['rhr']) else 0, 1),
            "baseline": round(baselines.get('rhr', 0), 1),
            "score": round(baselines.get('rhr', 0) / latest_day['rhr'] if not pd.isna(latest_day['rhr']) and latest_day['rhr'] > 0 else 0, 2)
        },
        "breathing_rate": {
            "value": round(latest_day['breathing_rate'] if not pd.isna(latest_day['breathing_rate']) else 0, 1),
            "baseline": round(baselines.get('breathing_rate', 0), 1)
        },
        "recovery_score": round(latest_day['recovery_score'] if 'recovery_score' in latest_day and not pd.isna(latest_day['recovery_score']) else 0, 1),
        "sleep_quality": round(latest_day['sleep_quality'] if 'sleep_quality' in latest_day and not pd.isna(latest_day['sleep_quality']) else 0, 1),
        "sleep_duration": int(latest_day['duration_minutes']),
    }
    
    return report

def generate_color_label(value, thresholds, colors):
    """Generate color and label based on thresholds."""
    if value is None or pd.isna(value):
        return colors[-1], "Unknown"
    
    for i, threshold in enumerate(thresholds):
        if value < threshold:
            return colors[i], ["Low", "Moderate", "High"][i]
    
    return colors[-1], "High"

def main():
    """Main function for the Analytics tab."""
    st.title("Daily HRV Analytics")
    
    # Data loading section
    with st.spinner("Loading data..."):
        df = get_hrv_data()
        
        if df.empty:
            st.error("No data found in database. Please check your connection or data availability.")
            return
    
    # Calculate night metrics from Sleep data
    night_data = calculate_night_metrics(df)
    
    if night_data.empty:
        st.warning("No sleep data found. Please tag some records with 'Sleep' tag.")
        return
    
    # Calculate baselines
    baselines = calculate_baselines(df)
    
    # Calculate recovery scores
    night_data = calculate_recovery_score(night_data, baselines)
    
    # Create daily report
    daily_report = create_daily_report(night_data, baselines)
    
    # Daily Report Section
    st.header("📊 Daily Report")
    
    # Display latest day metrics
    if daily_report:
        date_str = daily_report['date']
        
        st.subheader(f"Daily Report for {date_str}")
        
        # Create metrics layout
        col1, col2, col3 = st.columns(3)
        
        # Recovery Score
        with col1:
            recovery_score = daily_report['recovery_score']
            recovery_color, recovery_category = generate_color_label(
                recovery_score, 
                [33, 67], 
                ["#d9534f", "#f0ad4e", "#5cb85c"]
            )
            
            st.metric(
                "Recovery Score", 
                f"{recovery_score:.1f}",
                delta=f"{recovery_score - 50:.1f}" if recovery_score > 0 else None
            )
            
            st.markdown(
                f"<div style='background-color: {recovery_color}; color: white; padding: 5px; border-radius: 5px; text-align: center;'>"
                f"Recovery: {recovery_category}"
                f"</div>",
                unsafe_allow_html=True
            )
        
        # HRV
        with col2:
            rmssd = daily_report['hrv']['rmssd']
            baseline_hrv = daily_report['hrv']['baseline']
            
            st.metric(
                "HRV (RMSSD)", 
                f"{rmssd:.1f} ms",
                delta=f"{rmssd - baseline_hrv:.1f} ms" if baseline_hrv > 0 else None
            )
            
            # Add baseline comparison
            st.markdown(f"Baseline: {baseline_hrv:.1f} ms")
        
        # RHR
        with col3:
            rhr = daily_report['rhr']['value']
            baseline_rhr = daily_report['rhr']['baseline']
            
            st.metric(
                "Resting Heart Rate", 
                f"{rhr:.1f} bpm",
                delta=f"{baseline_rhr - rhr:.1f} bpm" if baseline_rhr > 0 else None,
                delta_color="inverse"
            )
            
            # Add baseline comparison
            st.markdown(f"Baseline: {baseline_rhr:.1f} bpm")
        
        # Second row of metrics
        col4, col5 = st.columns(2)
        
        # Sleep Quality
        with col4:
            sleep_quality = daily_report['sleep_quality']
            quality_color, quality_category = generate_color_label(
                sleep_quality, 
                [40, 80], 
                ["#d9534f", "#f0ad4e", "#5cb85c"]
            )
            
            if quality_category == "Low":
                quality_label = "Poor"
            elif quality_category == "Moderate":
                quality_label = "Fair"
            else:
                quality_label = "Good"
            
            st.metric(
                "Sleep Quality", 
                f"{sleep_quality:.1f}",
                delta=f"{sleep_quality - 50:.1f}" if sleep_quality > 0 else None
            )
            
            st.markdown(
                f"<div style='background-color: {quality_color}; color: white; padding: 5px; border-radius: 5px; text-align: center;'>"
                f"Quality: {quality_label}"
                f"</div>",
                unsafe_allow_html=True
            )
        
        # Breathing Rate
        with col5:
            breathing_rate = daily_report['breathing_rate']['value']
            baseline_br = daily_report['breathing_rate']['baseline']
            
            st.metric(
                "Breathing Rate", 
                f"{breathing_rate:.1f} br/min",
                delta=f"{breathing_rate - baseline_br:.1f} br/min" if baseline_br > 0 else None
            )
            
            # Add breathing rate status
            if breathing_rate < 12:
                br_status = "Hypoventilation"
            elif breathing_rate <= 16:
                br_status = "Optimal"
            elif breathing_rate <= 18:
                br_status = "Elevated"
            else:
                br_status = "Very Elevated"
            
            st.markdown(f"Status: {br_status} (Baseline: {baseline_br:.1f} br/min)")
    
    # HRV Metrics Summary
    st.header("📈 Night Metrics Summary Statistics")
    
    if not night_data.empty:
        # Summary statistics
        summary_stats = night_data[['rmssd', 'sdnn', 'rhr', 'breathing_rate']].describe()
        summary_stats = summary_stats.round(4)
        
        # Display summary statistics
        st.dataframe(summary_stats, use_container_width=True)
        
        # Display baseline metrics
        st.subheader("Baseline Metrics (14-day rolling)")
        
        baseline_markdown = f"""
        - Baseline HRV (RMSSD): **{baselines.get('hrv', 'N/A'):.2f} ms**
        - Baseline RHR: **{baselines.get('rhr', 'N/A'):.2f} bpm**
        - Baseline HR: **{baselines.get('hr', 'N/A'):.2f} bpm**
        - Baseline Breathing Rate: **{baselines.get('breathing_rate', 'N/A'):.2f} breaths/min**
        - Baseline LF/HF Ratio: **{baselines.get('lf_hf_ratio', 'N/A'):.2f}**
        - Baseline SDNN: **{baselines.get('sdnn', 'N/A'):.2f} ms**
        """
        
        st.markdown(baseline_markdown)
    
    # HRV Trend Analysis
    st.header("📊 HRV Trend Analysis")
    
    if len(night_data) >= 2:
        # Sort by date
        night_data_sorted = night_data.sort_values('date')
        
        # Create trend charts
        # HRV trend
        fig1 = go.Figure()
        
        fig1.add_trace(go.Scatter(
            x=night_data_sorted['date'],
            y=night_data_sorted['rmssd'],
            mode='lines+markers',
            name='RMSSD',
            line=dict(color='royalblue', width=2),
            marker=dict(size=8)
        ))
        
        # Add baseline
        if 'hrv' in baselines:
            fig1.add_shape(
                type="line",
                x0=night_data_sorted['date'].min(),
                y0=baselines['hrv'],
                x1=night_data_sorted['date'].max(),
                y1=baselines['hrv'],
                line=dict(color="red", width=2, dash="dash"),
            )
        
        fig1.update_layout(
            title="HRV (RMSSD) Trend",
            xaxis_title="Date",
            yaxis_title="RMSSD (ms)",
            height=300,
            margin=dict(l=20, r=20, t=40, b=20),
        )
        
        st.plotly_chart(fig1, use_container_width=True)
        
        # RHR trend
        fig2 = go.Figure()
        
        fig2.add_trace(go.Scatter(
            x=night_data_sorted['date'],
            y=night_data_sorted['rhr'],
            mode='lines+markers',
            name='RHR',
            line=dict(color='forestgreen', width=2),
            marker=dict(size=8)
        ))
        
        # Add baseline
        if 'rhr' in baselines:
            fig2.add_shape(
                type="line",
                x0=night_data_sorted['date'].min(),
                y0=baselines['rhr'],
                x1=night_data_sorted['date'].max(),
                y1=baselines['rhr'],
                line=dict(color="red", width=2, dash="dash"),
            )
        
        fig2.update_layout(
            title="Resting Heart Rate Trend",
            xaxis_title="Date",
            yaxis_title="RHR (bpm)",
            height=300,
            margin=dict(l=20, r=20, t=40, b=20),
        )
        
        st.plotly_chart(fig2, use_container_width=True)
        
        # Recovery score trend
        if 'recovery_score' in night_data_sorted.columns:
            fig3 = go.Figure()
            
            fig3.add_trace(go.Scatter(
                x=night_data_sorted['date'],
                y=night_data_sorted['recovery_score'],
                mode='lines+markers',
                name='Recovery Score',
                line=dict(color='purple', width=2),
                marker=dict(size=8)
            ))
            
            # Add threshold lines
            fig3.add_shape(
                type="line",
                x0=night_data_sorted['date'].min(),
                y0=33,
                x1=night_data_sorted['date'].max(),
                y1=33,
                line=dict(color="orange", width=2, dash="dash"),
            )
            
            fig3.add_shape(
                type="line",
                x0=night_data_sorted['date'].min(),
                y0=67,
                x1=night_data_sorted['date'].max(),
                y1=67,
                line=dict(color="green", width=2, dash="dash"),
            )
            
            fig3.update_layout(
                title="Recovery Score Trend",
                xaxis_title="Date",
                yaxis_title="Recovery Score",
                height=300,
                margin=dict(l=20, r=20, t=40, b=20),
            )
            
            st.plotly_chart(fig3, use_container_width=True)
    else:
        st.info("Not enough data for trend analysis. At least 2 nights of data required.")
    
    # Sleep Analysis
    st.header("🌙 Sleep Analysis")
    
    # Get the latest sleep data
    latest_sleep_date = night_data['date'].max()
    sleep_records = df[(df['date'] == latest_sleep_date) & 
                      df['tags'].apply(lambda x: 'Sleep' in x if isinstance(x, list) else False)]
    
    if not sleep_records.empty:
        # Detect sleep stages
        sleep_with_stages = detect_sleep_stages(sleep_records)
        
        # Calculate stage durations
        stage_counts = sleep_with_stages['sleep_stage'].value_counts()
        
        # Calculate total duration using timestamps
        start_time = sleep_with_stages['timestamp'].min()
        end_time = sleep_with_stages['timestamp'].max()
        total_minutes = round((end_time - start_time).total_seconds() / 60.0, 1)

        # Count total stages
        total_stage_counts = stage_counts.sum()
        if total_stage_counts > 0:
            deep_pct_raw = stage_counts.get('Deep', 0) / total_stage_counts
            rem_pct_raw = stage_counts.get('REM', 0) / total_stage_counts
            light_pct_raw = stage_counts.get('Light', 0) / total_stage_counts
        else:
            deep_pct_raw = rem_pct_raw = light_pct_raw = 0.0

        # Scale actual duration proportionally and round
        deep_minutes = round(total_minutes * deep_pct_raw, 1)
        rem_minutes = round(total_minutes * rem_pct_raw, 1)
        light_minutes = round(total_minutes * light_pct_raw, 1)

        # Calculate percentages and round
        deep_pct = round((deep_minutes / total_minutes) * 100, 1) if total_minutes > 0 else 0.0
        rem_pct = round((rem_minutes / total_minutes) * 100, 1) if total_minutes > 0 else 0.0
        light_pct = round((light_minutes / total_minutes) * 100, 1) if total_minutes > 0 else 0.0

        # Display sleep summary
        st.subheader(f"Sleep Summary for {latest_sleep_date}")

        # Sleep duration in hours
        duration_hours = round(total_minutes / 60.0, 1)
        
        col1, col2 = st.columns(2)
        
        with col1:
            # Determine duration color
            if duration_hours >= 7:
                duration_color = "green"
            elif duration_hours >= 6:
                duration_color = "orange"
            else:
                duration_color = "red"
                
            st.markdown(
                f"<div style='background-color: {duration_color}; color: white; padding: 10px; border-radius: 5px; text-align: center;'>"
                f"Sleep Duration: {duration_hours:.1f} hours ({total_minutes} minutes)"
                f"</div>",
                unsafe_allow_html=True
            )
        
        with col2:
            # Create pie chart for sleep stages
            fig = go.Figure(data=[go.Pie(
                labels=['Deep', 'REM', 'Light'],
                values=[deep_pct, rem_pct, light_pct],
                hole=.3,
                marker_colors=['#3366CC', '#DC3912', '#FF9900']
            )])
            
            fig.update_layout(
                title="Sleep Stages (%)",
                height=250,
                margin=dict(l=20, r=20, t=30, b=20),
            )
            
            st.plotly_chart(fig, use_container_width=True)
        
        # Sleep stage minutes
        st.markdown(
            f"<div style='display: flex; justify-content: space-around; text-align: center; margin: 10px 0;'>"
            f"<div><b>Deep Sleep:</b> {deep_minutes} min ({deep_pct:.1f}%)</div>"
            f"<div><b>REM Sleep:</b> {rem_minutes} min ({rem_pct:.1f}%)</div>"
            f"<div><b>Light Sleep:</b> {light_minutes} min ({light_pct:.1f}%)</div>"
            f"</div>",
            unsafe_allow_html=True
        )
        
        # Sleep Quality Components
        st.subheader("Sleep Quality Components")
        
        # Get required values
        rmssd = night_data[night_data['date'] == latest_sleep_date]['rmssd'].iloc[0]
        avg_hr = night_data[night_data['date'] == latest_sleep_date]['mean_hr'].iloc[0]
        duration = night_data[night_data['date'] == latest_sleep_date]['duration_minutes'].iloc[0]
        lf_hf_ratio = night_data[night_data['date'] == latest_sleep_date]['lf_hf_ratio'].iloc[0]
        
        # Calculate component contributions
        baseline_rmssd = baselines.get('hrv', rmssd)
        baseline_hr = baselines.get('hr', avg_hr)
        
        rmssd_score = min(rmssd / baseline_rmssd, 1.2) if baseline_rmssd > 0 else 0.5
        hr_drop_score = (baseline_hr - avg_hr) / baseline_hr if baseline_hr > 0 else 0.5
        duration_score = min(duration / 420, 1.0)  # max 7h
        lfhf_penalty = 1.0 if lf_hf_ratio < 2 else 0.8 if lf_hf_ratio < 4 else 0.5
        
        # Create bar chart for component weights
        comp_fig = go.Figure()
        
        comp_fig.add_trace(go.Bar(
            x=['HRV (RMSSD)', 'HR Drop', 'Duration', 'LF/HF Ratio'],
            y=[rmssd_score * 0.4 * 100, hr_drop_score * 0.3 * 100, duration_score * 0.2 * 100, lfhf_penalty * 0.1 * 100],
            text=[f"{rmssd_score * 0.4 * 100:.1f}%", f"{hr_drop_score * 0.3 * 100:.1f}%", 
                  f"{duration_score * 0.2 * 100:.1f}%", f"{lfhf_penalty * 0.1 * 100:.1f}%"],
            textposition='auto',
            marker_color=['royalblue', 'forestgreen', 'orange', 'purple']
        ))
        
        comp_fig.update_layout(
            title="Sleep Quality Component Contribution",
            xaxis_title="Component",
            yaxis_title="Contribution to Quality Score (%)",
            height=350,
            margin=dict(l=20, r=20, t=40, b=20),
        )
        
        st.plotly_chart(comp_fig, use_container_width=True)
        
        # Component explanation
        st.markdown("""
        ### Sleep Quality Component Explanation
        
        The sleep quality score is calculated from four components:
        
        1. **HRV (RMSSD)** - 40% weight: Measures parasympathetic nervous system activity during sleep
        2. **Heart Rate Drop** - 30% weight: How much your heart rate decreases from your daytime baseline
        3. **Sleep Duration** - 20% weight: Total time spent sleeping (capped at 7 hours)
        4. **LF/HF Ratio** - 10% weight: Balance between sympathetic and parasympathetic activity
        
        The formula is:
        ```
        rmssd_score = min(rmssd / baseline_rmssd, 1.2)
        hr_drop_score = (baseline_hr - avg_hr) / baseline_hr
        duration_score = min(sleep_duration / 420, 1.0)
        lfhf_penalty = 1.0 if lfhf < 2 else 0.8 if lfhf < 4 else 0.5
        
        sleep_quality = (
            0.4 * rmssd_score +
            0.3 * hr_drop_score +
            0.2 * duration_score +
            0.1 * lfhf_penalty
        ) * 100
        ```
        """)
    # Weekly Sleep Trends
    st.subheader("Weekly Sleep Trends")

    # Filter data for the past week
    week_ago = latest_sleep_date - timedelta(days=6)  # Get data for last 7 days
    weekly_sleep_df = night_data[(night_data['date'] >= week_ago) & (night_data['date'] <= latest_sleep_date)]

    if not weekly_sleep_df.empty and len(weekly_sleep_df) > 0:
        # Get all dates in the past week
        all_dates = [latest_sleep_date - timedelta(days=i) for i in range(6, -1, -1)]
        date_labels = [d.strftime('%a<br>%d') for d in all_dates]  # Format: "Mon<br>24"
        
        # Initialize data
        deep_durations = []
        rem_durations = []
        light_durations = []
        visible_dates = []
        
        # Get sleep stage durations for each date
        for date in all_dates:
            # Check if we have data for this date
            date_sleep = df[(df['date'] == date) & 
                        df['tags'].apply(lambda x: 'Sleep' in x if isinstance(x, list) else False)]
            
            if not date_sleep.empty:
                # Detect sleep stages for this date
                date_sleep_with_stages = detect_sleep_stages(date_sleep)
                
                # Get start and end time to calculate actual sleep duration
                start_time = date_sleep_with_stages['timestamp'].min()
                end_time = date_sleep_with_stages['timestamp'].max()
                total_minutes = (end_time - start_time).total_seconds() / 60.0

                # Count sleep stages
                stage_counts = date_sleep_with_stages['sleep_stage'].value_counts()
                total_stage_counts = stage_counts.sum()

                if total_stage_counts > 0 and total_minutes > 0:
                    deep_pct = stage_counts.get('Deep', 0) / total_stage_counts
                    rem_pct = stage_counts.get('REM', 0) / total_stage_counts
                    light_pct = stage_counts.get('Light', 0) / total_stage_counts

                    # Scale actual duration
                    deep_minutes = total_minutes * deep_pct
                    rem_minutes = total_minutes * rem_pct
                    light_minutes = total_minutes * light_pct
                else:
                    deep_minutes = rem_minutes = light_minutes = 0

                # Convert to hours
                deep_hours = deep_minutes / 60
                rem_hours = rem_minutes / 60
                light_hours = light_minutes / 60
                
                # Add to lists
                deep_durations.append(deep_hours)
                rem_durations.append(rem_hours)
                light_durations.append(light_hours)
                visible_dates.append(date)
            else:
                # No data for this date
                deep_durations.append(0)
                rem_durations.append(0)
                light_durations.append(0)
        
        # Create weekly sleep trend chart
        fig = go.Figure()
        
        # Add traces for each sleep stage as stacked bars
        fig.add_trace(go.Bar(
            x=date_labels,
            y=deep_durations,
            name='SWS (DEEP)',
            marker_color='#F9A8D4',  # Pink color for Deep Sleep
            text=[f"{h:.1f}h" if h > 0 else "" for h in deep_durations],
            textposition='inside'
        ))
        
        fig.add_trace(go.Bar(
            x=date_labels,
            y=rem_durations,
            name='REM',
            marker_color='#A78BFA',  # Purple color for REM Sleep
            text=[f"{h:.1f}h" if h > 0 else "" for h in rem_durations],
            textposition='inside'
        ))
        
        fig.add_trace(go.Bar(
            x=date_labels,
            y=light_durations,
            name='LIGHT',
            marker_color='#D8B4FE',  # Light purple for Light Sleep
            text=[f"{h:.1f}h" if h > 0 else "" for h in light_durations],
            textposition='inside'
        ))
        
        # Configure the layout
        fig.update_layout(
            barmode='stack',
            title="Sleep Stages by Night",
            xaxis_title="",
            yaxis_title="Hours",
            legend=dict(
                orientation="h",
                yanchor="bottom",
                y=1.02,
                xanchor="right",
                x=1
            ),
            plot_bgcolor='#1A1D21',  # Dark background like WHOOP
            paper_bgcolor='#1A1D21',
            font=dict(color='white'),
            margin=dict(l=40, r=40, t=60, b=40),
            height=400
        )
        
        # Add text annotations for total sleep duration on top of each stack
        for i, date in enumerate(date_labels):
            total_hours = deep_durations[i] + rem_durations[i] + light_durations[i]
            if total_hours > 0:  # Only add annotations for dates with sleep data
                fig.add_annotation(
                    x=i,
                    y=total_hours,
                    text=f"{total_hours:.2f}",
                    showarrow=False,
                    yshift=10,
                    font=dict(color="white")
                )
        
        # Display the figure
        st.plotly_chart(fig, use_container_width=True)
        
        # Add a summary of weekly averages
        valid_nights = [i for i, hrs in enumerate(deep_durations) if deep_durations[i] + rem_durations[i] + light_durations[i] > 0]
        if valid_nights:
            avg_deep = sum([deep_durations[i] for i in valid_nights]) / len(valid_nights)
            avg_rem = sum([rem_durations[i] for i in valid_nights]) / len(valid_nights)
            avg_light = sum([light_durations[i] for i in valid_nights]) / len(valid_nights)
            avg_total = avg_deep + avg_rem + avg_light
            
            col1, col2, col3, col4 = st.columns(4)
            
            with col1:
                st.metric("Avg Total Sleep", f"{avg_total:.1f}h")
            
            with col2:
                st.metric("Avg Deep Sleep", f"{avg_deep:.1f}h ({avg_deep/avg_total*100:.1f}%)")
                
            with col3:
                st.metric("Avg REM Sleep", f"{avg_rem:.1f}h ({avg_rem/avg_total*100:.1f}%)")
                
            with col4:
                st.metric("Avg Light Sleep", f"{avg_light:.1f}h ({avg_light/avg_total*100:.1f}%)")
    else:
        st.info("Not enough data to display weekly sleep trends. Please record sleep data for at least one night.")
    # Insights and recommendations section
    st.header("💡 Insights & Recommendations")
    
    if 'recovery_score' in night_data.columns and not night_data.empty:
        latest_recovery = night_data.sort_values('date', ascending=False).iloc[0]['recovery_score']
        
        st.subheader("Daily Recommendations")
        
        if latest_recovery < 33:
            st.markdown("""
            #### 🔴 Recovery Focus Day
            
            **Your body shows signs of needing recovery. Consider:**
            - Light walking or yoga
            - Stretching and mobility work
            - Extra sleep or naps if possible
            - Hydration and nutrition focus
            - Avoid high-intensity training
            
            **Target Strain:** 0-7
            """)
        elif latest_recovery < 67:
            st.markdown("""
            #### 🟡 Moderate Training Day
            
            **Your body shows moderate recovery. Consider:**
            - Moderate cardio (zone 2)
            - Strength training with moderate loads
            - Technical skill work
            - Adequate warm-up and cool-down
            - Normal sleep duration
            
            **Target Strain:** 8-14
            """)
        else:
            st.markdown("""
            #### 🟢 Performance Day
            
            **Your body shows excellent recovery. Consider:**
            - High-intensity interval training
            - Competition or race day
            - Personal record attempts
            - Heavy strength training
            - Longer duration endurance work
            
            **Target Strain:** 14-21
            """)
    
    # HRV Metrics Reference
    with st.expander("📚 HRV Metrics Reference"):
        st.markdown("""
        ## HRV Metrics Reference Guide
        
        ### Heart Rate (HR)
        | Range | Label |
        | ----- | ----- |
        | < 60 | Bradycardic |
        | 60–75 | Optimal resting HR |
        | 75–85 | Mild activation |
        | > 85 | High sympathetic tone |
        
        ### RMSSD (ms)
        | Range | Label |
        | ----- | ----- |
        | > 60 | Very high vagal tone |
        | 40–60 | High parasympathetic activity |
        | 25–40 | Healthy variability |
        | 15–25 | Reduced vagal tone |
        | < 15 | Low vagal input |
        
        ### SDNN (ms)
        | Range | Label |
        | ----- | ----- |
        | > 80 | Excellent resilience |
        | 50–80 | Good adaptability |
        | 30–50 | Moderate variability |
        | 20–30 | Low HRV |
        | < 20 | Very low HRV |
        
        ### LF/HF Ratio
        | Range | Label |
        | ----- | ----- |
        | < 0.5 | High parasympathetic |
        | 0.5–2.0 | Balanced |
        | 2.0–4.0 | Mild sympathetic |
        | 4.0–10.0 | High sympathetic |
        | > 10.0 | Likely invalid |
        """)

if __name__ == "__main__":
    st.set_page_config(
        page_title="HRV Analytics",
        page_icon="📊",
        layout="wide"
    )
    main()