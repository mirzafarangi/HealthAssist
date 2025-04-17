import streamlit as st
import pandas as pd
import numpy as np
import plotly.express as px
from sqlalchemy import create_engine, text
from datetime import datetime, timedelta
import pytz

# Database connection function
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
        s.timestamp DESC
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
            
            return df, None
    except Exception as e:
        return None, str(e)

def format_timestamp_berlin(timestamp):
    """Format timestamp to Berlin timezone with readable format"""
    if pd.isna(timestamp):
        return "N/A"
    
    # Ensure it's in Berlin timezone
    if timestamp.tzinfo is not None:
        berlin_tz = pytz.timezone('Europe/Berlin')
        berlin_time = timestamp.astimezone(berlin_tz)
    else:
        utc_time = pytz.utc.localize(timestamp)
        berlin_tz = pytz.timezone('Europe/Berlin')
        berlin_time = utc_time.astimezone(berlin_tz)
    
    # Format as a readable string
    return berlin_time.strftime("%Y-%m-%d %H:%M:%S (Berlin)")

def fetch_tag_distribution(df):
    """Calculate the distribution of tags in the dataframe."""
    tag_counts = {}
    for tags_list in df['tags']:
        if isinstance(tags_list, list):
            for tag in tags_list:
                if tag in tag_counts:
                    tag_counts[tag] += 1
                else:
                    tag_counts[tag] = 1
    
    # Convert to DataFrame for easy display
    tag_df = pd.DataFrame(list(tag_counts.items()), columns=['Tag', 'Count'])
    tag_df = tag_df.sort_values('Count', ascending=False).reset_index(drop=True)
    
    return tag_df

def calculate_date_range(df):
    """Calculate the range of dates in the dataframe."""
    if df.empty:
        return None, None, None
    
    min_date = df['date'].min()
    max_date = df['date'].max()
    
    if min_date and max_date:
        date_range = (max_date - min_date).days + 1
        return min_date, max_date, date_range
    
    return None, None, None

def main():
    """Main function for the Record Summary tab."""
    st.header("Record Summary")
    
    # Connection status
    with st.spinner("Connecting to database..."):
        engine, conn_error = get_db_engine()
        
        if conn_error:
            st.error(f"❌ Database connection failed: {conn_error}")
        else:
            st.success("✅ Successfully connected to database")
    
    # Fetch data
    with st.spinner("Fetching records..."):
        df, error = fetch_all_records()
        
        if error:
            st.error(f"❌ Error fetching records: {error}")
            return
        
        if df.empty:
            st.warning("No records found in database")
            return
        
        st.success(f"✅ Successfully fetched {len(df)} records")
    
    # Database Summary Section
    st.subheader("Database Summary")
    
    # Calculate date range
    min_date, max_date, date_range = calculate_date_range(df)
    
    # Calculate tag distribution
    tag_distribution = fetch_tag_distribution(df)
    
    # Display summary metrics in columns
    col1, col2, col3 = st.columns(3)
    
    with col1:
        st.metric("Total Records", len(df))
        
    with col2:
        st.metric("Date Range", f"{date_range} days" if date_range else "N/A")
        
    with col3:
        st.metric("Unique Tags", len(tag_distribution))
    
    # Display date range details
    if min_date and max_date:
        st.markdown(f"**Data Collection Period:** {min_date} to {max_date}")
    
    # Display tag distribution
    st.subheader("Tag Distribution")
    
    # Create a bar chart for tag distribution
    fig = px.bar(
        tag_distribution, 
        x='Tag', 
        y='Count',
        title="Records by Tag",
        color='Count',
        color_continuous_scale="Blues"
    )
    
    fig.update_layout(
        xaxis_title="Tag",
        yaxis_title="Number of Records",
        height=400
    )
    
    st.plotly_chart(fig, use_container_width=True)
    
    # Show tag distribution in a table
    st.dataframe(tag_distribution, use_container_width=True, height=200)
    
    # Records Table Section
    st.subheader("Records")
    
    # Format data for display
    display_df = df.copy()
    
    # Format timestamp to be shown in Berlin timezone
    display_df['display_timestamp'] = display_df['timestamp'].apply(format_timestamp_berlin)
    
    # Format numeric columns to 2 decimal places
    numeric_cols = [
        "mean_rr", "sdnn", "rmssd", "pnn50", "cv_rr", 
        "lfPower", "hfPower", "lfHfRatio", "breathingRate",
        "valid_rr_percentage", "quality_score"
    ]
    
    for col in numeric_cols:
        if col in display_df.columns:
            display_df[col] = display_df[col].round(2)
    
    # Convert tags list to string
    display_df['tags'] = display_df['tags'].apply(lambda x: ', '.join(x) if isinstance(x, list) else x)
    
    # Reorder columns for better display
    columns = [
        "display_timestamp", "recordingSessionId", "tags", "heartRate",
        "mean_rr", "sdnn", "rmssd", "pnn50", "cv_rr", "rr_count",
        "lfPower", "hfPower", "lfHfRatio", "breathingRate",
        "valid_rr_percentage", "quality_score", "outlier_count", "filter_method", "valid"
    ]
    
    # Ensure all columns exist
    display_columns = [col for col in columns if col in display_df.columns]
    
    # Display in a scrollable table
    st.dataframe(
        display_df[display_columns],
        use_container_width=True,
        height=500  # Adjustable height to make it scrollable but not take too much space
    )
    
    # Show data quality info
    quality_stats = display_df['quality_score'].describe().to_dict()
    
    st.subheader("Data Quality")
    st.markdown(f"""
    - **Average Quality Score**: {quality_stats['mean']:.2f}
    - **Minimum Quality Score**: {quality_stats['min']:.2f}
    - **Maximum Quality Score**: {quality_stats['max']:.2f}
    - **Valid Records**: {display_df['valid'].sum()} ({display_df['valid'].mean() * 100:.1f}%)
    """)

if __name__ == "__main__":
    # This allows the file to be run directly for testing
    st.set_page_config(
        page_title="Record Summary",
        page_icon="📊",
        layout="wide"
    )
    main()