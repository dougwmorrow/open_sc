import pandas as pd
import numpy as np
import warnings
from scipy import stats
from sklearn.ensemble import IsolationForest
from sklearn.preprocessing import StandardScaler
from sklearn.decomposition import PCA
from sklearn.cluster import DBSCAN
import plotly.express as px
import plotly.graph_objects as go
from plotly.subplots import make_subplots
import plotly.figure_factory as ff
import time

warnings.filterwarnings('ignore')

def get_numeric_columns(df):
    """Extract all numeric columns from dataframe"""
    return df.select_dtypes(include=[np.number]).columns.tolist()

def basic_data_overview(df):
    """Comprehensive overview of the dataset"""
    print("=" * 60)
    print("DATASET OVERVIEW")
    print("=" * 60)
    
    print(f"Shape: {df.shape}")
    print(f"Memory usage: {df.memory_usage(deep=True).sum() / 1024**2:.2f} MB")
    print(f"Numeric columns: {len(get_numeric_columns(df))}")
    print(f"Non-numeric columns: {len(df.columns) - len(get_numeric_columns(df))}")
    
    # Missing data summary
    missing_data = df.isnull().sum()
    missing_pct = (missing_data / len(df)) * 100
    missing_summary = pd.DataFrame({
        'Missing_Count': missing_data,
        'Missing_Percentage': missing_pct
    }).sort_values('Missing_Count', ascending=False)
    
    print(f"\nColumns with missing data: {len(missing_summary[missing_summary['Missing_Count'] > 0])}")
    print(f"Total missing values: {missing_data.sum()}")
    
    # Show top 10 columns with most missing data
    top_missing = missing_summary[missing_summary['Missing_Count'] > 0].head(10)
    if len(top_missing) > 0:
        print("\nTOP 10 COLUMNS WITH MISSING DATA:")
        print(top_missing.to_string())
    
    # Data types
    print("\nDATA TYPES:")
    print(df.dtypes.value_counts())
    
    return missing_summary

def statistical_summary_numeric(df, max_columns_display=20):
    """Detailed statistical summary for numeric columns with smart display"""
    numeric_cols = get_numeric_columns(df)
    
    if not numeric_cols:
        print("No numeric columns found!")
        return None
    
    print("=" * 60)
    print(f"STATISTICAL SUMMARY - NUMERIC COLUMNS ({len(numeric_cols)} total)")
    print("=" * 60)
    
    # Enhanced describe with additional statistics
    print("Computing statistical summary...")
    summary_stats = df[numeric_cols].describe().T
    
    # Add additional statistics
    summary_stats['variance'] = df[numeric_cols].var()
    summary_stats['skewness'] = df[numeric_cols].skew()
    summary_stats['kurtosis'] = df[numeric_cols].kurtosis()
    summary_stats['range'] = summary_stats['max'] - summary_stats['min']
    summary_stats['iqr'] = summary_stats['75%'] - summary_stats['25%']
    summary_stats['cv'] = summary_stats['std'] / summary_stats['mean']  # Coefficient of variation
    
    # Display most interesting columns (highest variance, skewness, etc.)
    print(f"\nShowing top {min(max_columns_display, len(numeric_cols))} most variable columns:")
    most_variable = summary_stats.nlargest(max_columns_display, 'cv')
    print(most_variable.round(4))
    
    # Create interactive table for all statistics
    create_interactive_stats_table(summary_stats)
    
    return summary_stats

def create_interactive_stats_table(summary_stats):
    """Create interactive statistics table"""
    fig = go.Figure(data=[go.Table(
        header=dict(values=list(['Column'] + list(summary_stats.columns)),
                   fill_color='paleturquoise',
                   align='left'),
        cells=dict(values=[summary_stats.index] + [summary_stats[col].round(4) for col in summary_stats.columns],
                  fill_color='lavender',
                  align='left'))
    ])
    
    fig.update_layout(
        title="Complete Statistical Summary (Interactive)",
        height=600
    )
    
    fig.show()

def detect_outliers_iqr_batch(df, multiplier=1.5, max_columns_process=50):
    """Detect outliers using IQR method with batch processing"""
    numeric_cols = get_numeric_columns(df)
    outlier_summary = {}
    
    print("=" * 60)
    print(f"IQR OUTLIER DETECTION ({len(numeric_cols)} columns)")
    print("=" * 60)
    
    # Process in batches for memory efficiency
    batch_size = max_columns_process
    total_outliers = 0
    total_batches = (len(numeric_cols) + batch_size - 1) // batch_size
    
    for batch_num, i in enumerate(range(0, len(numeric_cols), batch_size)):
        print(f"Processing batch {batch_num + 1}/{total_batches}...")
        batch_cols = numeric_cols[i:i+batch_size]
        
        for col in batch_cols:
            if df[col].notna().sum() < 2:
                continue
                
            Q1 = df[col].quantile(0.25)
            Q3 = df[col].quantile(0.75)
            IQR = Q3 - Q1
            
            lower_bound = Q1 - multiplier * IQR
            upper_bound = Q3 + multiplier * IQR
            
            outliers = df[(df[col] < lower_bound) | (df[col] > upper_bound)]
            
            outlier_summary[col] = {
                'count': len(outliers),
                'percentage': (len(outliers) / len(df)) * 100,
                'lower_bound': lower_bound,
                'upper_bound': upper_bound,
            }
            total_outliers += len(outliers)
    
    # Show summary of columns with most outliers
    outlier_df = pd.DataFrame(outlier_summary).T.sort_values('count', ascending=False)
    print(f"\nTotal outliers detected: {total_outliers}")
    print(f"Columns with outliers: {len(outlier_df[outlier_df['count'] > 0])}")
    print("\nTop 10 columns with most outliers:")
    print(outlier_df.head(10))
    
    return outlier_summary

def detect_outliers_zscore_batch(df, threshold=3, max_columns_process=50):
    """Detect outliers using Z-score method with batch processing"""
    numeric_cols = get_numeric_columns(df)
    outlier_summary = {}
    
    print("=" * 60)
    print(f"Z-SCORE OUTLIER DETECTION ({len(numeric_cols)} columns)")
    print("=" * 60)
    
    batch_size = max_columns_process
    total_outliers = 0
    total_batches = (len(numeric_cols) + batch_size - 1) // batch_size
    
    for batch_num, i in enumerate(range(0, len(numeric_cols), batch_size)):
        print(f"Processing batch {batch_num + 1}/{total_batches}...")
        batch_cols = numeric_cols[i:i+batch_size]
        
        for col in batch_cols:
            if df[col].notna().sum() < 2:
                continue
                
            z_scores = np.abs(stats.zscore(df[col].dropna()))
            outlier_indices = df[col].dropna().index[z_scores > threshold].tolist()
            
            outlier_summary[col] = {
                'count': len(outlier_indices),
                'percentage': (len(outlier_indices) / len(df)) * 100,
                'threshold': threshold,
                'max_zscore': z_scores.max() if len(z_scores) > 0 else 0,
            }
            total_outliers += len(outlier_indices)
    
    # Show summary
    outlier_df = pd.DataFrame(outlier_summary).T.sort_values('count', ascending=False)
    print(f"\nTotal outliers detected: {total_outliers}")
    print("Top 10 columns with most outliers:")
    print(outlier_df.head(10))
    
    return outlier_summary

def detect_outliers_isolation_forest_smart(df, contamination=0.1, max_features=20):
    """Smart Isolation Forest that selects most important features"""
    numeric_cols = get_numeric_columns(df)
    
    if len(numeric_cols) == 0:
        print("No numeric columns for Isolation Forest analysis!")
        return None
    
    print("=" * 60)
    print("ISOLATION FOREST OUTLIER DETECTION (Smart Feature Selection)")
    print("=" * 60)
    
    # Select most variable features for analysis
    feature_variance = df[numeric_cols].var().sort_values(ascending=False)
    selected_features = feature_variance.head(max_features).index.tolist()
    
    print(f"Selected {len(selected_features)} most variable features out of {len(numeric_cols)}")
    print(f"Selected features: {selected_features[:10]}{'...' if len(selected_features) > 10 else ''}")
    
    # Prepare data
    numeric_data = df[selected_features].fillna(df[selected_features].median())
    
    # Standardize the data
    scaler = StandardScaler()
    scaled_data = scaler.fit_transform(numeric_data)
    
    # Apply Isolation Forest
    iso_forest = IsolationForest(contamination=contamination, random_state=42, n_estimators=100)
    outlier_labels = iso_forest.fit_predict(scaled_data)
    outlier_scores = iso_forest.score_samples(scaled_data)
    
    # Create results dataframe
    results_df = df.copy()
    results_df['outlier_score'] = outlier_scores
    results_df['is_outlier'] = outlier_labels == -1
    
    outliers = results_df[results_df['is_outlier']]
    
    print(f"Total outliers detected: {len(outliers)} ({(len(outliers)/len(df)*100):.2f}%)")
    print(f"Outlier score range: {outlier_scores.min():.4f} to {outlier_scores.max():.4f}")
    
    return {
        'results_df': results_df,
        'outliers': outliers,
        'outlier_scores': outlier_scores,
        'selected_features': selected_features
    }

def correlation_analysis_smart(df, top_correlations=50, min_correlation=0.3):
    """Smart correlation analysis for high-dimensional data"""
    numeric_cols = get_numeric_columns(df)
    
    if len(numeric_cols) < 2:
        print("Need at least 2 numeric columns for correlation analysis!")
        return None
    
    print("=" * 60)
    print(f"CORRELATION ANALYSIS ({len(numeric_cols)} columns)")
    print("=" * 60)
    
    print("Computing correlation matrix...")
    # Calculate correlation matrix in chunks if too large
    if len(numeric_cols) > 100:
        print("Large dataset detected - using efficient correlation computation...")
        # Sample data for correlation if dataset is very large
        sample_size = min(10000, len(df))
        sample_df = df[numeric_cols].sample(sample_size) if len(df) > sample_size else df[numeric_cols]
        corr_matrix = sample_df.corr()
    else:
        corr_matrix = df[numeric_cols].corr()
    
    # Find all significant correlations
    correlations = []
    for i in range(len(corr_matrix.columns)):
        for j in range(i+1, len(corr_matrix.columns)):
            corr_val = corr_matrix.iloc[i, j]
            if abs(corr_val) >= min_correlation:
                correlations.append({
                    'var1': corr_matrix.columns[i],
                    'var2': corr_matrix.columns[j],
                    'correlation': corr_val,
                    'abs_correlation': abs(corr_val)
                })
    
    # Sort by absolute correlation
    correlations = sorted(correlations, key=lambda x: x['abs_correlation'], reverse=True)
    
    print(f"Found {len(correlations)} correlations >= {min_correlation}")
    
    if correlations:
        print(f"\nTop {min(top_correlations, len(correlations))} correlations:")
        for i, corr in enumerate(correlations[:top_correlations]):
            print(f"{i+1:2d}. {corr['var1']} <-> {corr['var2']}: {corr['correlation']:.4f}")
        
        # Create interactive correlation network
        create_correlation_network(correlations[:top_correlations])
        
        # Create heatmap for top correlated variables
        if len(correlations) > 0:
            top_vars = set()
            for corr in correlations[:top_correlations]:
                top_vars.add(corr['var1'])
                top_vars.add(corr['var2'])
            
            if len(top_vars) <= 50:  # Only create heatmap if manageable size
                create_correlation_heatmap(df[list(top_vars)].corr())
    
    return corr_matrix, correlations

def create_correlation_network(correlations):
    """Create network visualization of correlations"""
    if not correlations:
        return
    
    # Prepare data for network plot
    nodes = set()
    for corr in correlations:
        nodes.add(corr['var1'])
        nodes.add(corr['var2'])
    
    nodes = list(nodes)
    node_indices = {node: i for i, node in enumerate(nodes)}
    
    # Create edges
    edge_x = []
    edge_y = []
    edge_info = []
    
    # Simple circular layout
    import math
    n = len(nodes)
    angle_step = 2 * math.pi / n
    node_x = [math.cos(i * angle_step) for i in range(n)]
    node_y = [math.sin(i * angle_step) for i in range(n)]
    
    for corr in correlations[:30]:  # Limit edges for readability
        i = node_indices[corr['var1']]
        j = node_indices[corr['var2']]
        
        edge_x.extend([node_x[i], node_x[j], None])
        edge_y.extend([node_y[i], node_y[j], None])
        edge_info.append(f"{corr['var1']} - {corr['var2']}: {corr['correlation']:.3f}")
    
    # Create plot
    fig = go.Figure()
    
    # Add edges
    fig.add_trace(go.Scatter(
        x=edge_x, y=edge_y,
        line=dict(width=0.5, color='#888'),
        hoverinfo='none',
        mode='lines'
    ))
    
    # Add nodes
    fig.add_trace(go.Scatter(
        x=node_x, y=node_y,
        mode='markers+text',
        hoverinfo='text',
        text=nodes,
        hovertext=nodes,
        textposition="middle center",
        marker=dict(
            size=10,
            color='lightblue',
            line=dict(width=2, color='black')
        )
    ))
    
    fig.update_layout(
        title='Correlation Network (Top Correlations)',
        titlefont_size=16,
        showlegend=False,
        hovermode='closest',
        margin=dict(b=20,l=5,r=5,t=40),
        annotations=[ dict(
            text="Node connections show correlations >= threshold",
            showarrow=False,
            xref="paper", yref="paper",
            x=0.005, y=-0.002,
            xanchor='left', yanchor='bottom',
            font=dict(color='#888', size=12)
        )],
        xaxis=dict(showgrid=False, zeroline=False, showticklabels=False),
        yaxis=dict(showgrid=False, zeroline=False, showticklabels=False)
    )
    
    fig.show()

def create_correlation_heatmap(corr_matrix):
    """Create correlation heatmap for manageable number of variables"""
    fig = go.Figure(data=go.Heatmap(
        z=corr_matrix.values,
        x=corr_matrix.columns,
        y=corr_matrix.columns,
        colorscale='RdBu',
        zmid=0,
        text=np.round(corr_matrix.values, 2),
        texttemplate="%{text}",
        textfont={"size": 8},
        hoverongaps=False
    ))
    
    fig.update_layout(
        title='Correlation Heatmap (Top Correlated Variables)',
        xaxis_nticks=len(corr_matrix.columns),
        yaxis_nticks=len(corr_matrix.columns),
        width=800,
        height=700
    )
    
    fig.show()

def distribution_analysis_smart(df, max_plots=20, columns_to_analyze=None):
    """Smart distribution analysis with column selection"""
    numeric_cols = get_numeric_columns(df)
    
    if not numeric_cols:
        print("No numeric columns for distribution analysis!")
        return None
    
    print("=" * 60)
    print(f"DISTRIBUTION ANALYSIS ({len(numeric_cols)} total columns)")
    print("=" * 60)
    
    # Smart column selection if not specified
    if columns_to_analyze is None:
        # Select most interesting columns (highest variance, skewness, etc.)
        stats = df[numeric_cols].describe().T
        stats['variance'] = df[numeric_cols].var()
        stats['abs_skewness'] = abs(df[numeric_cols].skew())
        
        # Score columns by interestingness
        stats['interest_score'] = (
            stats['variance'].rank(ascending=False) + 
            stats['abs_skewness'].rank(ascending=False) +
            stats['std'].rank(ascending=False)
        ) / 3
        
        columns_to_analyze = stats.nsmallest(max_plots, 'interest_score').index.tolist()
    
    print(f"Analyzing {len(columns_to_analyze)} most interesting columns:")
    print(columns_to_analyze)
    
    distribution_stats = {}
    
    # Create subplots
    n_cols = min(3, len(columns_to_analyze))
    n_rows = (len(columns_to_analyze) + n_cols - 1) // n_cols
    
    fig = make_subplots(
        rows=n_rows, 
        cols=n_cols,
        subplot_titles=[f'Distribution of {col}' for col in columns_to_analyze],
        vertical_spacing=0.1
    )
    
    for i, col in enumerate(columns_to_analyze):
        row = i // n_cols + 1
        col_pos = i % n_cols + 1
        
        # Create histogram
        fig.add_trace(
            go.Histogram(
                x=df[col].dropna(),
                nbinsx=50,
                opacity=0.7,
                name=col,
                showlegend=False
            ),
            row=row, col=col_pos
        )
        
        # Add statistics
        mean_val = df[col].mean()
        median_val = df[col].median()
        
        fig.add_vline(
            x=mean_val,
            line_dash="dash",
            line_color="red",
            row=row, col=col_pos,
            annotation_text=f"Mean: {mean_val:.2f}",
            annotation_position="top"
        )
        
        fig.add_vline(
            x=median_val,
            line_dash="dash", 
            line_color="green",
            row=row, col=col_pos,
            annotation_text=f"Median: {median_val:.2f}",
            annotation_position="bottom"
        )
        
        # Normality test
        if df[col].notna().sum() > 3:
            sample_size = min(5000, len(df[col].dropna()))
            sample_data = df[col].dropna().sample(sample_size) if len(df[col].dropna()) > sample_size else df[col].dropna()
            shapiro_stat, shapiro_p = stats.shapiro(sample_data)
            distribution_stats[col] = {
                'shapiro_stat': shapiro_stat,
                'shapiro_p': shapiro_p,
                'is_normal': shapiro_p > 0.05,
                'skewness': df[col].skew(),
                'kurtosis': df[col].kurtosis()
            }
    
    fig.update_layout(
        height=400*n_rows,
        title_text=f"Distribution Analysis - Top {len(columns_to_analyze)} Most Interesting Columns",
        showlegend=False
    )
    
    fig.show()
    
    # Print normality test results
    print("\nNORMALITY TEST RESULTS (Shapiro-Wilk):")
    for col, stats_dict in distribution_stats.items():
        normal_status = "Normal" if stats_dict['is_normal'] else "Not Normal"
        print(f"{col}: {normal_status} (p-value: {stats_dict['shapiro_p']:.6f})")
    
    return distribution_stats

def missing_data_analysis_smart(df):
    """Smart missing data analysis for high-dimensional data"""
    print("=" * 60)
    print("MISSING DATA ANALYSIS")
    print("=" * 60)
    
    # Missing data patterns
    missing_counts = df.isnull().sum()
    missing_percentages = (missing_counts / len(df)) * 100
    
    missing_df = pd.DataFrame({
        'Column': missing_counts.index,
        'Missing_Count': missing_counts.values,
        'Missing_Percentage': missing_percentages.values
    }).sort_values('Missing_Count', ascending=False)
    
    # Show columns with missing data
    missing_cols = missing_df[missing_df['Missing_Count'] > 0]
    
    print(f"Columns with missing data: {len(missing_cols)} out of {len(df.columns)}")
    print(f"Total missing values: {missing_counts.sum()}")
    
    if len(missing_cols) > 0:
        print("\nTop 20 columns with most missing data:")
        print(missing_cols.head(20).to_string(index=False))
        
        # Missing data bar plot - only show columns with missing data
        top_missing = missing_cols.head(50)  # Show top 50 for readability
        
        fig = px.bar(
            top_missing,
            x='Column',
            y='Missing_Percentage',
            title=f'Missing Data Percentage by Column (Top {len(top_missing)})',
            labels={'Missing_Percentage': 'Missing Percentage (%)'}
        )
        
        fig.update_layout(
            xaxis_tickangle=-45,
            height=500
        )
        
        fig.show()
        
        # Create missing data pattern analysis
        if len(missing_cols) <= 50:  # Only for manageable number of columns
            create_missing_pattern_analysis(df, missing_cols['Column'].head(30).tolist())
    else:
        print("No missing data found!")
    
    return missing_df

def create_missing_pattern_analysis(df, columns_with_missing):
    """Analyze patterns in missing data"""
    missing_patterns = df[columns_with_missing].isnull()
    
    # Find common missing patterns
    pattern_counts = missing_patterns.value_counts().head(10)
    
    print(f"\nTop 10 missing data patterns:")
    for i, (pattern, count) in enumerate(pattern_counts.items()):
        missing_cols = [col for col, is_miss in zip(columns_with_missing, pattern) if is_miss]
        print(f"{i+1}. Pattern occurs {count} times - Missing in: {missing_cols[:5]}{'...' if len(missing_cols) > 5 else ''}")

def cluster_analysis_smart(df, max_features=20):
    """Smart clustering analysis for high-dimensional data"""
    numeric_cols = get_numeric_columns(df)
    
    if len(numeric_cols) < 2:
        print("Need at least 2 numeric columns for clustering!")
        return None
    
    print("=" * 60)
    print(f"CLUSTER ANALYSIS ({len(numeric_cols)} columns)")
    print("=" * 60)
    
    # Select most important features for clustering
    feature_variance = df[numeric_cols].var().sort_values(ascending=False)
    selected_features = feature_variance.head(max_features).index.tolist()
    
    print(f"Selected {len(selected_features)} most variable features for clustering")
    print(f"Selected features: {selected_features}")
    
    # Prepare data
    numeric_data = df[selected_features].fillna(df[selected_features].median())
    scaler = StandardScaler()
    scaled_data = scaler.fit_transform(numeric_data)
    
    # DBSCAN clustering
    dbscan = DBSCAN(eps=0.5, min_samples=5)
    cluster_labels = dbscan.fit_predict(scaled_data)
    
    n_clusters_found = len(set(cluster_labels)) - (1 if -1 in cluster_labels else 0)
    n_noise = list(cluster_labels).count(-1)
    
    print(f"DBSCAN Results:")
    print(f"Number of clusters: {n_clusters_found}")
    print(f"Number of noise points: {n_noise}")
    
    # Add cluster labels to results
    results_df = df.copy()
    results_df['cluster'] = cluster_labels
    
    # PCA for visualization
    pca = PCA(n_components=2)
    pca_data = pca.fit_transform(scaled_data)
    
    # Create PCA scatter plot
    fig = px.scatter(
        x=pca_data[:, 0],
        y=pca_data[:, 1],
        color=cluster_labels.astype(str),
        title=f'PCA Visualization of Clusters<br>Features used: {len(selected_features)}, Explained Variance: {sum(pca.explained_variance_ratio_):.2f}',
        labels={
            'x': f'PC1 ({pca.explained_variance_ratio_[0]:.2f})',
            'y': f'PC2 ({pca.explained_variance_ratio_[1]:.2f})',
            'color': 'Cluster'
        }
    )
    
    fig.update_layout(width=800, height=600)
    fig.show()
    
    return {
        'cluster_labels': cluster_labels,
        'n_clusters': n_clusters_found,
        'n_noise': n_noise,
        'results_df': results_df,
        'selected_features': selected_features
    }

def comprehensive_eda_report_smart(df, max_features_correlation=100, max_plots_distribution=20):
    """Smart comprehensive EDA for high-dimensional data"""
    print("🔍 COMPREHENSIVE EDA REPORT (OPTIMIZED FOR HIGH-DIMENSIONAL DATA)")
    print("=" * 80)
    
    start_time = time.time()
    
    # 1. Basic overview
    print("📊 Step 1/7: Basic Data Overview")
    missing_summary = basic_data_overview(df)
    
    # 2. Statistical summary
    print("\n📈 Step 2/7: Statistical Summary")
    stats_summary = statistical_summary_numeric(df)
    
    # 3. Missing data analysis
    print("\n❓ Step 3/7: Missing Data Analysis")
    missing_analysis = missing_data_analysis_smart(df)
    
    # 4. Distribution analysis (smart selection)
    print("\n📊 Step 4/7: Distribution Analysis")
    dist_analysis = distribution_analysis_smart(df, max_plots=max_plots_distribution)
    
    # 5. Correlation analysis (smart)
    print("\n🔗 Step 5/7: Correlation Analysis")
    corr_matrix, correlations = correlation_analysis_smart(df)
    
    # 6. Outlier detection (batch processing)
    print("\n🚨 Step 6/7: Outlier Detection")
    iqr_outliers = detect_outliers_iqr_batch(df)
    isolation_results = detect_outliers_isolation_forest_smart(df)
    
    # 7. Cluster analysis (smart feature selection)
    print("\n🎯 Step 7/7: Cluster Analysis")
    cluster_results = cluster_analysis_smart(df)
    
    end_time = time.time()
    
    print("\n" + "=" * 80)
    print(f"✅ EDA REPORT COMPLETED in {end_time - start_time:.2f} seconds")
    print("=" * 80)
    
    return {
        'missing_summary': missing_summary,
        'stats_summary': stats_summary,
        'missing_analysis': missing_analysis,
        'distribution_analysis': dist_analysis,
        'correlation_matrix': corr_matrix,
        'correlations': correlations,
        'iqr_outliers': iqr_outliers,
        'isolation_outliers': isolation_results,
        'cluster_results': cluster_results,
        'execution_time': end_time - start_time
    }

def quick_anomaly_detection_smart(df):
    """Quick anomaly detection optimized for high-dimensional data"""
    print("🚨 QUICK ANOMALY DETECTION SUMMARY (HIGH-DIMENSIONAL)")
    print("=" * 60)
    
    numeric_cols = get_numeric_columns(df)
    
    if not numeric_cols:
        print("No numeric columns found for anomaly detection!")
        return None
    
    print(f"Processing {len(numeric_cols)} numeric columns...")
    
    # Quick IQR analysis on all columns
    print("Running IQR analysis...")
    iqr_results = detect_outliers_iqr_batch(df, max_columns_process=100)
    
    # Smart Isolation Forest on selected features
    print("Running Isolation Forest on selected features...")
    iso_results = detect_outliers_isolation_forest_smart(df, max_features=30)
    
    # Summary
    total_outliers_iqr = sum([result['count'] for result in iqr_results.values()])
    columns_with_outliers = len([col for col, result in iqr_results.items() if result['count'] > 0])
    
    print(f"\n📊 SUMMARY:")
    print(f"Total IQR outliers across all columns: {total_outliers_iqr}")
    print(f"Columns with outliers: {columns_with_outliers}/{len(numeric_cols)}")
    
    if iso_results:
        print(f"Isolation Forest outliers: {len(iso_results['outliers'])} ({len(iso_results['outliers'])/len(df)*100:.2f}%)")
    
    return {
        'iqr_results': iqr_results,
        'isolation_results': iso_results,
        'total_outliers_iqr': total_outliers_iqr,
        'columns_with_outliers': columns_with_outliers
    }

# Example usage for high-dimensional data:
if __name__ == "__main__":
    # Create high-dimensional sample data
    np.random.seed(42)
    n_samples = 1000
    n_features = 260
    
    print(f"Creating sample dataset with {n_samples} rows and {n_features} columns...")
    
    # Generate realistic high-dimensional data
    sample_data = pd.DataFrame()
    
    # Add various types of columns
    for i in range(n_features):
        if i < 50:  # Normal distributions
            sample_data[f'normal_{i}'] = np.random.normal(100, 15, n_samples)
        elif i < 100:  # Skewed distributions
            sample_data[f'skewed_{i}'] = np.random.exponential(2, n_samples)
        elif i < 150:  # With outliers
            base_data = np.random.normal(50, 5, int(n_samples * 0.95))
            outliers = np.random.normal(200, 10, n_samples - len(base_data))
            sample_data[f'outliers_{i}'] = np.concatenate([base_data, outliers])
        elif i < 200:  # Categorical-like numeric
            sample_data[f'categorical_{i}'] = np.random.choice([1, 2, 3, 4, 5], n_samples)
        else:  # With missing data
            data = np.random.normal(75, 20, n_samples)
            missing_mask = np.random.random(n_samples) < 0.1
            data[missing_mask] = np.nan
            sample_data[f'missing_{i}'] = data
    
    print("Running optimized EDA on high-dimensional sample data...")
    
    # Quick anomaly detection
    anomaly_results = quick_anomaly_detection_smart(sample_data)
    
    # Full comprehensive report (uncomment to run)
    # eda_results = comprehensive_eda_report_smart(sample_data)
