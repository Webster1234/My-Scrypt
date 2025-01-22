<#
.SYNOPSIS
    ͬ�r�O�yָ��Ŀ䛡�ָ���n����VSCode ���IĿ䛣��Լ������п���̨ݔ���M��ӛ䛵� PowerShell �_�� (�������ɡ����ϡ�)��

.DESCRIPTION
    1. �O�yָ���Y�ϊA (DirectoryWatcher)��ӛ�����Ŀ䛃����Йn��֮�����h���ġ���׃�ӡ�
    2. �O�yָ���n�� (FileWatcher)����ᘌ�ԓ�n����׃���M�Ђ���cӛ䛡�
    3. �O�y VSCode ���I�Y�ϊA (VSCodeLogsWatcher)��
    4. ʹ�� Start-Transcript ��׽���� PowerShell ��Ԓ������̨ݔ����
    5. ��׃��ӛ䛌��� changes.csv���e�`���� errors.csv���K��׃�әn������ݡ�
    6. ���c Aider ���ϣ��H�������I���ϣ����������ጢ�@Щ�n������ DB (PostgreSQL / MongoDB) �򽻽o Aider �M������

.PARAMETER TargetFolder
    Ҫ�O�y����Ҫ�Y�ϊA·���������Y�ϊA(�����Y�ϊA)�șn���������h���ġ��������|�l�¼��������Մt���^�˹��ܡ�

.PARAMETER TargetFile
    Ҫ�O�y���ض��n��·��(���n��)������ "C:\MyProjects\some_config.json"�������Մt���^�˹��ܡ�

.PARAMETER VSCodeLogsDir
    VSCode ���I�n�����Y�ϊA���� "C:\Users\<USERNAME>\AppData\Roaming\Code\logs"�������Մt���^�˹��ܡ�

.PARAMETER LogDir
    ����_���a��֮���I��Ŀ�(�� CSV����ݙn���D䛙n����)���A�O춮�ǰ����Ŀ��µ� "monitoring_logs"��

.PARAMETER TranscriptFile
    ��׽���� PowerShell ��Ԓݔ�������֙n���Q��������� LogDir �С������Մt�A�O�� "console_transcript.log"��

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
# ȫ��׃�� & ǰ��̎��
#------------------------
$global:monitoring = $true
$PSDefaultParameterValues['*:Encoding'] = 'UTF8'

# �� LogDir �����ڣ��t����
if (-not (Test-Path $LogDir)) {
    New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
    Write-Host "�ѽ������IĿ�: $LogDir" -ForegroundColor Green
}

# ���� CSV �n��·��
$changesCsv = Join-Path $LogDir "changes.csv"
$errorsCsv  = Join-Path $LogDir "errors.csv"

# ����δ���ڣ���ʼ�� CSV ���^
if (-not (Test-Path $changesCsv)) {
    "TimeStamp,ChangeType,Path,BackupPath" | Out-File $changesCsv -Encoding UTF8
}
if (-not (Test-Path $errorsCsv)) {
    "TimeStamp,Error" | Out-File $errorsCsv -Encoding UTF8
}

# ��������Y�ϊA
$backupDir = Join-Path $LogDir "backups"
if (-not (Test-Path $backupDir)) {
    New-Item -ItemType Directory -Force -Path $backupDir | Out-Null
}

#------------------------
# �_ʼ��׽����̨ݔ��
#------------------------
$transcriptPath = Join-Path $LogDir $TranscriptFile
Start-Transcript -Path $transcriptPath -Append | Out-Null
Write-Host "���_ʼ��׽����̨ݔ��: $transcriptPath" -ForegroundColor Yellow

#------------------------
# �¼�̎����
#------------------------
function Handle-FileEvent {
    param(
        [System.IO.FileSystemEventArgs]$event,
        [string]$Label
    )

    $timeStamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    $path      = $event.FullPath
    $change    = $event.ChangeType

    # ͨ��ݔ��
    Write-Host "[$timeStamp] [$Label] $change -> $path" -ForegroundColor Green

    # �Lԇ��ݙn�� (�H�ڙn���_�����ڕr)
    if (Test-Path $path -PathType Leaf -ErrorAction SilentlyContinue) {
        try {
            $content = Get-Content -Path $path -Raw
            # ���ɂ�ݙn�����Q
            $backupFileName = "{0:yyyyMMdd_HHmmss}_{1}" -f (Get-Date), (Split-Path $path -Leaf)
            $backupPath = Join-Path $backupDir $backupFileName

            # ���n�����݌�����
            $content | Out-File -FilePath $backupPath -Encoding UTF8

            # ���� changes.csv
            $logData = "$timeStamp,$change,$path,$backupPath"
            Add-Content -Path $changesCsv -Value $logData
        }
        catch {
            $errMsg = $_.Exception.Message
            Write-Host "���ʧ��: $errMsg" -ForegroundColor Red
            Add-Content -Path $errorsCsv -Value "$timeStamp,$errMsg"
        }
    }
    else {
        # ���n���ѱ��h����ֻ���Y�ϊA�¼�
        $logData = "$timeStamp,$change,$path,"
        Add-Content -Path $changesCsv -Value $logData
    }
}

#------------------------
# ���� FileSystemWatcher
#------------------------
$watchers = @()  # �Á�ӛ����н����ıOҕ��

# ���ߺ���������һ���Oҕ���K�]�Ԍ����¼�
function New-DirWatcher {
    param(
        [string]$Folder,
        [string]$Filter,
        [string]$Label
    )
    # ���Y�ϊA�����ڻ����ִ����t���^
    if (-not [string]::IsNullOrEmpty($Folder) -and (Test-Path $Folder -PathType Container)) {
        $fsWatcher = New-Object System.IO.FileSystemWatcher
        $fsWatcher.Path = $Folder

        if ($Filter) {
            $fsWatcher.Filter = $Filter
        }
        else {
            # ���O Filter ��ʾ�Oҕ�Y�ϊA�����Йn��
            $fsWatcher.Filter = "*.*"
        }

        $fsWatcher.IncludeSubdirectories = $true  # �A�O�Oҕ��Ŀ�
        $fsWatcher.EnableRaisingEvents = $true

        # �����ķN�¼�
        $callbacks = {
            param($src, $e)
            Handle-FileEvent -event $e -Label $Label
        }
        Register-ObjectEvent $fsWatcher "Changed" -Action $callbacks | Out-Null
        Register-ObjectEvent $fsWatcher "Created" -Action $callbacks | Out-Null
        Register-ObjectEvent $fsWatcher "Deleted" -Action $callbacks | Out-Null
        Register-ObjectEvent $fsWatcher "Renamed" -Action $callbacks | Out-Null

        Write-Host "�����Oҕ��$Label -> $Folder\$($fsWatcher.Filter)" -ForegroundColor Cyan
        return $fsWatcher
    }
    else {
        if ($Folder) {
            Write-Host "Ŀ䛲����ڻ�δָ�������^�Oҕ��$Folder" -ForegroundColor DarkYellow
        }
        return $null
    }
}

# 1) �Oҕָ���Y�ϊA�������ṩ��
$dirWatcher = New-DirWatcher -Folder $TargetFolder -Filter "*.*" -Label "TargetFolder"
if ($dirWatcher) { $watchers += $dirWatcher }

# 2) �Oҕָ���n���������ṩ��
if (-not [string]::IsNullOrEmpty($TargetFile)) {
    $fileFolder = Split-Path $TargetFile
    $fileName   = Split-Path $TargetFile -Leaf

    $fileWatcher = New-DirWatcher -Folder $fileFolder -Filter $fileName -Label "TargetFile"
    if ($fileWatcher) { $watchers += $fileWatcher }
}

# 3) �Oҕ VSCode ���IĿ䛣������ṩ��
$vsWatcher = New-DirWatcher -Folder $VSCodeLogsDir -Filter "*.*" -Label "VSCodeLogs"
if ($vsWatcher) { $watchers += $vsWatcher }

#------------------------
# ֹͣ�O�غ���
#------------------------
function Stop-Monitoring {
    $global:monitoring = $false

    # ȡ�������¼�ӆ�
    Get-EventSubscriber | Unregister-Event -ErrorAction SilentlyContinue

    # ֹͣ����̨�D�
    Stop-Transcript | Out-Null

    Write-Host "`n�O����ֹͣ�������¼�ӆ��c�D䛙n���P�]��" -ForegroundColor Yellow
}

#------------------------
# ��B�z�麯��
#------------------------
function Get-MonitoringStatus {
    $timeStamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    $events = Get-EventSubscriber
    $changesCount = if (Test-Path $changesCsv) {
        (Get-Content $changesCsv).Count - 1
    } else { 0 }

    Write-Host "`n[$timeStamp] �O�ؠ�B��" -ForegroundColor Cyan
    Write-Host "---------------------------------------" -ForegroundColor Cyan
    Write-Host " - �¼�ӆ醔�: $($events.Count)" -ForegroundColor Cyan
    Write-Host " - ׃���o䛔�: $changesCount" -ForegroundColor Cyan

    foreach ($w in $watchers) {
        Write-Host " - �Oҕ����$($w.Path)\$($w.Filter)" -ForegroundColor Cyan
    }
    Write-Host " - ����̨�D䛙n: $transcriptPath" -ForegroundColor Cyan
}

#------------------------
# �����Ѕ^�K (����ʽ)
#------------------------
Clear-Host
Write-Host "---------------------------------------" -ForegroundColor Green
Write-Host "  ���رOҕ�_�� (�������ɲ���) �ц���" -ForegroundColor Green
Write-Host "---------------------------------------" -ForegroundColor Green
Write-Host " - �� 'q' �I�˳��Kֹͣ�O��" -ForegroundColor Yellow
Write-Host " - �� 's' �I�鿴��ǰ�O�ؠ�B" -ForegroundColor Yellow
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
