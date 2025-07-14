## EXECUTE IN POWERSHELL: PowerShell -ExecutionPolicy Bypass -File "C:\Users\Administrator\Downloads\popupclose_install.ps1"

# --- Configuration ---
# The GitHub page URL for the file
$githubPageUrl = "https://github.com/Xenogy/flabs_proxmox/blob/main/popupv2.exe"
# The name for the file on the local machine
$fileName = "popupv2.exe"

# --- Script Logic ---

# 1. Convert the GitHub page URL to the direct raw download URL
$downloadUrl = $githubPageUrl.Replace("github.com", "raw.githubusercontent.com").Replace("/blob/", "/")

# 2. Get the current user's Startup folder path
# This is the most reliable way to find the folder for any user account
try {
    $startupFolderPath = [Environment]::GetFolderPath('Startup')
} catch {
    Write-Host "Error: Could not determine the Startup folder path."
    # Pause the script to allow user to read the error before the window closes
    Read-Host "Press Enter to exit"
    exit
}


# 3. Define the full destination path for the executable
$destinationPath = Join-Path -Path $startupFolderPath -ChildPath $fileName

Write-Host "Installer starting..."
Write-Host "--------------------"
Write-Host "Download URL: $downloadUrl"
Write-Host "Target location: $destinationPath"
Write-Host ""

# 4. Download the file to the Startup folder
try {
    Write-Host "Downloading $fileName..."
    # Use Invoke-WebRequest to download the file from the URL to the destination path.
    # -UseBasicParsing is included for compatibility with older PowerShell versions.
    Invoke-WebRequest -Uri $downloadUrl -OutFile $destinationPath -UseBasicParsing
    
    Write-Host "Success: '$fileName' has been downloaded and placed in your Startup folder."
    Write-Host "It will now run automatically when you log into Windows."
    Write-Host ""
}
catch {
    Write-Host "Error: Failed to download the file."
    Write-Host "Please check your internet connection and the URL."
    # Print the specific error message
    Write-Host "Details: $($_.Exception.Message)"
    Read-Host "Press Enter to exit"
    exit
}

# 5. Start the process now
try {
    Write-Host "Starting the application for the first time..."
    Start-Process -FilePath $destinationPath
    Write-Host "Success: '$fileName' is now running."
}
catch {
    Write-Host "Error: Could not start the downloaded file."
    Write-Host "Details: $($_.Exception.Message)"
    Read-Host "Press Enter to exit"
    exit
}

Write-Host "--------------------"
Write-Host "Installation complete."

# Optional: Keep the window open for a few seconds to let the user read the output
Start-Sleep -Seconds 5
