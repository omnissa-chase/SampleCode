<#
.SYNOPSIS
    Upload large files to Workspace ONE UEM and create File Actions.

.DESCRIPTION
    This script uploads one or multiple files to Workspace ONE UEM using chunked upload
    and automatically creates a File Action containing all uploaded files. The script handles 
    large files by breaking them into chunks and uploading them sequentially to avoid timeout issues.
    
    This is a modified version of the AppUpload script available at:
    https://github.com/euc-oss/euc-samples/blob/main/UEM-Samples/Utilities%20and%20Tools/Generic/App%20Upload/UploadApp.ps1

.NOTES
    Author: Workspace ONE UEM Team
    Version: 2.0
    Date: December 16, 2025
    
    Requirements:
    - PowerShell 5.1 or later
    - Network connectivity to Workspace ONE UEM server
    - Valid UEM administrator credentials
    - Sufficient permissions to create File Actions in the target Organization Group

.EXAMPLE
    # Single file upload
    $AppFilePaths = @('C:\Files\app.apk')
    
.EXAMPLE
    # Multiple file upload
    $AppFilePaths = @(
        'C:\Files\config.xml',
        'C:\Files\data.json',
        'C:\Files\app.apk'
    )
#>

#==============================================================================
# CONFIGURATION SECTION - UPDATE THESE VALUES
#==============================================================================

# Authentication credentials for Workspace ONE UEM
$UserName = 'username'
$Password = 'password'

# API Key (aw-tenant-code) - found in UEM Console under System > Advanced > API > REST API
$ApiKey = ''

# Workspace ONE UEM API server URL (without https://)
$ServerURL = 'cnxxx.awmdm.com'

# Array of local file paths to be uploaded
# For single file: $AppFilePaths = @('C:\path\to\file.apk')
# For multiple files: $AppFilePaths = @('C:\file1.apk', 'C:\file2.xml', 'C:\file3.json')
$AppFilePaths = @('C:\file1.apk', 'C:\file2.xml', 'C:\file3.json')

# File Action configuration
# Name of the File Action to create
$FileActionName = "FA_Zebra_2"         
# Description of the File Action                         
$FileActionDescription = "Description"                          

# Organization Group ID where the File Action will be created
$OrgGroupId = 1234

# Device platform ID - determines which devices can receive this File Action
# Common values: 5 = Android, 10 = macOS, 12 = Windows Desktop
$DeviceType = 5

# Download path on the target device where files will be saved. File name will be appended to this when creating the File Action.
$FileDownloadPath = "/sdcard/"

# Chunk size for file upload (in bytes)
# Recommended: 10 MB to 100 MB. Use smaller values (5-10 MB) for slower connections
# Default: 10 MB
$ChunkSize = 10 * 1024 * 1024

#==============================================================================
# HELPER FUNCTIONS
#==============================================================================

<#
.SYNOPSIS
    Creates a Basic Authentication header for API calls.

.DESCRIPTION
    Implements Basic authentication by encoding username and password in Base64 format.
    See "Client side" at https://en.wikipedia.org/wiki/Basic_access_authentication

.PARAMETER username
    UEM administrator username

.PARAMETER password
    UEM administrator password

.OUTPUTS
    String containing the Base64-encoded authentication header
#>
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
Function Create-BasicAuthHeader {
    Param(
        [Parameter(Mandatory=$True)]
        [string]$username,
        [Parameter(Mandatory=$True)]
        [string]$password
    )

    $combined = $username + ":" + $password
    $encoding = [System.Text.Encoding]::ASCII.GetBytes($combined)
    $encodedString = [Convert]::ToBase64String($encoding)

    Return "Basic " + $encodedString
}

<#
.SYNOPSIS
    Builds HTTP headers for REST API calls to Workspace ONE UEM.

.DESCRIPTION
    Creates a dictionary of headers required for UEM API authentication and communication.

.PARAMETER authString
    Base64-encoded authentication string from Create-BasicAuthHeader function

.PARAMETER tenantCode
    API Key (aw-tenant-code) for the UEM environment

.OUTPUTS
    Dictionary object containing all required HTTP headers
#>
Function Create-Headers {
    Param(
        [Parameter(Mandatory=$True)]
        [string]$authString,
        [Parameter(Mandatory=$True)]
        [string]$tenantCode
    )

    $header = New-Object "System.Collections.Generic.Dictionary[[String],[String]]"
    $header.Add("Authorization", $authString)
    $header.Add("aw-tenant-code", $tenantCode)
    $header.Add("Accept", "application/json")
    $header.Add("Content-Type", "application/json")

    Return $header
}

<#
.SYNOPSIS
    Uploads a single chunk of a file to Workspace ONE UEM.

.DESCRIPTION
    Calls the POST /api/mam/apps/internal/uploadchunk API to upload a portion of a file.
    This API supports chunked uploads for large files, allowing files to be split into
    manageable pieces that are uploaded sequentially.

.PARAMETER serverURL
    UEM server URL without protocol (https:// is added automatically)

.PARAMETER headers
    HTTP headers dictionary containing authentication and tenant information

.PARAMETER body
    JSON string containing chunk data, transaction ID, sequence number, and size information

.OUTPUTS
    Response object from the API containing the transaction ID for the uploaded chunk
#>
Function UploadChunk {
    Param(
        [Parameter(Mandatory=$True)]
        [string]$serverURL,
        [Parameter(Mandatory=$True)]
        $headers,
        [Parameter(Mandatory=$True)]
        [string]$body
    )
    
    $ChunkURL = "https://$serverURL/api/mam/apps/internal/uploadchunk"
    Write-Verbose "Calling API: $ChunkURL"
    
    $response = Invoke-RestMethod -Method "POST" -Uri $ChunkURL -Headers $headers -Body $body -ContentType 'application/json'
    return $response
}

<#
.SYNOPSIS
    Creates a File Action in Workspace ONE UEM.

.DESCRIPTION
    Calls the POST /api/mdm/products/maintainFileAction API to create or update a File Action
    in UEM, making it available in the UEM administrator console for assignment to devices.

.PARAMETER Server
    UEM server URL without protocol (https:// is added automatically)

.PARAMETER headers
    HTTP headers dictionary containing authentication and tenant information

.PARAMETER faDetails
    JSON string containing File Action configuration including files, organization group, and platform

.OUTPUTS
    Response object from the API containing the created File Action details
#>
Function CreateFileAction {
    Param(
        [Parameter(Mandatory=$True)]
        [String] $Server,
        [Parameter(Mandatory=$True)]
        $headers,
        [Parameter(Mandatory=$True)]
        $faDetails
    )

    $url = "https://$Server/api/mdm/products/maintainFileAction"
    Write-Verbose "Calling API: $url"

    try {
        $response = Invoke-RestMethod -Method "POST" -Uri $url.ToString() -Headers $headers -Body $faDetails -ContentType 'application/json'
        return $response
    } catch {
        Write-Error "Failed to create File Action: $_"
        throw
    }
}

<#
.SYNOPSIS
    Uploads a single file to UEM in chunks.

.DESCRIPTION
    Reads a file and uploads it in chunks to UEM, tracking the transaction ID
    for the completed upload. Returns a hashtable containing file metadata.

.PARAMETER FilePath
    Path to the file to upload

.PARAMETER ServerURL
    UEM server URL

.PARAMETER Headers
    HTTP headers for API calls

.PARAMETER ChunkSize
    Size of each chunk to upload

.OUTPUTS
    Hashtable containing FileName, FilePath, TransactionId, and FileSize
#>
Function Upload-FileToUEM {
    Param(
        [Parameter(Mandatory=$True)]
        [string]$FilePath,
        [Parameter(Mandatory=$True)]
        [string]$ServerURL,
        [Parameter(Mandatory=$True)]
        $Headers,
        [Parameter(Mandatory=$True)]
        [int]$ChunkSize
    )

    # Validate file exists
    if (-not (Test-Path -Path $FilePath)) {
        Write-Error "File not found: $FilePath"
        throw "File not found: $FilePath"
    }

    # Get file information
    $fileInfo = Get-Item -Path $FilePath
    $TotalAppSize = $fileInfo.Length
    $FileName = $fileInfo.Name
    
    Write-Host "`n========================================" -ForegroundColor Cyan
    Write-Host "Uploading: $FileName" -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host "File Size: $([math]::Round($TotalAppSize / 1MB, 2)) MB"
    Write-Host "Chunk Size: $([math]::Round($ChunkSize / 1MB, 2)) MB"
    
    # Initialize upload tracking variables
    $ChunkSequenceNumber = 1              # Chunk sequence starts at 1
    $TransactionID = ""                   # Empty string for first upload
    $chunksUploaded = 0
    $localChunkSize = $ChunkSize          # Local copy to avoid modifying parameter
    
    # Open file stream for reading
    $fileStream = [System.IO.File]::OpenRead($FilePath)
    
    try {
        Write-Host "Starting chunked upload..." -ForegroundColor Yellow
        
        # Upload file in chunks until all bytes are uploaded
        while($chunksUploaded -ne $TotalAppSize) {
            
            # Adjust chunk size for the last chunk if necessary
            if ($localChunkSize -gt ($TotalAppSize - $chunksUploaded)) {
                $localChunkSize = $TotalAppSize - $chunksUploaded
            }
            
            # Read chunk from file
            $chunk = New-Object byte[] $localChunkSize
            $chunksRead = $fileStream.Read($chunk, 0, $localChunkSize)
            
            # Encode chunk to Base64 for API transmission
            $currentSize = $chunk.Length
            $b64Chunk = [System.Convert]::ToBase64String($chunk)
            
            # Prepare API request body
            $body = @{
                TransactionId = $TransactionID
                ChunkData = $b64Chunk
                ChunkSequenceNumber = $ChunkSequenceNumber
                TotalApplicationSize = $TotalAppSize
                ChunkSize = $currentSize
            }
            $body = $body | ConvertTo-Json
            
            # Upload chunk to UEM
            try {
                $chunkRes = UploadChunk -serverURL $ServerURL -headers $Headers -body $body
                $TransactionID = $chunkRes.TranscationId
                
                # Update progress
                $chunksUploaded += $chunksRead
                $ChunkSequenceNumber++
                
                $percentComplete = [math]::Round(($chunksUploaded / $TotalAppSize) * 100, 1)
                $uploadedMB = [math]::Round($chunksUploaded / 1MB, 2)
                Write-Host "Progress: $percentComplete% ($uploadedMB MB uploaded)" -ForegroundColor Green
                
            } catch {
                Write-Error "Failed to upload chunk $ChunkSequenceNumber for file $FileName"
                Write-Error $_
                throw
            }
        }
        
        Write-Host "Successfully uploaded: $FileName" -ForegroundColor Green
        Write-Host "Transaction ID: $TransactionID" -ForegroundColor Green
        
        # Return file upload details
        return @{
            FileName = $FileName
            FilePath = $FilePath
            TransactionId = $TransactionID
            FileSize = $TotalAppSize
        }
        
    } finally {
        # Always close the file stream
        if ($fileStream) {
            $fileStream.Close()
            $fileStream.Dispose()
        }
    }
}

#==============================================================================
# MAIN PROCESS
#==============================================================================

Write-Host "`n============================================" -ForegroundColor Magenta
Write-Host "Workspace ONE UEM File Action Upload Script" -ForegroundColor Magenta
Write-Host "============================================`n" -ForegroundColor Magenta

# Initialize API authentication
Write-Host "Setting up API authentication..." -ForegroundColor Yellow
$AuthString = Create-BasicAuthHeader -username $UserName -password $Password
$Headers = Create-Headers -authString $AuthString -tenantCode $ApiKey
Write-Host "Authentication configured successfully`n" -ForegroundColor Green

# Validate that at least one file path is provided
if ($AppFilePaths.Count -eq 0) {
    Write-Error "No file paths provided in `$AppFilePaths array"
    exit 1
}

Write-Host "Files to upload: $($AppFilePaths.Count)" -ForegroundColor Cyan

# Array to store uploaded file details (transaction IDs and metadata)
# Initialize as new ArrayList to avoid potential duplication issues
$uploadedFiles = New-Object System.Collections.ArrayList

# Upload each file and collect transaction IDs
foreach ($filePath in $AppFilePaths) {
    try {
        $uploadResult = Upload-FileToUEM -FilePath $filePath `
                                         -ServerURL $ServerURL `
                                         -Headers $Headers `
                                         -ChunkSize $ChunkSize
        [void]$uploadedFiles.Add($uploadResult)
        
    } catch {
        Write-Error "Failed to upload file: $filePath"
        Write-Error $_
        Write-Host "`nAborting: File upload failed. File Action will not be created." -ForegroundColor Red
        exit 1
    }
}

Write-Host "`n========================================" -ForegroundColor Green
Write-Host "All files uploaded successfully!" -ForegroundColor Green
Write-Host "========================================`n" -ForegroundColor Green

# Display summary of uploaded files
Write-Host "Upload Summary:" -ForegroundColor Cyan
foreach ($file in $uploadedFiles) {
    Write-Host "  - $($file.FileName) (Transaction ID: $($file.TransactionId))" -ForegroundColor White
}

#==============================================================================
# CREATE FILE ACTION
#==============================================================================

Write-Host "`nCreating File Action: $FileActionName" -ForegroundColor Yellow

# Build File Action base structure
$FaBase = @{}

# Configure general input settings
# InsertOnly = false: Will create or update an existing File Action with the same name
# InsertOnly = true: Will always create a new File Action and fail if name already exists
$FaGeneralInput = @{
    "LocationGroupID" = "$OrgGroupId"
    "InsertOnly" = "false"
}

# Add File Action metadata
$FaBase.Add("MaintainGeneralInput", $FaGeneralInput)
$FaBase.Add("Name", "$FileActionName")
$FaBase.Add("Description", "$FileActionDescription")
$FaBase.Add("DevicePlatformID", $DeviceType)

# Build array of blob files from uploaded files
$BlobFilesList = New-Object System.Collections.ArrayList

foreach ($uploadedFile in $uploadedFiles) {
    # Combine download path with filename
    $fullDownloadPath = $FileDownloadPath.TrimEnd('/') + '/' + $uploadedFile.FileName
    
    $FaBlobFiles = @{
        "TransactionId" = $uploadedFile.TransactionId
        "FileName" = $uploadedFile.FileName
        "DownloadPath" = $fullDownloadPath
        "FileVersion" = "1.0"
    }
    
    [void]$BlobFilesList.Add($FaBlobFiles)
    Write-Host "  - Added file to File Action: $($uploadedFile.FileName)" -ForegroundColor White
}

$FaBase.Add("BlobFiles", $BlobFilesList)

<#
Example API request body for maintainFileAction API:
POST https://<UEM-SERVER>/api/mdm/products/maintainFileAction

{
  "MaintainGeneralInput": {
    "LocationGroupID": 638,
    "InsertOnly": false
  },
  "Name": "MyFileAction",
  "Description": "Download files to device",
  "DevicePlatformID": 5,
  "BlobFiles": [
    {
      "TransactionId": "abc123-def456-ghi789",
      "FileName": "config.xml",
      "DownloadPath": "/sdcard/",
      "FileVersion": "1.0"
    },
    {
      "TransactionId": "xyz789-uvw456-rst123",
      "FileName": "app.apk",
      "DownloadPath": "/sdcard/",
      "FileVersion": "1.0"
    }
  ]
}
#>

# Convert File Action object to JSON
$FaJson = $FaBase | ConvertTo-Json -Depth 10
Write-Verbose "File Action request body: $FaJson"

# Create File Action in UEM
try {
    Write-Host "`nSubmitting File Action to Workspace ONE UEM..." -ForegroundColor Yellow
    Write-Host "This may take a few minutes depending on file sizes..." -ForegroundColor Yellow
    
    $saveRes = CreateFileAction -Server $ServerURL -headers $Headers -faDetails $FaJson
    
    Write-Host "`n========================================" -ForegroundColor Green
    Write-Host "SUCCESS!" -ForegroundColor Green
    Write-Host "========================================" -ForegroundColor Green
    Write-Host "File Action '$FileActionName' created successfully" -ForegroundColor Green
    Write-Host "Files included: $($uploadedFiles.Count)" -ForegroundColor White
    Write-Host "Organization Group ID: $OrgGroupId" -ForegroundColor White
    Write-Host "Platform: $DeviceType" -ForegroundColor White
    Write-Host "`nYou can now assign this File Action to devices from the UEM console.`n" -ForegroundColor Cyan
    
} catch {
    Write-Host "`n========================================" -ForegroundColor Red
    Write-Host "FAILED" -ForegroundColor Red
    Write-Host "========================================" -ForegroundColor Red
    Write-Error "Failed to create File Action: $_"
    Write-Host "`nPlease check your configuration and try again.`n" -ForegroundColor Yellow
    exit 1
}