import streamlit as st
import pandas as pd
from sqlalchemy import create_engine, text
import pytz
from datetime import datetime

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

def exclude_records_by_session_id(recording_session_id):
    """Exclude records from the database by recording_session_id."""
    engine, error = get_db_engine()
    if error:
        return None, error
    
    try:
        with engine.connect() as conn:
            # Start a transaction
            with conn.begin():
                # First, get the session IDs to exclude
                find_sessions_query = text("""
                SELECT id FROM hrv_sessions 
                WHERE recording_session_id = :recording_session_id
                """)
                
                result = conn.execute(find_sessions_query, {"recording_session_id": recording_session_id})
                session_ids = [row[0] for row in result]
                
                if not session_ids:
                    return 0, f"No records found with recording session ID: {recording_session_id}"
                
                # Delete from rr_intervals table first to handle the foreign key constraint
                rr_intervals_delete_query = text("""
                DELETE FROM rr_intervals 
                WHERE session_id IN :session_ids
                """)
                
                conn.execute(rr_intervals_delete_query, {"session_ids": tuple(session_ids)})
                
                # Delete from hrv_metrics
                metrics_delete_query = text("""
                DELETE FROM hrv_metrics 
                WHERE session_id IN :session_ids
                """)
                
                conn.execute(metrics_delete_query, {"session_ids": tuple(session_ids)})
                
                # Delete from session_tags
                tags_delete_query = text("""
                DELETE FROM session_tags 
                WHERE session_id IN :session_ids
                """)
                
                conn.execute(tags_delete_query, {"session_ids": tuple(session_ids)})
                
                # Delete from hrv_sessions
                sessions_delete_query = text("""
                DELETE FROM hrv_sessions 
                WHERE id IN :session_ids
                """)
                
                delete_result = conn.execute(sessions_delete_query, {"session_ids": tuple(session_ids)})
                
                return len(session_ids), None
    except Exception as e:
        return None, str(e)

def main():
    """Main function for the Exclude Records tab."""
    st.header("Exclude Records")
    
    # Connection status
    with st.spinner("Connecting to database..."):
        engine, conn_error = get_db_engine()
        
        if conn_error:
            st.error(f"❌ Database connection failed: {conn_error}")
            return
        else:
            st.success("✅ Successfully connected to database")
    
    # Fetch data to show current records
    with st.spinner("Fetching current records..."):
        df, error = fetch_all_records()
        
        if error:
            st.error(f"❌ Error fetching records: {error}")
            return
        
        total_records = len(df) if df is not None else 0
        st.success(f"✅ Database currently contains {total_records} records")
    
    # Instructions
    st.subheader("Remove Records by Recording Session ID")
    st.markdown("""
    Enter the recording session ID (e.g., `test_session_9d8283a8`) to exclude all associated records from the database.
    
    **⚠️ Warning:** This operation cannot be undone. Please double-check the ID before proceeding.
    """)
    
    # Show latest 10 recording session IDs for reference
    if df is not None and not df.empty:
        st.subheader("Recent Recording Session IDs for Reference")
        recent_sessions = df[['recordingSessionId', 'timestamp', 'tags']].head(10).copy()
        recent_sessions['timestamp'] = recent_sessions['timestamp'].apply(format_timestamp_berlin)
        recent_sessions['tags'] = recent_sessions['tags'].apply(lambda x: ', '.join(x) if isinstance(x, list) else x)
        st.dataframe(recent_sessions, use_container_width=True)
    
    # Input for recording session ID
    recording_session_id = st.text_input("Enter Recording Session ID to exclude", 
                                          placeholder="e.g., test_session_9d8283a8")
    
    # Exclude button
    if st.button("Exclude Records", type="primary", disabled=not recording_session_id):
        if not recording_session_id:
            st.warning("Please enter a recording session ID")
        else:
            with st.spinner(f"Excluding records for session ID: {recording_session_id}..."):
                count, error = exclude_records_by_session_id(recording_session_id)
                
                if error:
                    st.error(f"❌ Error excluding records: {error}")
                else:
                    st.success(f"✅ Successfully excluded {count} records with session ID: {recording_session_id}")
                    
                    # Refresh data to show updated record count
                    df, error = fetch_all_records()
                    
                    if error:
                        st.error(f"❌ Error refreshing records: {error}")
                    else:
                        new_total = len(df) if df is not None else 0
                        st.info(f"👉 Database now contains {new_total} records (removed {total_records - new_total} records)")
                        
                        # Show the button to clear the input and refresh
                        if st.button("Refresh"):
                            st.experimental_rerun()
    
    # Advanced section for bulk exclusion
    with st.expander("Advanced: Bulk Exclude Multiple Records"):
        st.markdown("""
        Enter multiple recording session IDs (one per line) to exclude them all at once.
        """)
        
        bulk_ids = st.text_area("Enter Recording Session IDs (one per line)", 
                                placeholder="test_session_001\ntest_session_002")
        
        if st.button("Bulk Exclude", type="primary", disabled=not bulk_ids):
            if not bulk_ids:
                st.warning("Please enter at least one recording session ID")
            else:
                ids_to_exclude = [id.strip() for id in bulk_ids.split("\n") if id.strip()]
                
                progress_bar = st.progress(0)
                status_text = st.empty()
                
                total_excluded = 0
                for i, session_id in enumerate(ids_to_exclude):
                    status_text.text(f"Processing {i+1}/{len(ids_to_exclude)}: {session_id}")
                    count, error = exclude_records_by_session_id(session_id)
                    
                    if error and "No records found" not in error:
                        st.error(f"❌ Error excluding records for {session_id}: {error}")
                    elif error and "No records found" in error:
                        st.warning(f"⚠️ {error}")
                    else:
                        total_excluded += count
                    
                    progress_bar.progress((i + 1) / len(ids_to_exclude))
                
                # Refresh data to show updated record count
                df, error = fetch_all_records()
                
                if error:
                    st.error(f"❌ Error refreshing records: {error}")
                else:
                    new_total = len(df) if df is not None else 0
                    st.success(f"✅ Bulk exclusion complete. Excluded {total_excluded} records across {len(ids_to_exclude)} session IDs.")
                    st.info(f"👉 Database now contains {new_total} records (removed {total_records - new_total} records)")
                    
                    # Show the button to clear the input and refresh
                    if st.button("Refresh Page"):
                        st.experimental_rerun()
    
    # Show verification section with current database records
    if df is not None and not df.empty and st.checkbox("Show Current Database Records"):
        st.subheader("Current Database Records")
        
        # Create a display dataframe
        display_df = df.copy()
        display_df['timestamp'] = display_df['timestamp'].apply(format_timestamp_berlin)
        display_df['tags'] = display_df['tags'].apply(lambda x: ', '.join(x) if isinstance(x, list) else x)
        
        # Select important columns
        display_columns = ['session_id', 'recordingSessionId', 'timestamp', 'tags', 'heartRate', 'rmssd']
        
        st.dataframe(display_df[display_columns], use_container_width=True)

if __name__ == "__main__":
    # This allows the file to be run directly for testing
    st.set_page_config(
        page_title="Exclude Records",
        page_icon="🗑️",
        layout="wide"
    )
    main()