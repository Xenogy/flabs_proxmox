## RUN IN POWERSHELL ON VM: PowerShell -ExecutionPolicy Bypass -File "C:\Users\Administrator\Downloads\watchdog_install.ps1"

# =====================================================================
# --- CONFIGURATION ---
# =====================================================================
$githubPageUrl = "https://github.com/Xenogy/flabs_proxmox/blob/main/watchdog.exe"
$fileName = "watchdog.exe"
# The process name is usually the filename without the extension.
$processName = "watchdog"

# =====================================================================
# --- SCRIPT LOGIC ---
# =====================================================================

Write-Host "Installer starting..."
Write-Host "--------------------" -ForegroundColor Yellow

# 1. DEFINE PATHS
try {
    # Get the current user's Startup folder path reliably.
    $startupFolderPath = [Environment]::GetFolderPath('Startup')
    $destinationPath = Join-Path -Path $startupFolderPath -ChildPath $fileName
} catch {
    Write-Host "FATAL ERROR: Could not determine the Startup folder path." -ForegroundColor Red
    Read-Host "Press Enter to exit"
    exit
}

# 2. CLEANUP PREVIOUS VERSIONS
Write-Host "Step 1: Cleaning up previous versions..." -ForegroundColor Green

# Stop any running process with the target name.
Write-Host " - Checking for a running process named '$processName'..."
$runningProcess = Get-Process -Name $processName -ErrorAction SilentlyContinue
if ($runningProcess) {
    Write-Host "   Found running process. Terminating it now." -ForegroundColor Yellow
    Stop-Process -Name $processName -Force -ErrorAction SilentlyContinue
    # Give it a moment to release the file handle.
    Start-Sleep -Seconds 1 
} else {
    Write-Host "   No running process found. Good."
}

# Delete the old executable from the Startup folder if it exists.
Write-Host " - Checking for old executable file ($fileName)..."
if (Test-Path -Path $destinationPath) {
    Write-Host "   Found old executable. Deleting it now." -ForegroundColor Yellow
    Remove-Item -Path $destinationPath -Force -ErrorAction SilentlyContinue
} else {
    Write-Host "   No old executable found. Good."
}

# --- NEW: Find and delete ALL .ahk files from the Startup folder ---
Write-Host " - Checking for old AutoHotkey source files (*.ahk)..."
$oldAhkFiles = Get-ChildItem -Path $startupFolderPath -Filter "*.ahk" -ErrorAction SilentlyContinue
if ($oldAhkFiles) {
    Write-Host "   Found old .ahk files. Deleting them now." -ForegroundColor Yellow
    foreach ($file in $oldAhkFiles) {
        Write-Host "     - Deleting $($file.Name)"
        Remove-Item -Path $file.FullName -Force
    }
} else {
    Write-Host "   No old .ahk files found. Good."
}
Write-Host ""


# 3. DOWNLOAD THE NEW VERSION
Write-Host "Step 2: Downloading new version..." -ForegroundColor Green
$downloadUrl = $githubPageUrl.Replace("github.com", "raw.githubusercontent.com").Replace("/blob/", "/")
Write-Host " - Download URL: $downloadUrl"
Write-Host " - Target location: $destinationPath"

try {
    Invoke-WebRequest -Uri $downloadUrl -OutFile $destinationPath -UseBasicParsing
    Write-Host "   Success: '$fileName' has been downloaded to your Startup folder."
    Write-Host ""
}
catch {
    Write-Host "FATAL ERROR: Failed to download the file." -ForegroundColor Red
    Write-Host "   Please check your internet connection and the URL."
    Write-Host "   Details: $($_.Exception.Message)"
    Read-Host "Press Enter to exit"
    exit
}

# 4. START THE NEW PROCESS
Write-Host "Step 3: Starting the new application..." -ForegroundColor Green
try {
    Start-Process -FilePath $destinationPath
    Write-Host "   Success: '$fileName' is now running."
}
catch {
    Write-Host "FATAL ERROR: Could not start the downloaded file." -ForegroundColor Red
    Write-Host "   Details: $($_.Exception.Message)"
    Read-Host "Press Enter to exit"
    exit
}

Write-Host "--------------------" -ForegroundColor Yellow
Write-Host "Installation complete." -ForegroundColor Green
Start-Sleep -Seconds 4
