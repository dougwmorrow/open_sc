<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Data Lake File Structure</title>
    <style>
        body {
            font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif;
            max-width: 1000px;
            margin: 0 auto;
            padding: 20px;
            background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
            min-height: 100vh;
        }

        .container {
            background: white;
            border-radius: 15px;
            padding: 30px;
            box-shadow: 0 20px 40px rgba(0,0,0,0.1);
        }

        .header {
            text-align: center;
            margin-bottom: 30px;
        }

        h1 {
            color: #2c3e50;
            margin-bottom: 10px;
            font-size: 2.2em;
        }

        .subtitle {
            color: #7f8c8d;
            font-size: 1.1em;
            margin-bottom: 20px;
        }

        .network-drive {
            background: linear-gradient(135deg, #3498db, #2980b9);
            color: white;
            padding: 15px;
            border-radius: 10px;
            margin-bottom: 20px;
            display: flex;
            align-items: center;
            gap: 10px;
        }

        .drive-icon {
            font-size: 2em;
        }

        .tree {
            margin-left: 20px;
            border-left: 2px solid #e74c3c;
            padding-left: 20px;
            margin-bottom: 30px;
        }

        .folder {
            display: flex;
            align-items: center;
            margin: 8px 0;
            padding: 8px;
            border-radius: 8px;
            transition: all 0.3s ease;
        }

        .folder:hover {
            background-color: #f8f9fa;
            transform: translateX(5px);
        }

        .folder-icon {
            margin-right: 10px;
            font-size: 1.2em;
        }

        .folder-name {
            font-weight: bold;
            color: #2c3e50;
            margin-right: 10px;
        }

        .folder-description {
            color: #7f8c8d;
            font-style: italic;
        }

        .level-1 { margin-left: 0; }
        .level-2 { margin-left: 30px; }
        .level-3 { margin-left: 60px; }
        .level-4 { margin-left: 90px; }
        .level-5 { margin-left: 120px; }
        .level-6 { margin-left: 150px; }
        .level-7 { margin-left: 180px; }

        .example-section {
            background: #f8f9fa;
            border-radius: 10px;
            padding: 20px;
            margin: 20px 0;
        }

        .example-title {
            font-weight: bold;
            color: #2c3e50;
            margin-bottom: 15px;
            font-size: 1.1em;
        }

        .file-path {
            background: #2c3e50;
            color: #ecf0f1;
            padding: 15px;
            border-radius: 8px;
            font-family: 'Courier New', monospace;
            word-break: break-all;
            margin: 10px 0;
        }

        .benefits {
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(250px, 1fr));
            gap: 20px;
            margin-top: 30px;
        }

        .benefit-card {
            background: linear-gradient(135deg, #f093fb 0%, #f5576c 100%);
            color: white;
            padding: 20px;
            border-radius: 10px;
            text-align: center;
        }

        .benefit-icon {
            font-size: 2em;
            margin-bottom: 10px;
        }

        .data-flow {
            text-align: center;
            margin: 30px 0;
            padding: 20px;
            background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
            color: white;
            border-radius: 10px;
        }

        .flow-arrow {
            font-size: 2em;
            margin: 10px;
            color: #f39c12;
        }
    </style>
</head>
<body>
    <div class="container">
        <div class="header">
            <h1>📊 Data Lake File Structure</h1>
            <div class="subtitle">How your data will be organized on the network drive</div>
        </div>

        <div class="network-drive">
            <div class="drive-icon">🖥️</div>
            <div>
                <strong>Network Drive Storage</strong><br>
                Centralized location accessible by authorized users across the organization
            </div>
        </div>

        <div class="data-flow">
            <div><strong>Data Flow Process</strong></div>
            <div>Raw Data → Processing → Organized Storage → Easy Access</div>
            <div class="flow-arrow">⬇️</div>
        </div>

        <h2 style="color: #2c3e50; margin-bottom: 20px;">📁 Folder Structure Breakdown</h2>

        <div class="tree">
            <div class="folder level-1">
                <span class="folder-icon">📁</span>
                <span class="folder-name">VendorFiles</span>
                <span class="folder-description">Root folder for all vendor data</span>
            </div>

            <div class="folder level-2">
                <span class="folder-icon">🏢</span>
                <span class="folder-name">PROD</span>
                <span class="folder-description">Production environment (live data)</span>
            </div>

            <div class="folder level-3">
                <span class="folder-icon">👨‍💻</span>
                <span class="folder-name">SqlDeveloper</span>
                <span class="folder-description">Data source system identifier</span>
            </div>

            <div class="folder level-4">
                <span class="folder-icon">🌎</span>
                <span class="folder-name">CA</span>
                <span class="folder-description">Region/Country code (e.g., CA = Canada)</span>
            </div>

            <div class="folder level-5">
                <span class="folder-icon">📋</span>
                <span class="folder-name">{category}</span>
                <span class="folder-description">Data type (e.g., Sales, Customers, Inventory)</span>
            </div>

            <div class="folder level-6">
                <span class="folder-icon">📅</span>
                <span class="folder-name">{year}</span>
                <span class="folder-description">Year (e.g., 2024, 2025)</span>
            </div>

            <div class="folder level-7">
                <span class="folder-icon">📆</span>
                <span class="folder-name">{month}</span>
                <span class="folder-description">Month (e.g., 01, 02, 12)</span>
            </div>

            <div class="folder level-7" style="margin-left: 210px;">
                <span class="folder-icon">📊</span>
                <span class="folder-name">📄 Parquet Files</span>
                <span class="folder-description">Compressed data files with timestamps</span>
            </div>
        </div>

        <div class="example-section">
            <div class="example-title">🔍 Real-World Example</div>
            <p><strong>Scenario:</strong> Sales data from Canada processed on March 15, 2024 at 2:30 PM</p>
            <div class="file-path">
                /VendorFiles/PROD/SqlDeveloper/CA/Sales/2024/03/15/daily_sales_143000.parquet
            </div>
            <p><strong>What this means:</strong> Sales data for March 15, 2024, processed at 14:30:00 (2:30 PM), stored as a compressed Parquet file</p>
        </div>

        <div class="example-section">
            <div class="example-title">📋 Multiple Categories Example</div>
            <div class="file-path">/VendorFiles/PROD/SqlDeveloper/CA/Customers/2024/07/14/customer_data_091500.parquet</div>
            <div class="file-path">/VendorFiles/PROD/SqlDeveloper/CA/Inventory/2024/07/14/inventory_snapshot_143000.parquet</div>
            <div class="file-path">/VendorFiles/PROD/SqlDeveloper/CA/Orders/2024/07/14/order_transactions_200000.parquet</div>
        </div>

        <h2 style="color: #2c3e50; margin-bottom: 20px;">✨ Why This Structure Works</h2>

        <div class="benefits">
            <div class="benefit-card">
                <div class="benefit-icon">🎯</div>
                <strong>Easy to Find</strong><br>
                Data is organized logically by type, date, and time
            </div>
            <div class="benefit-card">
                <div class="benefit-icon">📈</div>
                <strong>Scalable</strong><br>
                Structure grows naturally as more data is added
            </div>
            <div class="benefit-card">
                <div class="benefit-icon">🔄</div>
                <strong>Automated</strong><br>
                Files are automatically placed in correct folders
            </div>
            <div class="benefit-card">
                <div class="benefit-icon">⚡</div>
                <strong>Fast Access</strong><br>
                Parquet format ensures quick data retrieval
            </div>
        </div>

        <div class="example-section">
            <div class="example-title">🔑 Key Points for Stakeholders</div>
            <ul style="line-height: 1.8;">
                <li><strong>Organized:</strong> Data is systematically organized by category, date, and time</li>
                <li><strong>Traceable:</strong> Each file includes a timestamp showing exactly when it was created</li>
                <li><strong>Efficient:</strong> Parquet format compresses data while maintaining fast access</li>
                <li><strong>Searchable:</strong> Folder structure makes it easy to locate specific data sets</li>
                <li><strong>Backup-friendly:</strong> Organized structure simplifies backup and archival processes</li>
            </ul>
        </div>
    </div>
</body>
</html>
