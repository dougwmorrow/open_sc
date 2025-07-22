Sub CountValuesInColumnA()
    Dim ws As Worksheet
    Dim lastRow As Long
    Dim dataRange As Range
    Dim valueDict As Object
    Dim cell As Range
    Dim i As Long
    Dim outputRow As Long
    
    ' Set the active worksheet
    Set ws = ActiveSheet
    
    ' Find the last row with data in column A
    lastRow = ws.Cells(ws.Rows.Count, "A").End(xlUp).Row
    
    ' Check if there's data
    If lastRow < 1 Then
        MsgBox "No data found in column A"
        Exit Sub
    End If
    
    ' Set the data range (assuming data starts from A1)
    Set dataRange = ws.Range("A1:A" & lastRow)
    
    ' Create a dictionary to store value counts
    Set valueDict = CreateObject("Scripting.Dictionary")
    
    ' Count occurrences of each value
    For Each cell In dataRange
        If Not IsEmpty(cell.Value) Then
            If valueDict.exists(cell.Value) Then
                valueDict(cell.Value) = valueDict(cell.Value) + 1
            Else
                valueDict(cell.Value) = 1
            End If
        End If
    Next cell
    
    ' Clear previous results (starting from column C)
    ws.Range("C:D").Clear
    
    ' Add headers
    ws.Range("C1").Value = "Value"
    ws.Range("D1").Value = "Count"
    
    ' Output the results starting from row 2
    outputRow = 2
    Dim key As Variant
    For Each key In valueDict.Keys
        ws.Cells(outputRow, 3).Value = key
        ws.Cells(outputRow, 4).Value = valueDict(key)
        outputRow = outputRow + 1
    Next key
    
    ' Format the output
    With ws.Range("C1:D1")
        .Font.Bold = True
        .Interior.Color = RGB(200, 200, 200)
    End With
    
    ' Auto-fit columns
    ws.Columns("C:D").AutoFit
    
    ' Sort results by count (descending)
    If outputRow > 2 Then
        ws.Range("C1:D" & outputRow - 1).Sort Key1:=ws.Range("D1"), Order1:=xlDescending, Header:=xlYes
    End If
    
    MsgBox "Value counting completed! Results are in columns C and D."
End Sub

' Alternative: Count specific value
Sub CountSpecificValue()
    Dim searchValue As String
    Dim ws As Worksheet
    Dim lastRow As Long
    Dim countResult As Long
    
    Set ws = ActiveSheet
    
    ' Get the value to search for
    searchValue = InputBox("Enter the value to count:", "Count Specific Value")
    
    If searchValue = "" Then Exit Sub
    
    ' Find last row
    lastRow = ws.Cells(ws.Rows.Count, "A").End(xlUp).Row
    
    ' Count using COUNTIF
    countResult = Application.WorksheetFunction.CountIf(ws.Range("A:A"), searchValue)
    
    MsgBox "'" & searchValue & "' appears " & countResult & " times in column A"
End Sub

' Quick method using built-in Excel features
Sub CreatePivotTableCount()
    Dim ws As Worksheet
    Dim lastRow As Long
    Dim dataRange As Range
    Dim pt As PivotTable
    Dim pc As PivotCache
    
    Set ws = ActiveSheet
    lastRow = ws.Cells(ws.Rows.Count, "A").End(xlUp).Row
    Set dataRange = ws.Range("A1:A" & lastRow)
    
    ' Create pivot cache
    Set pc = ActiveWorkbook.PivotCaches.Create(SourceType:=xlDatabase, SourceData:=dataRange)
    
    ' Create pivot table on new sheet
    Set pt = pc.CreatePivotTable(TableDestination:=ws.Range("F1"))
    
    With pt
        .PivotFields("Column1").Orientation = xlRowField
        .PivotFields("Column1").Orientation = xlDataField
        .PivotFields("Count of Column1").Function = xlCount
    End With
    
    MsgBox "Pivot table created in column F showing value counts!"
End Sub