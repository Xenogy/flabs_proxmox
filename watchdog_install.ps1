## RUN IN POWERSHELL ON VM: PowerShell -ExecutionPolicy Bypass -File "C:\Users\Administrator\Downloads\watchdog_install.ps1"

# =====================================================================
# --- CONFIGURATION ---
# =====================================================================

# --- NEW VERSION ---
# The details for the new script you want to download and install.
$githubPageUrl = "https://github.com/Xenogy/flabs_proxmox/blob/main/watchdog.exe"
$fileName = "watchdog.exe"

# --- OLD VERSIONS TO DELETE ---
# Add any old .exe filenames you may have used here. The script will hunt
# for these and remove them.
$oldExeNames = @(
    "popupv2.exe",
    "watchdog.exe",
    "popupcloser.exe"
)

# =====================================================================
# --- SCRIPT LOGIC (No changes needed below) ---
# =====================================================================

Write-Host "Installer starting..."
Write-Host "--------------------" -ForegroundColor Yellow

# 1. DEFINE PATHS
$processName = $fileName.Replace(".exe", "")
try {
    $startupFolderPath = [Environment]::GetFolderPath('Startup')
} catch {
    Write-Host "FATAL ERROR: Could not determine the Startup folder path." -ForegroundColor Red
    Read-Host "Press Enter to exit"
    exit
}

# 2. CLEANUP PREVIOUS VERSIONS
Write-Host "Step 1: Cleaning up previous versions..." -ForegroundColor Green

# --- NEW: Hunt for and delete all specified old EXEs ---
Write-Host " - Checking for known old executables..."
foreach ($oldName in $oldExeNames) {
    $oldProcessName = $oldName.Replace(".exe", "")
    $oldFilePath = Join-Path -Path $startupFolderPath -ChildPath $oldName
    
    # Stop the running process if it exists
    if (Get-Process -Name $oldProcessName -ErrorAction SilentlyContinue) {
        Write-Host "   - Found running process '$oldProcessName'. Terminating..." -ForegroundColor Yellow
        Stop-Process -Name $oldProcessName -Force -ErrorAction SilentlyContinue
    }
    
    # Delete the old file if it exists
    if (Test-Path -Path $oldFilePath) {
        Write-Host "   - Found old file '$oldName'. Deleting..." -ForegroundColor Yellow
        Remove-Item -Path $oldFilePath -Force -ErrorAction SilentlyContinue
    }
}

# Clean up the primary target file/process as well
Write-Host " - Checking for primary process '$processName'..."
if (Get-Process -Name $processName -ErrorAction SilentlyContinue) {
    Write-Host "   - Terminating '$processName' to prepare for update..." -ForegroundColor Yellow
    Stop-Process -Name $processName -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 1 # Give it a moment to release the file handle
}
$destinationPath = Join-Path -Path $startupFolderPath -ChildPath $fileName
if (Test-Path -Path $destinationPath) {
    Write-Host "   - Deleting '$fileName' to prepare for update..." -ForegroundColor Yellow
    Remove-Item -Path $destinationPath -Force
}

# Clean up any leftover source files
Write-Host " - Checking for old AutoHotkey source files (*.ahk)..."
$oldAhkFiles = Get-ChildItem -Path $startupFolderPath -Filter "*.ahk" -ErrorAction SilentlyContinue
if ($oldAhkFiles) {
    Write-Host "   - Found and deleting old .ahk files." -ForegroundColor Yellow
    $oldAhkFiles | Remove-Item -Force
}
Write-Host ""

# 3. DOWNLOAD AND INSTALL
Write-Host "Step 2: Downloading and installing new version..." -ForegroundColor Green
$downloadUrl = $githubPageUrl.Replace("github.com", "raw.githubusercontent.com").Replace("/blob/", "/")
try {
    Invoke-WebRequest -Uri $downloadUrl -OutFile $destinationPath -UseBasicParsing
    Write-Host "   Success: '$fileName' has been downloaded."
    Start-Process -FilePath $destinationPath
    Write-Host "   Success: '$fileName' is now running."
}
catch {
    Write-Host "FATAL ERROR: Download or start failed." -ForegroundColor Red
    Write-Host "   Details: $($_.Exception.Message)"
    Read-Host "Press Enter to exit"
    exit
}

Write-Host "--------------------" -ForegroundColor Yellow
Write-Host "Installation complete." -ForegroundColor Green
Start-Sleep -Seconds 4
