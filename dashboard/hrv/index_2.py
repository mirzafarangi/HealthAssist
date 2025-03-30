import streamlit as st
import pandas as pd
import numpy as np
import plotly.express as px
import plotly.graph_objects as go
from sqlalchemy import create_engine, text
from datetime import datetime, timedelta
import pytz
from typing import List, Dict, Tuple, Any, Optional

# Database connection function
def get_db_engine():
    """Create and return a database engine."""
    try:
        DATABASE_URL = "your db url here"
        engine = create_engine(DATABASE_URL)
        # Test connection
        with engine.connect() as conn:
            conn.execute(text("SELECT 1"))
        return engine, None
    except Exception as e:
        return None, str(e)

def fetch_all_records():
    """Fetch all records from the database."""
    engine, error = get_db_engine()
    if error:
        return None, error
    
    # Base query to join all necessary tables
    query_text = """
    SELECT 
        s.id as session_id,
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
        s.timestamp ASC
    """
    
    try:
        # Create SQLAlchemy text object for the query
        query = text(query_text)
        
        with engine.connect() as conn:
            df = pd.read_sql_query(query, conn)
            
            # Format timestamp to UTC timezone first
            df['timestamp'] = pd.to_datetime(df['timestamp'], utc=True)
            
            # Convert UTC timestamps to Berlin timezone
            berlin_tz = pytz.timezone('Europe/Berlin')
            df['timestamp'] = df['timestamp'].dt.tz_convert(berlin_tz)
            
            # Extract date for date-based analysis
            df['date'] = df['timestamp'].dt.date
            
            # Sort by date to ensure chronological processing
            df = df.sort_values('date')
            
            return df, None
    except Exception as e:
        return None, str(e)

def extract_sws_periods(sleep_df):
    """
    Approximate slow-wave sleep by extracting the lowest 30-minute rolling window
    near the end of sleep period (last 90 mins).
    
    Args:
        sleep_df: DataFrame containing sleep records
        
    Returns:
        DataFrame with approximated SWS periods
    """
    if sleep_df.empty:
        return pd.DataFrame()
    
    # Sort by timestamp
    sleep_df = sleep_df.sort_values("timestamp")
    
    # Get end time of sleep and calculate cutoff for SWS detection
    end_time = sleep_df['timestamp'].max()
    cutoff = end_time - pd.Timedelta(minutes=90)
    
    # Filter for records in the last 90 minutes of sleep
    sws_window = sleep_df[sleep_df['timestamp'] >= cutoff].copy()
    
    if sws_window.empty:
        return sleep_df  # Fallback to all sleep records if window is too narrow
    
    # Apply 5-minute rolling median to find stable HR periods
    sws_window['rolling_hr'] = sws_window['heartRate'].rolling(window=5, min_periods=1).median()
    
    # Take the 30 records with lowest heart rate as approximate SWS
    lowest_30min = sws_window.sort_values('rolling_hr').head(30)
    
    if len(lowest_30min) < 3:
        return sleep_df  # Fallback if not enough records
        
    return lowest_30min

def calculate_stress_index(hr, baseline_rhr, hrv, baseline_hrv):
    """
    Calculate stress index based on HR and HRV values
    
    Args:
        hr: Current heart rate
        baseline_rhr: Baseline resting heart rate
        hrv: Current HRV (RMSSD)
        baseline_hrv: Baseline HRV (RMSSD)
        
    Returns:
        Stress index (0-3 scale)
    """
    if pd.isna(hr) or pd.isna(baseline_rhr) or pd.isna(hrv) or pd.isna(baseline_hrv) or baseline_rhr == 0 or baseline_hrv == 0:
        return np.nan
        
    # Calculate HR component (0-1.5 scale)
    hr_ratio = hr / baseline_rhr
    hr_component = min(1.5, max(0, (hr_ratio - 0.8) * 2))
    
    # Calculate HRV component (0-1.5 scale, inverted - lower HRV = higher stress)
    hrv_ratio = hrv / baseline_hrv
    hrv_component = min(1.5, max(0, (1 - hrv_ratio) * 2))
    
    # Combine components
    stress_index = hr_component + hrv_component
    
    return round(min(3.0, max(0.0, stress_index)), 1)

def calculate_daily_metrics_with_dynamic_baselines(df):
    """
    Calculate daily metrics with dynamic baselines that evolve as days progress.
    For each day, the baseline is calculated based on all previous days.
    
    Args:
        df: DataFrame with HRV records
        
    Returns:
        DataFrame with daily metrics and their corresponding baselines
    """
    if df.empty:
        return pd.DataFrame()
    
    # Extract sleep and non-sleep records
    sleep_records = df[df['tags'].apply(lambda x: 'Sleep' in x if isinstance(x, list) else False)]
    non_sleep_records = df[~df['tags'].apply(lambda x: 'Sleep' in x if isinstance(x, list) else False)]
    
    if sleep_records.empty:
        return pd.DataFrame()
    
    # Get unique dates and sort them
    unique_dates = sorted(df['date'].unique())
    
    # Initialize results dataframe
    result_data = []
    
    # Initialize cumulative data for baseline calculations
    cumulative_sleep = pd.DataFrame()
    cumulative_non_sleep = pd.DataFrame()
    
    for date in unique_dates:
        # Get data for current date
        day_sleep = sleep_records[sleep_records['date'] == date]
        day_non_sleep = non_sleep_records[non_sleep_records['date'] == date]
        
        # Add to cumulative data for baseline calculations
        cumulative_sleep = pd.concat([cumulative_sleep, day_sleep])
        cumulative_non_sleep = pd.concat([cumulative_non_sleep, day_non_sleep])
        
        # Calculate metrics for current day
        # 1. Resting Heart Rate (lowest 10% during sleep)
        if not day_sleep.empty and len(day_sleep) >= 3:
            rhr = day_sleep['heartRate'].quantile(0.1)
        elif not day_sleep.empty:
            rhr = day_sleep['heartRate'].min()
        else:
            rhr = np.nan
            
        # 2. Average Heart Rate (from non-sleep periods)
        avg_hr = day_non_sleep['heartRate'].mean() if not day_non_sleep.empty else np.nan
        
        # 3. HRV (RMSSD during sleep)
        hrv = day_sleep['rmssd'].mean() if not day_sleep.empty else np.nan
        
        # 4. Breathing Rate (during sleep)
        breathing_rate = day_sleep['breathingRate'].mean() if not day_sleep.empty else np.nan
        
        # Calculate cumulative baselines from all data up to current date
        # These represent the dynamic baselines that evolve over time
        
        # Baseline HRV (median of lowest 30% RMSSD values)
        if not cumulative_sleep.empty and len(cumulative_sleep) >= 3:
            lowest_hrv_count = max(1, int(len(cumulative_sleep) * 0.3))
            baseline_hrv = cumulative_sleep.nsmallest(lowest_hrv_count, 'rmssd')['rmssd'].median()
        else:
            baseline_hrv = hrv  # On first day, baseline = current value
        
        # Baseline RHR (median of lowest 30% RHR values)
        if not cumulative_sleep.empty and len(cumulative_sleep) >= 3:
            lowest_rhr_count = max(1, int(len(cumulative_sleep) * 0.3))
            baseline_rhr = cumulative_sleep.nsmallest(lowest_rhr_count, 'heartRate')['heartRate'].median()
        else:
            baseline_rhr = rhr  # On first day, baseline = current value
        
        # Baseline HR (median of all non-sleep HR values)
        baseline_hr = cumulative_non_sleep['heartRate'].median() if not cumulative_non_sleep.empty else avg_hr
        
        # Baseline Breathing Rate (median of all sleep breathing rates)
        baseline_breathing_rate = cumulative_sleep['breathingRate'].median() if not cumulative_sleep.empty else breathing_rate
        
        # Calculate stress index
        stress_index = calculate_stress_index(avg_hr, baseline_rhr, hrv, baseline_hrv)
        
        # Store results
        result_data.append({
            'date': date,
            'rhr': rhr,
            'avg_hr': avg_hr,
            'hrv': hrv,
            'breathing_rate': breathing_rate,
            'stress_index': stress_index,
            'baseline_rhr': baseline_rhr,
            'baseline_hr': baseline_hr,
            'baseline_hrv': baseline_hrv,
            'baseline_breathing_rate': baseline_breathing_rate,
            'day_number': len(result_data) + 1  # Day counter starting from 1
        })
    
    # Convert to DataFrame
    result_df = pd.DataFrame(result_data)
    
    return result_df

def create_weekly_trend_chart(data, metric_column, baseline_column, title, color_scale, y_axis_title):
    """
    Create a weekly trend chart with dynamic baseline
    
    Args:
        data: DataFrame with daily metrics
        metric_column: Column name for the metric to plot
        baseline_column: Column name for the baseline values
        title: Chart title
        color_scale: Color scale for the line
        y_axis_title: Y-axis title
        
    Returns:
        Plotly figure
    """
    # Get the last 7 days of data (or all if less than 7)
    days_to_show = min(7, len(data))
    plot_data = data.tail(days_to_show)
    
    # Create figure
    fig = go.Figure()
    
    # Add metric line
    fig.add_trace(go.Scatter(
        x=plot_data['date'],
        y=plot_data[metric_column],
        mode='lines+markers',
        name=y_axis_title,
        line=dict(color=color_scale[0], width=3),
        marker=dict(size=8)
    ))
    
    # Add baseline line
    fig.add_trace(go.Scatter(
        x=plot_data['date'],
        y=plot_data[baseline_column],
        mode='lines',
        name=f'Baseline {y_axis_title}',
        line=dict(color=color_scale[1], width=2, dash='dash')
    ))
    
    # Update layout
    fig.update_layout(
        title=title,
        xaxis_title="Date",
        yaxis_title=y_axis_title,
        height=350,
        margin=dict(l=40, r=40, t=50, b=40),
        legend=dict(
            orientation="h",
            yanchor="bottom",
            y=1.02,
            xanchor="right",
            x=1
        ),
        hovermode="x unified"
    )
    
    # Add colored area between lines to highlight the difference
    for i in range(len(plot_data) - 1):
        fig.add_shape(
            type="rect",
            x0=plot_data['date'].iloc[i],
            x1=plot_data['date'].iloc[i+1],
            y0=min(plot_data[metric_column].iloc[i], plot_data[baseline_column].iloc[i]),
            y1=max(plot_data[metric_column].iloc[i], plot_data[baseline_column].iloc[i]),
            fillcolor=color_scale[2],
            opacity=0.2,
            line=dict(width=0),
            layer="below"
        )
    
    return fig

def create_day_number_chart(data, metric_column, baseline_column, title, color_scale, y_axis_title):
    """
    Create a chart showing the trend by day number (from day 1 onwards)
    
    Args:
        data: DataFrame with daily metrics
        metric_column: Column name for the metric to plot
        baseline_column: Column name for the baseline values
        title: Chart title
        color_scale: Color scale for the line
        y_axis_title: Y-axis title
        
    Returns:
        Plotly figure
    """
    # Create figure
    fig = go.Figure()
    
    # Add metric line
    fig.add_trace(go.Scatter(
        x=data['day_number'],
        y=data[metric_column],
        mode='lines+markers',
        name=y_axis_title,
        line=dict(color=color_scale[0], width=3),
        marker=dict(size=8)
    ))
    
    # Add baseline line
    fig.add_trace(go.Scatter(
        x=data['day_number'],
        y=data[baseline_column],
        mode='lines',
        name=f'Baseline {y_axis_title}',
        line=dict(color=color_scale[1], width=2, dash='dash')
    ))
    
    # Update layout
    fig.update_layout(
        title=title,
        xaxis_title="Day Number",
        yaxis_title=y_axis_title,
        height=350,
        margin=dict(l=40, r=40, t=50, b=40),
        legend=dict(
            orientation="h",
            yanchor="bottom",
            y=1.02,
            xanchor="right",
            x=1
        ),
        hovermode="x unified",
        xaxis=dict(
            tickmode='linear',
            tick0=1,
            dtick=1
        )
    )
    
    # Add colored area between lines to highlight the difference
    for i in range(len(data) - 1):
        fig.add_shape(
            type="rect",
            x0=data['day_number'].iloc[i],
            x1=data['day_number'].iloc[i+1],
            y0=min(data[metric_column].iloc[i], data[baseline_column].iloc[i]),
            y1=max(data[metric_column].iloc[i], data[baseline_column].iloc[i]),
            fillcolor=color_scale[2],
            opacity=0.2,
            line=dict(width=0),
            layer="below"
        )
    
    return fig

def create_metric_convergence_plot(data, view_type):
    """
    Create a plot showing how metrics converge with their baselines over time
    
    Args:
        data: DataFrame with daily metrics
        view_type: 'calendar' for calendar dates or 'day_number' for day counts
        
    Returns:
        Plotly figure
    """
    # Calculate the absolute difference between each metric and its baseline
    data['rhr_diff'] = np.abs(data['rhr'] - data['baseline_rhr'])
    data['hr_diff'] = np.abs(data['avg_hr'] - data['baseline_hr'])
    data['hrv_diff'] = np.abs(data['hrv'] - data['baseline_hrv'])
    data['breathing_diff'] = np.abs(data['breathing_rate'] - data['baseline_breathing_rate'])
    
    # Normalize the differences (0-1 scale for comparison)
    max_rhr_diff = data['rhr_diff'].max()
    max_hr_diff = data['hr_diff'].max()
    max_hrv_diff = data['hrv_diff'].max()
    max_breathing_diff = data['breathing_diff'].max()
    
    data['rhr_diff_norm'] = data['rhr_diff'] / max_rhr_diff if max_rhr_diff > 0 else 0
    data['hr_diff_norm'] = data['hr_diff'] / max_hr_diff if max_hr_diff > 0 else 0
    data['hrv_diff_norm'] = data['hrv_diff'] / max_hrv_diff if max_hrv_diff > 0 else 0
    data['breathing_diff_norm'] = data['breathing_diff'] / max_breathing_diff if max_breathing_diff > 0 else 0
    
    # Create figure
    fig = go.Figure()
    
    x_column = 'date' if view_type == 'calendar' else 'day_number'
    x_title = "Date" if view_type == 'calendar' else "Day Number"
    
    # Add lines for each metric's convergence
    fig.add_trace(go.Scatter(
        x=data[x_column],
        y=data['rhr_diff_norm'],
        mode='lines+markers',
        name="RHR Convergence",
        line=dict(color='#8C0600', width=2)
    ))
    
    fig.add_trace(go.Scatter(
        x=data[x_column],
        y=data['hr_diff_norm'],
        mode='lines+markers',
        name="HR Convergence",
        line=dict(color='#C24B00', width=2)
    ))
    
    fig.add_trace(go.Scatter(
        x=data[x_column],
        y=data['hrv_diff_norm'],
        mode='lines+markers',
        name="HRV Convergence",
        line=dict(color='#008596', width=2)
    ))
    
    fig.add_trace(go.Scatter(
        x=data[x_column],
        y=data['breathing_diff_norm'],
        mode='lines+markers',
        name="Breathing Convergence",
        line=dict(color='#004B40', width=2)
    ))
    
    # Update layout
    fig.update_layout(
        title="Metric Convergence Over Time",
        xaxis_title=x_title,
        yaxis_title="Normalized Difference from Baseline",
        height=350,
        margin=dict(l=40, r=40, t=50, b=40),
        hovermode="x unified",
        yaxis=dict(range=[0, 1.1])
    )
    
    if view_type == 'day_number':
        fig.update_layout(
            xaxis=dict(
                tickmode='linear',
                tick0=1,
                dtick=1
            )
        )
    
    return fig

def main():
    """Main function for the Visualizations tab."""
    st.header("Daily Metrics Summary")
    
    with st.spinner("Loading data..."):
        # Fetch all records
        df, error = fetch_all_records()
        
        if error:
            st.error(f"❌ Error fetching data: {error}")
            return
        
        if df.empty:
            st.warning("No data available for visualization.")
            return
        
        # Calculate daily metrics with dynamic baselines
        daily_metrics = calculate_daily_metrics_with_dynamic_baselines(df)
        
        if daily_metrics.empty:
            st.warning("Unable to calculate daily metrics. Ensure you have sleep data tagged appropriately.")
            return
        
        st.success(f"✅ Processed {len(daily_metrics)} days of data for visualization")
    
    # View options
    st.subheader("View Options")
    view_type = st.radio(
        "Select view type:", 
        ["Calendar", "Day Number"], 
        horizontal=True,
        help="Calendar shows dates, Day Number shows progression from day 1 onwards"
    )
    
    # Show latest data summary
    latest_day = daily_metrics.iloc[-1]
    date_str = latest_day['date'].strftime('%Y-%m-%d')
    
    st.subheader(f"Latest Metrics ({date_str})")
    
    # Display key metrics
    col1, col2, col3, col4, col5 = st.columns(5)
    
    with col1:
        st.metric(
            "Heart Rate", 
            f"{latest_day['avg_hr']:.1f} bpm", 
            f"{latest_day['avg_hr'] - latest_day['baseline_hr']:.1f}" if not pd.isna(latest_day['avg_hr']) else None
        )
    
    with col2:
        st.metric(
            "Resting HR", 
            f"{latest_day['rhr']:.1f} bpm",
            f"{latest_day['rhr'] - latest_day['baseline_rhr']:.1f}" if not pd.isna(latest_day['rhr']) else None,
            delta_color="inverse"
        )
    
    with col3:
        st.metric(
            "HRV (RMSSD)", 
            f"{latest_day['hrv']:.1f} ms",
            f"{latest_day['hrv'] - latest_day['baseline_hrv']:.1f}" if not pd.isna(latest_day['hrv']) else None
        )
    
    with col4:
        st.metric(
            "Breathing Rate", 
            f"{latest_day['breathing_rate']:.1f} brpm",
            f"{latest_day['breathing_rate'] - latest_day['baseline_breathing_rate']:.1f}" if not pd.isna(latest_day['breathing_rate']) else None
        )
    
    with col5:
        st.metric(
            "Stress Index", 
            f"{latest_day['stress_index']:.1f}" if not pd.isna(latest_day['stress_index']) else "N/A",
            None
        )
    
    # Create visualizations tab section
    st.subheader("Metric Trends with Dynamic Baselines")
    
    # Set up tabs for different visualizations
    viz_tab1, viz_tab2, viz_tab3, viz_tab4, viz_tab5 = st.tabs([
        "Heart Rate", "Resting HR", "HRV", "Breathing Rate", "Stress Index"
    ])
    
    # Determine which plotting function to use based on view type
    plot_func = create_weekly_trend_chart if view_type == "Calendar" else create_day_number_chart
    
    with viz_tab1:
        # Heart Rate visualization
        hr_fig = plot_func(
            daily_metrics,
            'avg_hr',
            'baseline_hr',
            'Heart Rate Trend with Dynamic Baseline',
            ['#C24B00', '#8B2800', '#FFB74D'],  # Orange palette
            'Heart Rate (bpm)'
        )
        st.plotly_chart(hr_fig, use_container_width=True)
        
        # Explanation
        st.markdown("""
        **Heart Rate Trend Analysis:**
        - Shows your average heart rate during active periods (excluding sleep)
        - The baseline (dashed line) represents your cumulative average HR, recalculated each day
        - Greater separation between the lines indicates deviation from your typical values
        - HR typically rises with activity/stress and falls with recovery
        """)
    
    with viz_tab2:
        # Resting Heart Rate visualization
        rhr_fig = plot_func(
            daily_metrics,
            'rhr',
            'baseline_rhr',
            'Resting Heart Rate Trend with Dynamic Baseline',
            ['#8C0600', '#5A0300', '#F9A19B'],  # Red palette
            'Resting Heart Rate (bpm)'
        )
        st.plotly_chart(rhr_fig, use_container_width=True)
        
        # Explanation
        st.markdown("""
        **Resting Heart Rate Analysis:**
        - Shows your resting heart rate during sleep
        - The baseline (dashed line) adjusts as more data is collected
        - Lower RHR typically indicates better cardiovascular fitness and recovery
        - RHR can be affected by fatigue, stress, hydration, and numerous health factors
        """)
    
    with viz_tab3:
        # HRV visualization
        hrv_fig = plot_func(
            daily_metrics,
            'hrv',
            'baseline_hrv',
            'HRV Trend with Dynamic Baseline',
            ['#008596', '#005F6B', '#97DFEB'],  # Blue palette
            'HRV (RMSSD) in ms'
        )
        st.plotly_chart(hrv_fig, use_container_width=True)
        
        # Explanation
        st.markdown("""
        **Heart Rate Variability Analysis:**
        - Shows your RMSSD (root mean square of successive RR interval differences)
        - The baseline evolves as your HRV patterns develop over time
        - Higher HRV typically indicates better recovery and autonomic nervous system balance
        - Lower HRV can indicate stress, inadequate recovery, or overtraining
        """)
    
    with viz_tab4:
        # Breathing Rate visualization
        br_fig = plot_func(
            daily_metrics,
            'breathing_rate',
            'baseline_breathing_rate',
            'Breathing Rate Trend with Dynamic Baseline',
            ['#004B40', '#00332C', '#97D0C5'],  # Green palette
            'Breathing Rate (breaths/min)'
        )
        st.plotly_chart(br_fig, use_container_width=True)
        
        # Explanation
        st.markdown("""
        **Breathing Rate Analysis:**
        - Shows your breathing rate during sleep
        - The baseline is typically stable for most individuals
        - Significant changes may indicate respiratory issues, stress, or altitude changes
        - Optimal breathing rate during sleep is typically 10-14 breaths per minute
        """)
    
    with viz_tab5:
        # Stress Index visualization (no baseline - it's a derived metric)
        stress_data = daily_metrics.copy()
        stress_fig = go.Figure()
        
        # Add stress index line
        stress_fig.add_trace(go.Scatter(
            x=stress_data['date'] if view_type == 'Calendar' else stress_data['day_number'],
            y=stress_data['stress_index'],
            mode='lines+markers',
            name='Stress Index',
            line=dict(color='#9C27B0', width=3),  # Purple
            marker=dict(size=10)
        ))
        
        # Add reference lines for stress zones
        stress_fig.add_shape(
            type="line",
            x0=stress_data.iloc[0]['date' if view_type == 'Calendar' else 'day_number'],
            x1=stress_data.iloc[-1]['date' if view_type == 'Calendar' else 'day_number'],
            y0=0.8, y1=0.8,
            line=dict(color="gold", width=1, dash="dash"),
        )
        
        stress_fig.add_shape(
            type="line",
            x0=stress_data.iloc[0]['date' if view_type == 'Calendar' else 'day_number'],
            x1=stress_data.iloc[-1]['date' if view_type == 'Calendar' else 'day_number'],
            y0=1.8, y1=1.8,
            line=dict(color="crimson", width=1, dash="dash"),
        )
        
        # Add zone labels
        stress_fig.add_annotation(
            x=stress_data.iloc[-1]['date' if view_type == 'Calendar' else 'day_number'],
            y=0.4,
            text="Low Stress Zone",
            showarrow=False,
            font=dict(color="green"),
            xanchor="right"
        )
        
        stress_fig.add_annotation(
            x=stress_data.iloc[-1]['date' if view_type == 'Calendar' else 'day_number'],
            y=1.3,
            text="Medium Stress Zone",
            showarrow=False,
            font=dict(color="gold"),
            xanchor="right"
        )
        
        stress_fig.add_annotation(
            x=stress_data.iloc[-1]['date' if view_type == 'Calendar' else 'day_number'],
            y=2.4,
            text="High Stress Zone",
            showarrow=False,
            font=dict(color="crimson"),
            xanchor="right"
        )
        
        # Update layout
        stress_fig.update_layout(
            title="Stress Index Trend",
            xaxis_title="Date" if view_type == 'Calendar' else "Day Number",
            yaxis_title="Stress Index (0-3)",
            height=350,
            margin=dict(l=40, r=40, t=50, b=40),
            yaxis=dict(range=[0, 3])
        )
        
        if view_type == 'day_number':
            stress_fig.update_layout(
                xaxis=dict(
                    tickmode='linear',
                    tick0=1,
                    dtick=1
                )
            )
        
        st.plotly_chart(stress_fig, use_container_width=True)
        
        # Explanation
        st.markdown("""
        **Stress Index Analysis:**
        - Scale: 0-3 (Low: <0.8, Medium: 0.8-1.8, High: >1.8)
        - Calculated from both heart rate and HRV data relative to your baselines
        - Higher values indicate greater physiological stress
        - This metric integrates multiple data points to estimate overall stress level
        """)
    
    # Add a Metrics Convergence tab to show how fast baselines are developing
    st.subheader("Metrics Convergence Analysis")
    
    # Create convergence visualization
    convergence_fig = create_metric_convergence_plot(daily_metrics, 'day_number' if view_type == 'Day Number' else 'calendar')
    st.plotly_chart(convergence_fig, use_container_width=True)
    
    # Explanation of convergence
    st.markdown("""
    **Metrics Convergence Analysis:**
    - Shows how quickly each metric is approaching its stable baseline
    - Lower values indicate the metric is closer to its established baseline
    - Fast convergence means your baselines stabilize quickly
    - Metrics that remain high may need more data to establish reliable baselines
    
    As you collect more data, your baselines become more stable and reliable for accurately assessing changes in your metrics.
    """)
    
    # Show statistics about baseline stability
    if len(daily_metrics) >= 3:
        # Calculate the coefficient of variation for each baseline to assess stability
        latest_7_days = min(7, len(daily_metrics))
        baseline_stability = daily_metrics.tail(latest_7_days).copy()
        
        baseline_cv = {
            'Heart Rate': (baseline_stability['baseline_hr'].std() / baseline_stability['baseline_hr'].mean() * 100) if baseline_stability['baseline_hr'].mean() > 0 else 0,
            'Resting HR': (baseline_stability['baseline_rhr'].std() / baseline_stability['baseline_rhr'].mean() * 100) if baseline_stability['baseline_rhr'].mean() > 0 else 0,
            'HRV': (baseline_stability['baseline_hrv'].std() / baseline_stability['baseline_hrv'].mean() * 100) if baseline_stability['baseline_hrv'].mean() > 0 else 0,
            'Breathing Rate': (baseline_stability['baseline_breathing_rate'].std() / baseline_stability['baseline_breathing_rate'].mean() * 100) if baseline_stability['baseline_breathing_rate'].mean() > 0 else 0
        }
        
        st.subheader("Baseline Stability (last 7 days)")
        
        baseline_stability_df = pd.DataFrame({
            'Metric': baseline_cv.keys(),
            'Variability (%)': [round(v, 1) for v in baseline_cv.values()],
            'Status': ['Stable' if v < 5 else ('Moderately Stable' if v < 10 else 'Still Developing') for v in baseline_cv.values()]
        })
        
        st.dataframe(baseline_stability_df, use_container_width=True)
        
        # Show days to stability estimate
        days_collected = len(daily_metrics)
        est_days_to_stability = max(0, 14 - days_collected)
        
        if est_days_to_stability > 0:
            st.info(f"📊 Baseline Development: Approximately {est_days_to_stability} more days of data recommended for stable baselines.")
        else:
            st.success("📊 Baseline Development: You have collected sufficient data for reliable baselines!")
    
    # Add download capability for the data
    st.subheader("Export Data")
    
    # Prepare clean dataframe for download
    download_df = daily_metrics.copy()
    download_df['date'] = download_df['date'].astype(str)  # Convert date to string for CSV
    
    # Create downloadable CSV
    csv = download_df.to_csv(index=False)
    st.download_button(
        label="Download Metrics CSV",
        data=csv,
        file_name="hrv_metrics_with_dynamic_baselines.csv",
        mime="text/csv",
    )
    
    # Documentation section
    with st.expander("📚 About Dynamic Baselines"):
        st.markdown("""
        ### Understanding Dynamic Baselines
        
        This visualization shows how your health metrics evolve over time, with baselines that develop as more data is collected.
        
        **Key concepts:**
        
        - **Day 1 baselines**: On your first day of data collection, your baseline equals your current values
        - **Evolving baselines**: As you add more days of data, baselines recalculate to include all historical data
        - **Stabilization**: After approximately 14 days, most baselines become relatively stable
        - **Interpretation**: The gap between the baseline and your daily value shows how today compares to your typical state
        
        **Calculation methods:**
        
        - **Heart Rate baseline**: Median of all non-sleep heart rate readings
        - **Resting HR baseline**: Median of the lowest 30% of all sleep heart rate readings
        - **HRV baseline**: Median of the lowest 30% of all sleep RMSSD readings
        - **Breathing Rate baseline**: Median of all sleep breathing rate readings
        - **Stress Index**: Composite score using both HR and HRV compared to their baselines
        
        This approach is similar to methods used in professional HRV monitoring systems like WHOOP and Oura.
        """)

if __name__ == "__main__":
    # This allows the file to be run directly for testing
    st.set_page_config(
        page_title="Metric Visualizations",
        page_icon="📊",
        layout="wide"
    )
    main()