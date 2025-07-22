' SIMPLE VERSION - Less likely to cause errors
Sub SimpleCountValues()
    Dim ws As Worksheet
    Dim lastRow As Long
    Dim i As Long, j As Long
    Dim currentValue As String
    Dim count As Long
    Dim outputRow As Long
    Dim found As Boolean
    
    Set ws = ActiveSheet
    lastRow = ws.Cells(ws.Rows.Count, "A").End(xlUp).Row
    
    If lastRow < 1 Then
        MsgBox "No data in column A"
        Exit Sub
    End If
    
    ' Clear output area
    ws.Range("C1:D100").Clear
    
    ' Headers
    ws.Range("C1").Value = "Value"
    ws.Range("D1").Value = "Count"
    
    outputRow = 2
    
    ' Simple counting method
    For i = 1 To lastRow
        If Not IsEmpty(ws.Cells(i, 1).Value) Then
            currentValue = CStr(ws.Cells(i, 1).Value)
            
            ' Check if we've already counted this value
            found = False
            For j = 2 To outputRow - 1
                If ws.Cells(j, 3).Value = currentValue Then
                    found = True
                    Exit For
                End If
            Next j
            
            ' If not found, count it
            If Not found Then
                count = Application.WorksheetFunction.CountIf(ws.Range("A:A"), currentValue)
                ws.Cells(outputRow, 3).Value = currentValue
                ws.Cells(outputRow, 4).Value = count
                outputRow = outputRow + 1
            End If
        End If
    Next i
    
    MsgBox "Counting completed!"
End Sub

Sub CountValuesInColumnA()
    On Error GoTo ErrorHandler
    
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
    
    ' Check if there's meaningful data
    If lastRow < 1 Or (lastRow = 1 And IsEmpty(ws.Range("A1"))) Then
        MsgBox "No data found in column A"
        Exit Sub
    End If
    
    ' Set the data range (assuming data starts from A1)
    Set dataRange = ws.Range("A1:A" & lastRow)
    
    ' Create a dictionary to store value counts
    Set valueDict = CreateObject("Scripting.Dictionary")
    
    ' Count occurrences of each value
    For Each cell In dataRange
        If Not IsEmpty(cell.Value) And cell.Value <> "" Then
            Dim cellValue As String
            cellValue = CStr(cell.Value)
            
            If valueDict.exists(cellValue) Then
                valueDict(cellValue) = valueDict(cellValue) + 1
            Else
                valueDict(cellValue) = 1
            End If
        End If
    Next cell
    
    ' Check if we found any values
    If valueDict.Count = 0 Then
        MsgBox "No non-empty values found in column A"
        Exit Sub
    End If
    
    ' Clear previous results (starting from column C) - be more specific
    Dim clearRange As Range
    Set clearRange = ws.Range("C1:D1000") ' Clear specific range instead of entire columns
    clearRange.Clear
    
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
    On Error Resume Next ' Ignore formatting errors
    With ws.Range("C1:D1")
        .Font.Bold = True
        .Interior.Color = RGB(200, 200, 200)
    End With
    On Error GoTo ErrorHandler
    
    ' Auto-fit columns
    On Error Resume Next
    ws.Columns("C:D").AutoFit
    On Error GoTo ErrorHandler
    
    ' Sort results by count (descending) - with better error handling
    If outputRow > 2 Then
        On Error Resume Next
        Dim sortRange As Range
        Set sortRange = ws.Range("C1:D" & (outputRow - 1))
        sortRange.Sort Key1:=ws.Range("D1"), Order1:=xlDescending, Header:=xlYes
        On Error GoTo ErrorHandler
    End If
    
    MsgBox "Value counting completed! Results are in columns C and D." & vbCrLf & _
           "Found " & valueDict.Count & " unique values."
    
    Exit Sub
    
ErrorHandler:
    MsgBox "Error occurred: " & Err.Description & vbCrLf & _
           "Error number: " & Err.Number & vbCrLf & _
           "Please ensure column A contains data and columns C-D are not protected."
    
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

' MANUAL FORMULA METHOD (No VBA required)
' Instructions: 
' 1. Put unique values in column C manually or use Remove Duplicates
' 2. In D2, enter: =COUNTIF($A:$A,C2)
' 3. Copy formula down for all unique values