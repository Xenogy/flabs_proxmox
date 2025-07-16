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
$oldExeNames = @(
    "popupcloser.exe",
    "popupv2.exe",
    "watchdog.exe"
)

# =====================================================================
# --- SCRIPT LOGIC ---
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
$allKnownExes = $oldExeNames + $fileName

# --- Cleanup Loop for Processes and Files ---
Write-Host " - Checking for old processes and files..."
foreach ($exeName in $allKnownExes) {
    $procName = $exeName.Replace(".exe", "")
    $filePath = Join-Path -Path $startupFolderPath -ChildPath $exeName

    # Stop the running process if it exists
    if (Get-Process -Name $procName -ErrorAction SilentlyContinue) {
        Write-Host "   - Found running process '$procName'. Terminating..." -ForegroundColor Yellow
        Stop-Process -Name $procName -Force -ErrorAction SilentlyContinue
    }
    
    # Delete the old file if it exists
    if (Test-Path -Path $filePath) {
        Write-Host "   - Found file '$exeName'. Deleting..." -ForegroundColor Yellow
        Remove-Item -Path $filePath -Force -ErrorAction SilentlyContinue
    }
}

# --- NEW: Cleanup Loop for Shortcuts (.lnk files) ---
Write-Host " - Checking for old shortcuts..."
try {
    $shell = New-Object -ComObject WScript.Shell
    $shortcutFiles = Get-ChildItem -Path $startupFolderPath -Filter "*.lnk" -ErrorAction SilentlyContinue

    foreach ($shortcut in $shortcutFiles) {
        $targetPath = $shell.CreateShortcut($shortcut.FullName).TargetPath
        $targetFilename = Split-Path -Path $targetPath -Leaf # Gets just the filename like "popupv2.exe"

        if ($allKnownExes -contains $targetFilename) {
            Write-Host "   - Found shortcut '$($shortcut.Name)' pointing to '$targetFilename'. Deleting..." -ForegroundColor Yellow
            Remove-Item -Path $shortcut.FullName -Force
        }
    }
} catch {
    Write-Host "   - Warning: Could not check for shortcuts. This might happen on very restricted systems." -ForegroundColor Yellow
}


# --- Cleanup for .ahk source files ---
Write-Host " - Checking for old AutoHotkey source files (*.ahk)..."
$oldAhkFiles = Get-ChildItem -Path $startupFolderPath -Filter "*.ahk" -ErrorAction SilentlyContinue
if ($oldAhkFiles) {
    Write-Host "   - Found and deleting old .ahk files." -ForegroundColor Yellow
    $oldAhkFiles | Remove-Item -Force
}
Write-Host ""


# 3. DOWNLOAD AND INSTALL
Write-Host "Step 2: Downloading and installing new version..." -ForegroundColor Green
$destinationPath = Join-Path -Path $startupFolderPath -ChildPath $fileName
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
