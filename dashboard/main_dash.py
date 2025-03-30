import streamlit as st
import importlib
import os
import sys

# Set page configuration
st.set_page_config(
    page_title="HealthAssist Dashboard",
    page_icon="⚕️",
    layout="wide",
    initial_sidebar_state="expanded",
)

# Apply global CSS styling for both mobile and desktop compatibility
st.markdown("""
<style>
    .main {
        background-color: #f8f9fa;
    }
    h1, h2, h3 {
        font-family: 'Arial', sans-serif;
        color: #2c3e50;
    }
    .stTabs [data-baseweb="tab-list"] {
        gap: 8px;
    }
    .stTabs [data-baseweb="tab"] {
        height: 50px;
        white-space: pre-wrap;
        background-color: #f8f9fa;
        border-radius: 4px 4px 0px 0px;
        border: 1px solid #ddd;
        padding-left: 16px;
        padding-right: 16px;
    }
    .stTabs [aria-selected="true"] {
        background-color: #e6f3ff;
        border-bottom: 2px solid #4e8cff;
    }
    
    /* Mobile Responsiveness */
    @media (max-width: 768px) {
        .stTabs [data-baseweb="tab"] {
            height: auto;
            padding: 10px 8px;
            font-size: 14px;
        }
        h1 {
            font-size: 1.8rem;
        }
        h2 {
            font-size: 1.5rem;
        }
        h3 {
            font-size: 1.2rem;
        }
    }
</style>
""", unsafe_allow_html=True)

# Title and description
st.title("HealthAssist Dashboard")
st.markdown("---")

# Sidebar
st.sidebar.title("HealthAssist")
st.sidebar.markdown("---")

# Metric categories definition
metric_categories = [
    {"name": "Cardiovascular Metrics", "folder": "hrv"},
    {"name": "Metric Category 2", "folder": "metric2"},
    # Add more metric categories here as needed
]

# Function to import and run tab modules with folder structure support
def load_tab_module(folder, module_name):
    """
    Dynamically import a tab module from specified folder and return its main function
    
    Args:
        folder (str): The folder containing the module
        module_name (str): The name of the module without .py extension
        
    Returns:
        function: The main function from the module, or None if not found/error
    """
    try:
        # Add the current directory to the path (if not already there)
        current_dir = os.path.dirname(os.path.abspath(__file__))
        if current_dir not in sys.path:
            sys.path.append(current_dir)
        
        # Import the module with folder prefix
        full_module_name = f"{folder}.{module_name}" if folder else module_name
        module = importlib.import_module(full_module_name)
        
        # Return the main function
        if hasattr(module, 'main'):
            return module.main
        else:
            st.error(f"Module {full_module_name} does not have a main function.")
            return None
    except Exception as e:
        st.error(f"Error loading module {full_module_name}: {str(e)}")
        return None

# Create main category tabs
category_tabs = st.tabs([category["name"] for category in metric_categories])

# Process each category
for i, tab in enumerate(category_tabs):
    with tab:
        category = metric_categories[i]
        folder = category["folder"]
        
        # Define tabs for each category
        if folder == "hrv":
            # Tab configurations for Cardiovascular Metrics
            tabs = [
                {"name": "Record Summary", "module": "record_summary"},
                {"name": "Index 1", "module": "index_1"},
                {"name": "Index_2", "module": "index_2"},
                {"name": "Delete Records", "module": "delete_session"}
                # Add more tabs here as needed
            ]
        elif folder == "metric2":
            # Example tab configuration for another metric category
            tabs = [
                {"name": "Summary", "module": "summary"},
                {"name": "Analysis", "module": "analysis"}
                # Add more tabs as needed
            ]
        else:
            # Default empty tabs for undefined categories
            tabs = []
        
        # Create sub-tabs for the current category
        if tabs:
            sub_tabs = st.tabs([tab["name"] for tab in tabs])
            
            # Load and display each tab's content
            for j, sub_tab in enumerate(sub_tabs):
                with sub_tab:
                    tab_module = tabs[j]["module"]
                    tab_function = load_tab_module(folder, tab_module)
                    
                    if tab_function:
                        # Call the tab's main function
                        tab_function()
                    else:
                        st.warning(f"Could not load content for tab: {tabs[j]['name']}")
        else:
            st.info(f"No tabs defined for {category['name']} yet.")

# Footer
st.markdown("---")
st.markdown("&copy; 2025 HealthAssist Dashboard")