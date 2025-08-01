import pandas as pd
import numpy as np
import plotly.express as px
import plotly.graph_objects as go
from plotly.subplots import make_subplots
import plotly.figure_factory as ff
from sklearn.decomposition import PCA
from sklearn.manifold import TSNE
from sklearn.preprocessing import StandardScaler, LabelEncoder
from sklearn.ensemble import IsolationForest, RandomForestRegressor
from sklearn.cluster import DBSCAN
from sklearn.feature_selection import mutual_info_classif
from scipy import stats
from scipy.stats import entropy
from scipy.cluster.hierarchy import dendrogram, linkage
from scipy.spatial.distance import pdist, squareform
import re
import warnings
warnings.filterwarnings('ignore')

# ========================= MEMORY OPTIMIZATION =========================

def optimize_dataframe_memory(df):
    """Reduce memory usage by optimizing data types - can achieve 80%+ reduction"""
    initial_memory = df.memory_usage(deep=True).sum() / 1024**2
    
    # Optimize numeric columns
    for col in df.select_dtypes(include=['int']).columns:
        col_min, col_max = df[col].min(), df[col].max()
        
        if col_min >= 0:
            if col_max < 255:
                df[col] = df[col].astype(np.uint8)
            elif col_max < 65535:
                df[col] = df[col].astype(np.uint16)
            elif col_max < 4294967295:
                df[col] = df[col].astype(np.uint32)
        else:
            if col_min > -128 and col_max < 127:
                df[col] = df[col].astype(np.int8)
            elif col_min > -32768 and col_max < 32767:
                df[col] = df[col].astype(np.int16)
    
    # Optimize float columns
    for col in df.select_dtypes(include=['float']).columns:
        df[col] = pd.to_numeric(df[col], downcast='float')
    
    # Convert low-cardinality strings to category (saves massive memory)
    for col in df.select_dtypes(include=['object']).columns:
        if df[col].nunique() / len(df) < 0.5:  # Less than 50% unique
            df[col] = df[col].astype('category')
    
    final_memory = df.memory_usage(deep=True).sum() / 1024**2
    reduction = 100 * (initial_memory - final_memory) / initial_memory
    print(f"📈 Memory optimized: {initial_memory:.1f}MB → {final_memory:.1f}MB ({reduction:.1f}% reduction)")
    
    return df

def get_numeric_columns(df):
    """Extract all numeric columns from dataframe"""
    return df.select_dtypes(include=[np.number]).columns.tolist()

# ========================= ID RELATIONSHIP ANALYSIS =========================

def analyze_id_relationships(df, col1='ACCOUNT_NUMBER', col2='ACCOUNT_ID'):
    """Comprehensive analysis of relationship between two ID columns"""
    
    # Calculate bidirectional uniqueness
    col1_to_col2 = df.groupby(col1)[col2].nunique()
    col2_to_col1 = df.groupby(col2)[col1].nunique()
    
    # Detect relationship type
    max_col2_per_col1 = col1_to_col2.max()
    max_col1_per_col2 = col2_to_col1.max()
    
    def detect_type(max1, max2):
        if max1 == 1 and max2 == 1:
            return "One-to-One"
        elif max1 == 1:
            return f"Many-to-One ({col1} → {col2})"
        elif max2 == 1:
            return f"One-to-Many ({col1} → {col2})"
        else:
            return "Many-to-Many"
    
    # Calculate mutual information
    clean_df = df[[col1, col2]].dropna()
    if len(clean_df) > 50000:
        clean_df = clean_df.sample(50000, random_state=42)
    
    le1, le2 = LabelEncoder(), LabelEncoder()
    encoded_col1 = le1.fit_transform(clean_df[col1].astype(str))
    encoded_col2 = le2.fit_transform(clean_df[col2].astype(str))
    
    mi_score = mutual_info_classif(
        encoded_col1.reshape(-1, 1), 
        encoded_col2, 
        discrete_features=True
    )[0]
    
    h_col1 = entropy(np.bincount(encoded_col1))
    h_col2 = entropy(np.bincount(encoded_col2))
    normalized_mi = mi_score / min(h_col1, h_col2) if min(h_col1, h_col2) > 0 else 0
    
    results = {
        'relationship_type': detect_type(max_col1_per_col2, max_col2_per_col1),
        'cardinality': {
            col1: df[col1].nunique(),
            col2: df[col2].nunique(),
            'ratio': df[col1].nunique() / df[col2].nunique()
        },
        'mutual_information': {
            'score': mi_score,
            'normalized': normalized_mi,
            'strength': 'Strong' if normalized_mi > 0.7 else 'Moderate' if normalized_mi > 0.3 else 'Weak'
        },
        'mapping_distribution': {
            f'{col2}_per_{col1}': col1_to_col2.describe().to_dict(),
            f'{col1}_per_{col2}': col2_to_col1.describe().to_dict()
        }
    }
    
    return results

def plot_id_relationship_analysis(df, col1='ACCOUNT_NUMBER', col2='ACCOUNT_ID'):
    """Create comprehensive visualizations for ID relationship analysis"""
    
    # Get analysis results
    analysis = analyze_id_relationships(df, col1, col2)
    
    # Create subplots
    fig = make_subplots(
        rows=2, cols=2,
        subplot_titles=[
            'Cardinality Comparison',
            'Relationship Distribution',
            f'{col2}s per {col1}',
            f'{col1}s per {col2}'
        ],
        specs=[[{"secondary_y": False}, {"secondary_y": False}],
               [{"secondary_y": False}, {"secondary_y": False}]]
    )
    
    # 1. Cardinality comparison
    fig.add_trace(
        go.Bar(x=[col1, col2], 
               y=[analysis['cardinality'][col1], analysis['cardinality'][col2]],
               name='Unique Values',
               marker_color=['lightblue', 'lightcoral']),
        row=1, col=1
    )
    
    # 2. Data completeness
    completeness = pd.DataFrame({
        'Column': [col1, col2],
        'Complete': [df[col1].notnull().sum(), df[col2].notnull().sum()],
        'Missing': [df[col1].isnull().sum(), df[col2].isnull().sum()]
    })
    
    fig.add_trace(
        go.Bar(x=completeness['Column'], y=completeness['Complete'], 
               name='Complete', marker_color='green', opacity=0.7),
        row=1, col=2
    )
    fig.add_trace(
        go.Bar(x=completeness['Column'], y=completeness['Missing'], 
               name='Missing', marker_color='red', opacity=0.7),
        row=1, col=2
    )
    
    # 3 & 4. Relationship distributions
    col1_to_col2_counts = df.groupby(col1)[col2].nunique()
    col2_to_col1_counts = df.groupby(col2)[col1].nunique()
    
    fig.add_trace(
        go.Histogram(x=col1_to_col2_counts, name=f'{col2}s per {col1}', 
                     marker_color='lightblue', opacity=0.7),
        row=2, col=1
    )
    
    fig.add_trace(
        go.Histogram(x=col2_to_col1_counts, name=f'{col1}s per {col2}', 
                     marker_color='lightcoral', opacity=0.7),
        row=2, col=2
    )
    
    # Update layout
    relationship_type = analysis['relationship_type']
    mi_strength = analysis['mutual_information']['strength']
    fig.update_layout(
        title_text=f"ID Relationship Analysis: {relationship_type} | MI: {mi_strength}",
        height=800,
        showlegend=True
    )
    
    return fig

def plot_id_sankey_flow(df, col1='ACCOUNT_NUMBER', col2='ACCOUNT_ID', max_nodes=30):
    """Create Sankey diagram showing ID relationships (optimized for performance)"""
    
    # Sample and aggregate for performance
    if len(df) > 100000:
        sample_df = df[[col1, col2]].dropna().sample(50000, random_state=42)
    else:
        sample_df = df[[col1, col2]].dropna()
    
    # Get top connections by frequency
    flow_data = sample_df.groupby([col1, col2]).size().reset_index(name='count')
    flow_data = flow_data.nlargest(max_nodes, 'count')
    
    # Create nodes
    all_col1_vals = flow_data[col1].unique()
    all_col2_vals = flow_data[col2].unique()
    
    node_labels = [f"{col1}_{str(v)[:10]}" for v in all_col1_vals] + [f"{col2}_{str(v)[:10]}" for v in all_col2_vals]
    
    # Create indices
    col1_indices = {val: i for i, val in enumerate(all_col1_vals)}
    col2_indices = {val: i + len(all_col1_vals) for i, val in enumerate(all_col2_vals)}
    
    # Create Sankey
    fig = go.Figure(data=[go.Sankey(
        node=dict(
            pad=15,
            thickness=20,
            line=dict(color="black", width=0.5),
            label=node_labels,
            color="rgba(255,0,255,0.8)"
        ),
        link=dict(
            source=[col1_indices[row[col1]] for _, row in flow_data.iterrows()],
            target=[col2_indices[row[col2]] for _, row in flow_data.iterrows()],
            value=flow_data['count'].tolist(),
            color="rgba(255,0,255,0.4)"
        ))])
    
    fig.update_layout(
        title_text=f"ID Relationship Flow: {col1} → {col2} (Top {max_nodes} connections)", 
        font_size=10,
        height=600
    )
    
    return fig

# ========================= ENHANCED ORIGINAL FUNCTIONS =========================

def plot_missing_data_heatmap(df, max_cols=50, focus_cols=None):
    """Enhanced missing data heatmap with memory optimization"""
    
    # Prioritize focus columns if provided
    if focus_cols:
        cols_to_plot = focus_cols + [col for col in df.columns[:max_cols-len(focus_cols)] if col not in focus_cols]
    else:
        cols_to_plot = df.columns[:max_cols] if len(df.columns) > max_cols else df.columns
    
    # Sample large datasets for performance
    if len(df) > 50000:
        sample_df = df[cols_to_plot].sample(20000, random_state=42)
        title_suffix = " (20K sample)"
    else:
        sample_df = df[cols_to_plot]
        title_suffix = ""
    
    missing_matrix = sample_df.isnull().astype(int)
    
    fig = px.imshow(
        missing_matrix.T, 
        title=f"Missing Data Heatmap{title_suffix}",
        labels=dict(x="Record Index", y="Column", color="Missing"),
        color_continuous_scale=['white', 'red'],
        aspect='auto'
    )
    
    fig.update_layout(
        height=max(400, len(cols_to_plot) * 15),
        xaxis_title="Record Index",
        yaxis_title="Columns"
    )
    
    return fig

def plot_correlation_clustermap(df, top_n=50, method='complete', exclude_ids=True):
    """Enhanced correlation heatmap with ID column handling"""
    numeric_cols = get_numeric_columns(df)
    
    # Exclude ID columns if requested (they often have spurious correlations)
    if exclude_ids:
        id_patterns = ['id', 'number', 'key', 'code']
        numeric_cols = [col for col in numeric_cols 
                       if not any(pattern in col.lower() for pattern in id_patterns)]
    
    # Select top N most variable columns
    if len(numeric_cols) > top_n:
        variances = df[numeric_cols].var().sort_values(ascending=False)
        numeric_cols = variances.head(top_n).index.tolist()
    
    if len(numeric_cols) < 2:
        return None
    
    # Use sample for large datasets
    if len(df) > 100000:
        sample_df = df[numeric_cols].sample(50000, random_state=42).fillna(0)
    else:
        sample_df = df[numeric_cols].fillna(0)
    
    corr_matrix = sample_df.corr()
    
    # Hierarchical clustering for better organization
    linkage_matrix = linkage(pdist(corr_matrix), method=method)
    dendro = dendrogram(linkage_matrix, labels=corr_matrix.index, no_plot=True)
    reordered_cols = [corr_matrix.index[i] for i in dendro['leaves']]
    
    corr_reordered = corr_matrix.loc[reordered_cols, reordered_cols]
    
    fig = px.imshow(
        corr_reordered,
        title=f"Correlation Heatmap with Clustering (Top {len(numeric_cols)} Features)",
        color_continuous_scale='RdBu_r',
        zmin=-1, zmax=1,
        aspect='auto'
    )
    
    fig.update_layout(height=800, width=800)
    
    return fig

def plot_distribution_grid(df, max_features=20, bins=50, focus_cols=None):
    """Enhanced distribution grid with focus column prioritization"""
    numeric_cols = get_numeric_columns(df)
    
    # Prioritize focus columns
    if focus_cols:
        focus_numeric = [col for col in focus_cols if col in numeric_cols]
        other_numeric = [col for col in numeric_cols if col not in focus_cols]
        
        # Calculate scores for remaining columns
        if len(focus_numeric) < max_features and other_numeric:
            needed = max_features - len(focus_numeric)
            if len(other_numeric) > needed:
                feature_scores = df[other_numeric].apply(
                    lambda x: abs(x.skew()) + x.var()/df[other_numeric].var().max()
                ).sort_values(ascending=False)
                other_numeric = feature_scores.head(needed).index.tolist()
        
        numeric_cols = focus_numeric + other_numeric[:max_features-len(focus_numeric)]
    else:
        # Select most interesting columns
        if len(numeric_cols) > max_features:
            feature_scores = df[numeric_cols].apply(
                lambda x: abs(x.skew()) + x.var()/x.var().max() if x.var() > 0 else 0
            ).sort_values(ascending=False)
            numeric_cols = feature_scores.head(max_features).index.tolist()
    
    if len(numeric_cols) == 0:
        return None
    
    n_cols = 4
    n_rows = (len(numeric_cols) + n_cols - 1) // n_cols
    
    fig = make_subplots(
        rows=n_rows, cols=n_cols,
        subplot_titles=numeric_cols,
        vertical_spacing=0.08,
        horizontal_spacing=0.05
    )
    
    for i, col in enumerate(numeric_cols):
        row = i // n_cols + 1
        col_pos = i % n_cols + 1
        
        # Remove outliers for better visualization
        col_data = df[col].dropna()
        if len(col_data) > 0:
            Q1 = col_data.quantile(0.25)
            Q3 = col_data.quantile(0.75)
            IQR = Q3 - Q1
            if IQR > 0:
                filtered_data = col_data[(col_data >= Q1 - 1.5*IQR) & (col_data <= Q3 + 1.5*IQR)]
            else:
                filtered_data = col_data
            
            fig.add_trace(
                go.Histogram(x=filtered_data, nbinsx=bins, name=col, showlegend=False,
                           opacity=0.7),
                row=row, col=col_pos
            )
    
    fig.update_layout(
        title_text=f"Distribution Grid (Top {len(numeric_cols)} Features)",
        height=300*n_rows,
        showlegend=False
    )
    
    return fig

def plot_outlier_detection_comparison(df, max_features=15, sample_size=50000):
    """Enhanced outlier detection with sampling for performance"""
    numeric_cols = get_numeric_columns(df)
    
    # Sample for performance
    if len(df) > sample_size:
        sample_df = df[numeric_cols].sample(sample_size, random_state=42)
    else:
        sample_df = df[numeric_cols]
    
    if len(numeric_cols) > max_features:
        variances = sample_df.var().sort_values(ascending=False)
        numeric_cols = variances.head(max_features).index.tolist()
        sample_df = sample_df[numeric_cols]
    
    outlier_results = []
    
    for col in numeric_cols:
        col_data = sample_df[col].dropna()
        if len(col_data) < 10:
            continue
            
        # IQR method
        Q1 = col_data.quantile(0.25)
        Q3 = col_data.quantile(0.75)
        IQR = Q3 - Q1
        iqr_outliers = len(col_data[(col_data < Q1 - 1.5*IQR) | (col_data > Q3 + 1.5*IQR)])
        
        # Z-score method (more robust)
        z_scores = np.abs(stats.zscore(col_data))
        zscore_outliers = len(col_data[z_scores > 3])
        
        # Modified Z-score (even more robust)
        median = col_data.median()
        mad = np.median(np.abs(col_data - median))
        if mad > 0:
            modified_z_scores = 0.6745 * (col_data - median) / mad
            modified_outliers = len(col_data[np.abs(modified_z_scores) > 3.5])
        else:
            modified_outliers = 0
        
        outlier_results.append({
            'Feature': col,
            'IQR': iqr_outliers,
            'Z-Score': zscore_outliers,
            'Modified Z-Score': modified_outliers,
            'Total_Records': len(col_data)
        })
    
    results_df = pd.DataFrame(outlier_results)
    
    # Convert to percentages
    for method in ['IQR', 'Z-Score', 'Modified Z-Score']:
        results_df[f'{method}_Pct'] = (results_df[method] / results_df['Total_Records']) * 100
    
    fig = go.Figure()
    
    methods = ['IQR_Pct', 'Z-Score_Pct', 'Modified Z-Score_Pct']
    colors = ['red', 'blue', 'green']
    
    for method, color in zip(methods, colors):
        fig.add_trace(go.Bar(
            x=results_df['Feature'],
            y=results_df[method],
            name=method.replace('_Pct', ''),
            marker_color=color,
            opacity=0.7
        ))
    
    sample_note = f" (Sample: {len(sample_df):,} records)" if len(df) > sample_size else ""
    fig.update_layout(
        title=f"Outlier Detection Comparison{sample_note}",
        xaxis_title="Features",
        yaxis_title="Outlier Percentage (%)",
        barmode='group',
        height=600,
        xaxis_tickangle=-45
    )
    
    return fig

def plot_pca_analysis(df, n_components=10, exclude_ids=True):
    """Enhanced PCA analysis with ID column handling"""
    numeric_cols = get_numeric_columns(df)
    
    # Exclude ID columns for better PCA results
    if exclude_ids:
        id_patterns = ['id', 'number', 'key', 'code']
        numeric_cols = [col for col in numeric_cols 
                       if not any(pattern in col.lower() for pattern in id_patterns)]
    
    if len(numeric_cols) < 2:
        return None
    
    # Sample for performance
    if len(df) > 100000:
        data_clean = df[numeric_cols].sample(50000, random_state=42).fillna(df[numeric_cols].median())
    else:
        data_clean = df[numeric_cols].fillna(df[numeric_cols].median())
    
    scaler = StandardScaler()
    data_scaled = scaler.fit_transform(data_clean)
    
    # Fit PCA
    n_components = min(n_components, len(numeric_cols), len(data_clean))
    pca = PCA(n_components=n_components)
    pca_result = pca.fit_transform(data_scaled)
    
    # Create comprehensive PCA visualization
    fig = make_subplots(
        rows=2, cols=2,
        subplot_titles=[
            'Explained Variance Ratio',
            'Cumulative Explained Variance',
            'PCA Scatter Plot (PC1 vs PC2)',
            'Feature Loadings (PC1 vs PC2)'
        ]
    )
    
    # Explained variance ratio
    fig.add_trace(
        go.Bar(x=list(range(1, len(pca.explained_variance_ratio_)+1)), 
               y=pca.explained_variance_ratio_,
               name='Explained Variance',
               marker_color='lightblue'),
        row=1, col=1
    )
    
    # Cumulative explained variance
    cumsum_var = np.cumsum(pca.explained_variance_ratio_)
    fig.add_trace(
        go.Scatter(x=list(range(1, len(cumsum_var)+1)), 
                   y=cumsum_var,
                   mode='lines+markers',
                   name='Cumulative Variance',
                   line=dict(color='red')),
        row=1, col=2
    )
    
    # PCA scatter plot
    fig.add_trace(
        go.Scatter(x=pca_result[:, 0], 
                   y=pca_result[:, 1],
                   mode='markers',
                   name='Data Points',
                   opacity=0.6,
                   marker=dict(color='blue', size=4)),
        row=2, col=1
    )
    
    # Feature loadings (top contributors only for clarity)
    loadings = pca.components_[:2].T
    loading_importance = np.sum(np.abs(loadings), axis=1)
    top_features_idx = np.argsort(loading_importance)[-15:]  # Top 15 features
    
    for i in top_features_idx:
        feature = numeric_cols[i]
        fig.add_trace(
            go.Scatter(x=[0, loadings[i, 0]], 
                       y=[0, loadings[i, 1]],
                       mode='lines+text',
                       text=['', feature],
                       textposition='top center',
                       name=feature,
                       showlegend=False,
                       line=dict(width=2)),
            row=2, col=2
        )
    
    total_variance = sum(pca.explained_variance_ratio_)
    fig.update_layout(
        title_text=f"PCA Analysis (Total Variance Explained: {total_variance:.2%})",
        height=800,
        showlegend=True
    )
    
    return fig

def plot_feature_importance_analysis(df, target_col=None, max_features=20, exclude_ids=True):
    """Enhanced feature importance with better target selection"""
    numeric_cols = get_numeric_columns(df)
    
    # Exclude ID columns
    if exclude_ids:
        id_patterns = ['id', 'number', 'key', 'code']
        numeric_cols = [col for col in numeric_cols 
                       if not any(pattern in col.lower() for pattern in id_patterns)]
    
    if len(numeric_cols) < 2:
        return None
    
    # Sample for performance
    if len(df) > 100000:
        sample_df = df[numeric_cols].sample(50000, random_state=42)
    else:
        sample_df = df[numeric_cols]
    
    # Better target selection
    if target_col is None or target_col not in numeric_cols:
        # Use the column with highest variance as target
        variances = sample_df.var()
        target_col = variances.idxmax()
    
    target = sample_df[target_col].fillna(sample_df[target_col].median())
    feature_cols = [col for col in numeric_cols if col != target_col]
    features = sample_df[feature_cols].fillna(sample_df[feature_cols].median())
    
    # Random Forest for feature importance
    rf = RandomForestRegressor(n_estimators=100, random_state=42, n_jobs=-1)
    rf.fit(features, target)
    
    # Get feature importance
    importance_df = pd.DataFrame({
        'Feature': feature_cols,
        'Importance': rf.feature_importances_
    }).sort_values('Importance', ascending=False).head(max_features)
    
    fig = px.bar(
        importance_df, 
        x='Importance', 
        y='Feature',
        orientation='h',
        title=f'Top {max_features} Feature Importance (Target: {target_col})',
        labels={'Importance': 'Feature Importance Score'},
        color='Importance',
        color_continuous_scale='viridis'
    )
    
    fig.update_layout(
        height=max(400, len(importance_df) * 25),
        yaxis={'categoryorder': 'total ascending'}
    )
    
    return fig

# ========================= ENHANCED DASHBOARD =========================

def create_comprehensive_dashboard(df, id_cols=['ACCOUNT_NUMBER', 'ACCOUNT_ID']):
    """Enhanced dashboard with memory optimization and ID analysis"""
    print("🎯 Creating Enhanced Comprehensive Dashboard...")
    print("=" * 60)
    
    figures = {}
    
    # Step 0: Memory optimization
    print("🔧 Optimizing memory usage...")
    df_optimized = optimize_dataframe_memory(df.copy())
    
    # Step 1: ID relationship analysis (if ID columns exist)
    if all(col in df_optimized.columns for col in id_cols):
        print("🔗 Creating ID relationship analysis...")
        figures['id_relationship'] = plot_id_relationship_analysis(df_optimized, id_cols[0], id_cols[1])
        figures['id_sankey'] = plot_id_sankey_flow(df_optimized, id_cols[0], id_cols[1])
    
    # Step 2: Enhanced missing data analysis
    print("📊 Creating missing data visualizations...")
    figures['missing_heatmap'] = plot_missing_data_heatmap(df_optimized, focus_cols=id_cols)
    
    # Step 3: Enhanced correlation analysis
    print("🔗 Creating correlation analysis...")
    figures['correlation_clustermap'] = plot_correlation_clustermap(df_optimized, exclude_ids=True)
    
    # Step 4: Enhanced distribution analysis
    print("📈 Creating distribution analysis...")
    figures['distribution_grid'] = plot_distribution_grid(df_optimized, focus_cols=id_cols)
    
    # Step 5: Enhanced outlier detection
    print("🚨 Creating outlier detection comparison...")
    figures['outlier_comparison'] = plot_outlier_detection_comparison(df_optimized)
    
    # Step 6: Enhanced PCA analysis
    print("🎯 Creating PCA analysis...")
    figures['pca_analysis'] = plot_pca_analysis(df_optimized, exclude_ids=True)
    
    # Step 7: Enhanced feature importance
    print("⭐ Creating feature importance analysis...")
    figures['feature_importance'] = plot_feature_importance_analysis(df_optimized, exclude_ids=True)
    
    print("✅ Enhanced dashboard creation completed!")
    print(f"📊 Generated {len([f for f in figures.values() if f is not None])} visualizations")
    print(f"💾 Optimized dataframe memory usage")
    
    return figures, df_optimized

def show_all_plots(figures):
    """Display all generated plots with enhanced descriptions"""
    for name, fig in figures.items():
        if fig is not None:
            print(f"\n📊 Showing: {name.replace('_', ' ').title()}")
            fig.show()
        else:
            print(f"⚠️ Skipped: {name.replace('_', ' ').title()} (insufficient data)")

def generate_analysis_summary(df, id_cols=['ACCOUNT_NUMBER', 'ACCOUNT_ID']):
    """Generate a comprehensive analysis summary"""
    print("\n" + "="*50)
    print("📋 ENHANCED DATASET ANALYSIS SUMMARY")
    print("="*50)
    
    print(f"📊 Dataset Shape: {df.shape[0]:,} rows × {df.shape[1]:,} columns")
    print(f"💾 Memory Usage: {df.memory_usage(deep=True).sum() / 1024**2:.1f} MB")
    
    # ID Analysis
    if all(col in df.columns for col in id_cols):
        print(f"\n🔗 ID Column Analysis:")
        id_analysis = analyze_id_relationships(df, id_cols[0], id_cols[1])
        print(f"   Relationship Type: {id_analysis['relationship_type']}")
        print(f"   {id_cols[0]} Unique: {id_analysis['cardinality'][id_cols[0]]:,}")
        print(f"   {id_cols[1]} Unique: {id_analysis['cardinality'][id_cols[1]]:,}")
        print(f"   Cardinality Ratio: {id_analysis['cardinality']['ratio']:.2f}")
        print(f"   Mutual Information: {id_analysis['mutual_information']['strength']}")
    
    # Data Quality
    print(f"\n📈 Data Quality Overview:")
    total_nulls = df.isnull().sum().sum()
    print(f"   Total Missing Values: {total_nulls:,} ({100*total_nulls/(df.shape[0]*df.shape[1]):.1f}%)")
    
    numeric_cols = get_numeric_columns(df)
    print(f"   Numeric Columns: {len(numeric_cols)}")
    print(f"   Categorical Columns: {len(df.select_dtypes(include=['object', 'category']).columns)}")
    
    print("\n✅ Analysis complete! Use show_all_plots(figures) to view visualizations.")

# ========================= EXAMPLE USAGE =========================

if __name__ == "__main__":
    # Example usage with synthetic data similar to your scenario
    np.random.seed(42)
    n_samples, n_features = 300000, 260  # Match your dataset size
    
    print("🚀 Running enhanced visualization suite on large dataset...")
    print(f"📊 Simulating dataset shape: {n_samples:,} × {n_features}")
    
    # Generate synthetic data that mimics your scenario
    base_features = np.random.randn(n_samples, 20)
    correlated_features = base_features + np.random.randn(n_samples, 20) * 0.3
    noise_features = np.random.randn(n_samples, n_features - 42)
    
    # Create ID columns with realistic cardinality
    account_numbers = np.random.randint(1000000, 1073000, n_samples)  # 73K unique
    account_ids = np.random.randint(2000000, 2063000, n_samples)      # 63K unique
    
    all_features = np.hstack([
        account_numbers.reshape(-1, 1),
        account_ids.reshape(-1, 1),
        base_features, 
        correlated_features, 
        noise_features
    ])
    
    # Add some outliers
    outlier_indices = np.random.choice(n_samples, size=1000, replace=False)
    all_features[outlier_indices] += np.random.randn(1000, n_features) * 5
    
    # Create DataFrame
    feature_names = ['ACCOUNT_NUMBER', 'ACCOUNT_ID'] + [f'feature_{i:03d}' for i in range(n_features-2)]
    sample_data = pd.DataFrame(all_features, columns=feature_names)
    
    # Add some missing data
    missing_mask = np.random.random((n_samples, n_features)) < 0.02  # 2% missing
    sample_data = sample_data.mask(missing_mask)
    
    # Run enhanced analysis
    print(f"🔍 Running comprehensive analysis...")
    figures, optimized_df = create_comprehensive_dashboard(sample_data)
    
    # Generate summary
    generate_analysis_summary(optimized_df)
    
    print(f"\n💡 To display all plots, run: show_all_plots(figures)")
    print(f"💡 Access individual plots: figures['id_relationship'].show()")
    print(f"💡 Optimized dataframe available as: optimized_df")
