<#
.SYNOPSIS
    同時監測指定目錄、指定檔案、VSCode 日誌目錄，以及將所有控制台輸出進行記錄的 PowerShell 腳本 (純粹生成「材料」)。

.DESCRIPTION
    1. 監測指定資料夾 (DirectoryWatcher)，記錄其子目錄內所有檔案之增、刪、改、名變動。
    2. 監測指定檔案 (FileWatcher)，可針對該檔案的變動進行備份與記錄。
    3. 監測 VSCode 日誌資料夾 (VSCodeLogsWatcher)。
    4. 使用 Start-Transcript 捕捉所有 PowerShell 會話中主控台輸出。
    5. 將變動記錄寫入 changes.csv、錯誤寫入 errors.csv，並對變動檔案做備份。
    6. 不與 Aider 整合，僅生成日誌材料；您可在日後將這些檔案導入 DB (PostgreSQL / MongoDB) 或交給 Aider 進行整理。

.PARAMETER TargetFolder
    要監測的主要資料夾路徑。整個資料夾(含子資料夾)內檔案的增、刪、改、名都會觸發事件。若留空則跳過此功能。

.PARAMETER TargetFile
    要監測的特定檔案路徑(含檔名)。例如 "C:\MyProjects\some_config.json"。若留空則跳過此功能。

.PARAMETER VSCodeLogsDir
    VSCode 日誌檔所在資料夾。如 "C:\Users\<USERNAME>\AppData\Roaming\Code\logs"。若留空則跳過此功能。

.PARAMETER LogDir
    存放腳本產生之日誌的目錄(含 CSV、備份檔、轉錄檔案等)。預設於當前執行目錄下的 "monitoring_logs"。

.PARAMETER TranscriptFile
    捕捉整個 PowerShell 會話輸出的文字檔名稱。將存放在 LogDir 中。若留空則預設為 "console_transcript.log"。

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\multi_monitor.ps1 `
        -TargetFolder "C:\MyProjects" `
        -TargetFile "C:\MyProjects\my_config.json" `
        -VSCodeLogsDir "C:\Users\MyUser\AppData\Roaming\Code\logs" `
        -LogDir "C:\Logs\MyMonitorLogs" `
        -TranscriptFile "all_console_output.log"
#>

param(
    [string]$TargetFolder,
    [string]$TargetFile,
    [string]$VSCodeLogsDir,
    [string]$LogDir = ".\monitoring_logs",
    [string]$TranscriptFile = "console_transcript.log"
)

#------------------------
# 全域變數 & 前置處理
#------------------------
$global:monitoring = $true
$PSDefaultParameterValues['*:Encoding'] = 'UTF8'

# 若 LogDir 不存在，則建立
if (-not (Test-Path $LogDir)) {
    New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
    Write-Host "已建立日誌目錄: $LogDir" -ForegroundColor Green
}

# 建立 CSV 檔案路徑
$changesCsv = Join-Path $LogDir "changes.csv"
$errorsCsv  = Join-Path $LogDir "errors.csv"

# 若尚未存在，初始化 CSV 標頭
if (-not (Test-Path $changesCsv)) {
    "TimeStamp,ChangeType,Path,BackupPath" | Out-File $changesCsv -Encoding UTF8
}
if (-not (Test-Path $errorsCsv)) {
    "TimeStamp,Error" | Out-File $errorsCsv -Encoding UTF8
}

# 建立備份資料夾
$backupDir = Join-Path $LogDir "backups"
if (-not (Test-Path $backupDir)) {
    New-Item -ItemType Directory -Force -Path $backupDir | Out-Null
}

#------------------------
# 開始捕捉控制台輸出
#------------------------
$transcriptPath = Join-Path $LogDir $TranscriptFile
Start-Transcript -Path $transcriptPath -Append | Out-Null
Write-Host "已開始捕捉控制台輸出: $transcriptPath" -ForegroundColor Yellow

#------------------------
# 事件處理函數
#------------------------
function Handle-FileEvent {
    param(
        [System.IO.FileSystemEventArgs]$event,
        [string]$Label
    )

    $timeStamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    $path      = $event.FullPath
    $change    = $event.ChangeType

    # 通用輸出
    Write-Host "[$timeStamp] [$Label] $change -> $path" -ForegroundColor Green

    # 嘗試備份檔案 (僅在檔案確實存在時)
    if (Test-Path $path -PathType Leaf -ErrorAction SilentlyContinue) {
        try {
            $content = Get-Content -Path $path -Raw
            # 生成備份檔案名稱
            $backupFileName = "{0:yyyyMMdd_HHmmss}_{1}" -f (Get-Date), (Split-Path $path -Leaf)
            $backupPath = Join-Path $backupDir $backupFileName

            # 將檔案內容寫入備份
            $content | Out-File -FilePath $backupPath -Encoding UTF8

            # 寫入 changes.csv
            $logData = "$timeStamp,$change,$path,$backupPath"
            Add-Content -Path $changesCsv -Value $logData
        }
        catch {
            $errMsg = $_.Exception.Message
            Write-Host "備份失敗: $errMsg" -ForegroundColor Red
            Add-Content -Path $errorsCsv -Value "$timeStamp,$errMsg"
        }
    }
    else {
        # 若檔案已被刪除或只是資料夾事件
        $logData = "$timeStamp,$change,$path,"
        Add-Content -Path $changesCsv -Value $logData
    }
}

#------------------------
# 建立 FileSystemWatcher
#------------------------
$watchers = @()  # 用來記錄所有建立的監視器

# 工具函數：建立一個監視器並註冊對應事件
function New-DirWatcher {
    param(
        [string]$Folder,
        [string]$Filter,
        [string]$Label
    )
    # 若資料夾不存在或為空字串，則跳過
    if (-not [string]::IsNullOrEmpty($Folder) -and (Test-Path $Folder -PathType Container)) {
        $fsWatcher = New-Object System.IO.FileSystemWatcher
        $fsWatcher.Path = $Folder

        if ($Filter) {
            $fsWatcher.Filter = $Filter
        }
        else {
            # 不設 Filter 表示監視資料夾內所有檔案
            $fsWatcher.Filter = "*.*"
        }

        $fsWatcher.IncludeSubdirectories = $true  # 預設監視子目錄
        $fsWatcher.EnableRaisingEvents = $true

        # 綁定四種事件
        $callbacks = {
            param($src, $e)
            Handle-FileEvent -event $e -Label $Label
        }
        Register-ObjectEvent $fsWatcher "Changed" -Action $callbacks | Out-Null
        Register-ObjectEvent $fsWatcher "Created" -Action $callbacks | Out-Null
        Register-ObjectEvent $fsWatcher "Deleted" -Action $callbacks | Out-Null
        Register-ObjectEvent $fsWatcher "Renamed" -Action $callbacks | Out-Null

        Write-Host "建立監視：$Label -> $Folder\$($fsWatcher.Filter)" -ForegroundColor Cyan
        return $fsWatcher
    }
    else {
        if ($Folder) {
            Write-Host "目錄不存在或未指定，跳過監視：$Folder" -ForegroundColor DarkYellow
        }
        return $null
    }
}

# 1) 監視指定資料夾（若有提供）
$dirWatcher = New-DirWatcher -Folder $TargetFolder -Filter "*.*" -Label "TargetFolder"
if ($dirWatcher) { $watchers += $dirWatcher }

# 2) 監視指定檔案（若有提供）
if (-not [string]::IsNullOrEmpty($TargetFile)) {
    $fileFolder = Split-Path $TargetFile
    $fileName   = Split-Path $TargetFile -Leaf

    $fileWatcher = New-DirWatcher -Folder $fileFolder -Filter $fileName -Label "TargetFile"
    if ($fileWatcher) { $watchers += $fileWatcher }
}

# 3) 監視 VSCode 日誌目錄（若有提供）
$vsWatcher = New-DirWatcher -Folder $VSCodeLogsDir -Filter "*.*" -Label "VSCodeLogs"
if ($vsWatcher) { $watchers += $vsWatcher }

#------------------------
# 停止監控函數
#------------------------
function Stop-Monitoring {
    $global:monitoring = $false

    # 取消所有事件訂閱
    Get-EventSubscriber | Unregister-Event -ErrorAction SilentlyContinue

    # 停止控制台轉錄
    Stop-Transcript | Out-Null

    Write-Host "`n監控已停止，所有事件訂閱與轉錄檔已關閉。" -ForegroundColor Yellow
}

#------------------------
# 狀態檢查函數
#------------------------
function Get-MonitoringStatus {
    $timeStamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    $events = Get-EventSubscriber
    $changesCount = if (Test-Path $changesCsv) {
        (Get-Content $changesCsv).Count - 1
    } else { 0 }

    Write-Host "`n[$timeStamp] 監控狀態：" -ForegroundColor Cyan
    Write-Host "---------------------------------------" -ForegroundColor Cyan
    Write-Host " - 事件訂閱數: $($events.Count)" -ForegroundColor Cyan
    Write-Host " - 變更紀錄數: $changesCount" -ForegroundColor Cyan

    foreach ($w in $watchers) {
        Write-Host " - 監視器：$($w.Path)\$($w.Filter)" -ForegroundColor Cyan
    }
    Write-Host " - 主控台轉錄檔: $transcriptPath" -ForegroundColor Cyan
}

#------------------------
# 主執行區塊 (互動式)
#------------------------
Clear-Host
Write-Host "---------------------------------------" -ForegroundColor Green
Write-Host "  多重監視腳本 (純粹生成材料) 已啟動" -ForegroundColor Green
Write-Host "---------------------------------------" -ForegroundColor Green
Write-Host " - 按 'q' 鍵退出並停止監控" -ForegroundColor Yellow
Write-Host " - 按 's' 鍵查看當前監控狀態" -ForegroundColor Yellow
Write-Host "---------------------------------------`n" -ForegroundColor Yellow

while ($global:monitoring) {
    if ($Host.UI.RawUI.KeyAvailable) {
        $key = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
        switch ($key.Character) {
            'q' {
                Stop-Monitoring
                break
            }
            's' {
                Get-MonitoringStatus
            }
        }
    }
    Start-Sleep -Milliseconds 200
}
