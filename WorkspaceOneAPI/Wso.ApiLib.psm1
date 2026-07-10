<#
.AUTHOR
cbradley@vmware.com
.SYNOPSIS
Workspace ONE (AirWatch) lightweight API helper functions for secure REST access and utilities.
.DESCRIPTION
Provides helper functions to:
 - Enforce TLS 1.2 for outbound requests
 - Log with stream-aware and colored console output
 - Build and execute secured web requests with optional SSL certificate pinning
 - Perform Workspace ONE API calls with Basic or OAuth authorization
 - Handle simple pagination patterns for WS1 APIs
 - Retrieve API help metadata across WS1 endpoints
 - Create Basic Authorization headers
 - Read the current logged-on user and username
 - Build application/x-www-form-urlencoded payloads
 - Acquire OAuth tokens (client credentials grant)

This script is designed to run as a module-like helper for Workspace ONE integrations.
.NOTES
Requires Windows PowerShell (WebRequest, WMI) and registry access if using Install-WorkspaceOneAPILite.
Ensure server certificate thumbprints are correct when enabling SSL pinning.
.VERSION
260112.4
#>
$CurrentVersion="260112.4"

$TLSVersion=""

$DebugPreference = 1

$LogFile="$PSScriptRoot\WorkspaceOneAPI.log"
function Write-Log{
    <#
    .SYNOPSIS
    Writes a timestamped log entry to console (colored) and to a file.
    .DESCRIPTION
    Writes messages to the console in color unless DebugPreference contains 'Silent'.
    Otherwise routes messages to PowerShell streams depending on level:
      - Error -> Write-Error
      - Warn  -> Write-Warning
      - Verbose -> Write-Verbose (honors $VerbosePreference)
    Always appends to WorkspaceOneAPI.log alongside the script.
    .PARAMETER Message
    The message text to log.
    .PARAMETER Path
    Ignored at runtime (overridden to script log path). Kept for signature compatibility.
    .PARAMETER Level
    The severity of the message. Accepts Error, Warn, Verbose. Default: Verbose.
    .EXAMPLE
    Write-Log -Message "Starting request"
    .EXAMPLE
    Write-Log -Message "Certificate mismatch" -Level Error
    .NOTES
    Console coloring is only used when not in a 'Silent' debug state.
    #>
    param([string]$Message,[string]$Path=$LogFile,
    [ValidateSet("Error","Warn","Verbose")]
    [string]$Level="Verbose")
    $Path = "$PSScriptRoot\WorkspaceOneAPI.log"

    $FormattedDate = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    if($DebugPreference -notlike "*Silent*"){
        $Colors=@{'Error'=[System.ConsoleColor]::Red;'Warn'=[System.ConsoleColor]::Yellow;'Verbose'=[System.ConsoleColor]::Cyan}
        Write-Host -ForegroundColor $Colors[$Level] "$FormattedDate`t [$($Level.ToUpper())`:] $Message"
        "$FormattedDate $($Level.ToUpper())`: $Message" | Out-File -FilePath $Path -Append
    }Else{
       If($Level -eq 'Error' -and $ErrorActionPreference -notlike "*Silent*") {
            Write-Error $Message
            "$FormattedDate $($Level.ToUpper())`: $Message" | Out-File -FilePath $Path -Append
       }
       ElseIf($Level -eq 'Warn' -and $WarningPreference -notlike "*Silent*") {
            Write-Warning $Message
            "$FormattedDate $($Level.ToUpper())`: $Message" | Out-File -FilePath $Path -Append
       }
       ElseIf($Level -eq 'Verbose' -and $VerbosePreference) {
            Write-Verbose $Message
            "$FormattedDate $($Level.ToUpper())`: $Message" | Out-File -FilePath $Path -Append
       }   
    }
}

#Attempts to set the default TLS version for connection to TLS 1.2
If(!($TLSVersion)){
    Try {
        If( [System.Net.ServicePointManager]::SecurityProtocol -ne [System.Net.SecurityProtocolType]::Tls12){ 
            [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
            Write-Log -Message "TLS 1.2 has been successfully enabled."
        }
    } Catch {
        $err=$_.Exception.Message;
        Write-Log -Message "An error has occurred enabling Tls1.2: $err`r`nExiting..." -Level Error
        return
    }
}


<#
.AUTHOR
cbradley@vmware.com
.SYNOPSIS
Invokes a Workspace ONE API endpoint with Basic or OAuth authentication and pagination support.
.DESCRIPTION
Constructs the full API URL from ApiSettings.Server and the given endpoint.
Attaches the aw-tenant-code header (ApiSettings.ApiKey).
Supports:
 - Basic Auth (from ApiSettings.BasicAuthCreds or Username/Password)
 - OAuth (from $this.Config.OauthConfig via Invoke-OauthTokenRequest)
Handles responses and optionally follows pagination via Get-NextApiPage.
.PARAMETER Endpoint
Relative path of the API endpoint (e.g., 'api/mdm/devices').
.PARAMETER ApiSettings
Settings object with properties like Server, ApiKey, AuthType, Username, Password, BasicAuthCreds, SslThumbprint.
.PARAMETER ApiVersion
API version used in Accept/ContentType headers as 'application/json;version=#'. Default: 1.
.PARAMETER Method
HTTP method to use (GET, POST, PUT, DELETE, etc.). Default: GET.
.PARAMETER Data
Optional JSON body for POST/PUT requests.
.OUTPUTS
Parsed JSON object from the last page (or single response) on success; otherwise an object may contain StatusCode.
.EXAMPLE
Invoke-WorkspaceOneAPICommand -Endpoint 'api/mdm/devices' -ApiSettings $settings -ApiVersion 2
#>
function Invoke-WorkspaceOneAPICommand{
    param([string]$Endpoint, [PSCustomObject]$ApiSettings, $ApiVersion=1, $Method="GET",  $Data="")
    $Endpoint="$($ApiSettings.Server)/$Endpoint"
    $Accept="application/json;version=$ApiVersion"
    $ContentType="application/json;version=$ApiVersion"
    $Headers=@{"aw-tenant-code"=$ApiSettings.ApiKey}

    $ClientCertificate="";

    If(($ApiSettings.AuthType -eq $null) -or $ApiSettings.AuthType -eq "Basic"){
        If($ApiSettings.BasicAuthCreds){
            $Private:BasicAuthCreds=$ApiSettings.BasicAuthCreds
        }ElseIf($ApiSettings.Username -and $ApiSettings.Password){
            $Private:BasicAuthCreds=(New-BasicAuthCredentials -Username $ApiSettings.Username -Password $ApiSettings.Password)
        }
        $Headers.Add("Authorization",$Private:BasicAuthCreds);
    }Else{
        If($ApiSettings.AuthType -in @("Oauth", "OauthCertificate")){
            $OauthSettings=$this.Config.OauthConfig;
            $OauthToken = Invoke-OauthTokenRequest -IdentityUri $OauthSettings.identityUri -GrantType $OauthSettings.grant_type -ClientId $OauthSettings.client_id -ClientSecret $OauthSettings.client_secret -Scope $OauthSettings.scope
            If($OauthToken){
                    $Headers.Add("Authorization",$OauthToken);
            }
        }
    }

    $SslThumbprint=$ApiSettings.SslThumbprint;
    #Main web request
 
    $currentPage=0
    $ReturnObj = New-Object -TypeName PSCustomObject -Property @{"StatusCode"=$WebRequest.StatusCode};      
    while($true){
        If(![string]::IsNullOrEmpty($NextPage)){ $Endpoint=$NextPage }
        $WebRequest = Invoke-SecureWebRequestEx -Endpoint $Endpoint -Method $Method -Accept $Accept -ContentType $ContentType -Headers $Headers -Data $Data -SslThumbprint $SslThumbprint -DisableCertificatePinning
        If($WebRequest.StatusCode -lt 300){  
             If($WebRequest.Content){
                $ReturnObj = ConvertFrom-Json $WebRequest.Content; 
            }        
        }
        $NextPage=Get-NextApiPage -Endpoint $Endpoint -ReturnObj $ReturnObj
        If($NextPage -eq $null){
            break;
        }
    }                       
    return $ReturnObj
}

<#
.AUTHOR
cbradley@vmware.com
.SYNOPSIS
Fetches Workspace ONE API help metadata for known product areas/versions.
.DESCRIPTION
Queries a predefined list of API help URIs (e.g., mdmv1..v4, systemv1..v2, mamv1)
and returns a collection that includes the name, path, version, and retrieved metadata for each.
.PARAMETER ApiSettings
Settings object passed through to the API invoker (see Invoke-WorkspaceOneAPICommand).
.OUTPUTS
An array of PSCustomObject with properties: name, path, apiversion, metadata.
.EXAMPLE
Get-WorkspaceOneHelp -ApiSettings $settings
#>
function Get-WorkspaceOneHelp{
     param([PSCustomObject]$ApiSettings)
   
    $MetadataList=@("api/help/Docs/mdmv1";
         "api/help/Docs/mdmv2";
         "api/help/Docs/mdmv3";
         "api/help/Docs/mdmv4";
         "api/help/Docs/systemv1";
         "api/help/Docs/systemv2";
         "api/help/Docs/mamv1";
         #"api/help/Docs/mamv2";                      
     );

    $Docs=@()

    foreach($apihelp in $MetadataList){
        $GetAPIMetaData=Invoke-WorkspaceOneAPICommand -Endpoint $apihelp -ApiSettings $ApiSettings 
        If(($apihelp | Split-Path -Leaf) -match "(.*)v([1-9])"){
            $subpath=$Matches[1]
            $apiversion=$Matches[2]
        }
        $Docs += @(New-Object PSCustomObject -Property @{"name"=$apihelp;"path"=$subpath;"apiversion"=$apiversion;"metadata"=$GetAPIMetaData})
    }
    return $Docs
}


<#
.SYNOPSIS
Determines the next paginated API URL based on response content and URL query.
.DESCRIPTION
Supports two common patterns:
 1) Body includes 'total', 'page', 'page_size' and data array in another property.
 2) Body includes 'TotalResults' and current page is derived from 'page=#' in the URL.
If more data is likely present, constructs and returns the next page URL; otherwise returns $null.
.PARAMETER Endpoint
The URL used for the current page (may contain page and/or pagesize).
.PARAMETER ReturnObj
Parsed JSON response object for the current page.
.OUTPUTS
String URL for the next page, or $null if no further pages are indicated.
.EXAMPLE
$next = Get-NextApiPage -Endpoint $url -ReturnObj $obj
#>
function Get-NextApiPage{
    param($Endpoint, $ReturnObj)
    $PageSize=500
    If($Endpoint -match "pagesize\=([0-9]{1,4})"){
        [int]::TryParse($Matches[1], [ref]$PageSize)
    }
    $Divider="?"
    If($Endpoint -match "([^?]*)\?") { $Divider="&amp;" }
                       
    # paging type 1
    If($ReturnObj.total){
        $SmartObjectId=($ReturnObj | Get-Member -MemberType NoteProperty | Where Name -notin @("page", "page_size", "total","links") | Select Name).Name
        $SmartObjectCount=($ReturnObj."$SmartObjectId" | Measure).Count
        If($SmartObjectCount -lt $PageSize){
            return
        }
        $CurrentPage=$ReturnObj.page
    }
    ElseIf($ReturnObj.TotalResults){
        $SmartObjectId=($ReturnObj | Get-Member -MemberType NoteProperty | Where Name -notin @("TotalResults") | Select Name).Name    
        $SmartObjectCount=($ReturnObj."$SmartObjectId" | Measure).Count
        $CurrentPage=0
        If($Endpoint -match "page=([0-9]{1,5})") { $CurrentPage=$Matches[1] }
    }
    If($CurrentPage){
        return "$Endpoint$Divider`page=$($CurrentPage + 1)"
    }
    return
}


<#
.SYNOPSIS
Creates an HTTP Basic Authorization header value.
.DESCRIPTION
Encodes "username:password" as Base64 per RFC 7617 and prefixes with "Basic ".
Note this is not encryption—use over TLS.
.PARAMETER Username
The username portion.
.PARAMETER Password
The password portion.
.OUTPUTS
String in the form "Basic <base64>".
.EXAMPLE
$auth = New-BasicAuthCredentials -Username 'apiuser' -Password 'p@ssw0rd'
#> 
function New-BasicAuthCredentials{
    param($Username, $Password)
   Process{
        Try{
            $UTFEncoded=[System.Text.Encoding]::UTF8.GetBytes("$Username`:$Password");
            $AuthString=[System.Convert]::ToBase64String($UTFEncoded)
            #Special method for obfuscating the credentials
            return "Basic $AuthString"
        } Catch{
            $err=$_.Excepton.Message;
            return;
        }
        return;
    }
}

<#
.AUTHOR
cbradley@vmware.com
.SYNOPSIS
Gets the currently logged-on Windows user in a normalized object format.
.DESCRIPTION
Uses WMI (Win32_ComputerSystem.Username) and parses either DOMAIN\User or user@domain
into an object with Username, Domain, and FullName/Fullname properties.
.OUTPUTS
PSCustomObject with Username, Domain, FullName (or Fullname).
.EXAMPLE
Get-CurrentLoggedonUser
#>
function Get-CurrentLoggedonUser{
    #If Username lookup has not been processed, use Get-WMIOBject to return the user.
    If(!($usernameLookup)){
        $usernameLookup = Get-WMIObject -class Win32_ComputerSystem | select username;
    }
    if($usernameLookup){
        if($usernameLookup -match "([^\\]*)\\(.*)"){
            $usernameLookup = New-Object -TypeName PSCustomObject -Property @{"Username"=$Matches[2];"Domain"=$Matches[1];"FullName"=$Matches[0]};
        } elseif($usernameLookup -match "([^@]*)@(.*)"){
            $usernameLookup = New-Object -TypeName PSCustomObject -Property @{"Username"=$Matches[1];"Domain"=$Matches[2];"Fullname"=$Matches[0]};
        }
    }     
    return $usernameLookup;
}

<#
.SYNOPSIS
Builds a formatted trace string for log position context.
.DESCRIPTION
Returns a string containing a random token and the supplied file/class/function/source names.
Useful for tagging log entries with contextual information.
.PARAMETER FileName
File or logical source name.
.PARAMETER ClassName
If provided, overrides FileName in the output.
.PARAMETER FunctionName
The function name to include in the trace tag.
.PARAMETER SourceName
Optional source prefix (e.g., 'Client->').
.OUTPUTS
String containing contextual trace marker.
.EXAMPLE
Get-LogPos -FileName 'Module.psm1' -FunctionName 'Invoke-Call'
#>
Function Get-LogPos {
    [Alias("GetLogPos")]
    param([string]$FileName,[string]$ClassName,[string]$FunctionName,[string]$SourceName="") 
    
    If($ClassName){
        $FileName = "$ClassName"
    }
    If($SourceName){
        $SourceName="$SourceName-&gt;"
    }
    return " ({0}) {3}[{1}::{2}] " -f ([Random]::new().Next(999)), $FileName, $FunctionName, $SourceName;
}

 <#
.SYNOPSIS
Executes an HTTP request with optional SSL certificate pinning and returns a simplified response.
.DESCRIPTION
Creates a System.Net.WebRequest with provided method, headers, and body.
If DisableCertificatePinning is not set, requires an SSL thumbprint to match the server certificate.
Reads the response stream into a string and returns a compact object containing status code and content.
.PARAMETER Endpoint
The full URL to call.
.PARAMETER Method
HTTP method (GET/POST/PUT/DELETE, etc.). Default: GET.
.PARAMETER Accept
The Accept header value. Default: application/json;version=1.
.PARAMETER ContentType
The Content-Type header value. Default: application/json;version=1.
.PARAMETER Headers
Hashtable of additional headers to add to the request.
.PARAMETER Data
Optional request body (string). UTF-8 encoded.
.PARAMETER SslThumbprint
Certificate thumbprint used for pinning when pinning is enabled.
.PARAMETER DisableCertificatePinning
If present, disables pinning (NOT secure; intended for trusted dev/test).
.OUTPUTS
Object with properties: Headers, ContentLength, ContentType, CharacterSet, LastModified, ResponseUri, StatusCode, Content, StatusDescription.
.EXAMPLE
Invoke-SecureWebRequestEx -Endpoint $url -Method 'GET' -SslThumbprint $thumb
#> 
function Invoke-SecureWebRequestEx{
    param([string]$Endpoint, [string]$Method="GET", [string]$Accept="application/json;version=1", 
        [string]$ContentType="application/json;version=1", $Headers=@{}, $Data="", [string]$SslThumbprint="", 
        [switch]$DisableCertificatePinning)
    $ProcInfo=Get-LogPos -FileName $CurrentModuleFileName -FunctionName $MyInvocation.MyCommand.Name 
        
    Write-Log -Message "BEGIN REQUEST '$Method $Endpoint'"
    $Content=$null
    Try
    {
        If($DisableCertificatePinning.IsPresent){
            Write-Log -Message "CONNECTION IS NOT SECURE.  SSL PINNING IS CURRENTLY DISABLED.  CREDENTIALS CAN BE EASILY INTERCEPTED BY PROXIES OR OTHER MALICIOUS ACTORS." -Level Warn
        } ElseIf([string]::IsNullOrEmpty($SslThumbprint) -and !($DisableCertificatePinning.IsPresent)){
            $err="SSL thumbprint is not set.  SSL thumbprint is required to ensure API requests are secure to Workspace One server."
            throw (New-CustomException "An SSL/TLS error has occured", $err);
        }
        # Create web request with headers and credentials
        $WebRequest = [System.Net.WebRequest]::Create("$Endpoint")
        $WebRequest.Method = $Method;
        $WebRequest.Accept = $Accept;
        $WebRequest.ContentType = $ContentType;
            
        foreach($Header in $Headers.Keys){
            $WebRequest.Headers.Add($Header, $Headers[$Header]);
        }
            
        #Data stream for POST/PUT data
        If($Data){ 
            $ByteArray = [System.Text.Encoding]::UTF8.GetBytes($Data);
            $WebRequest.ContentLength = $ByteArray.Length;  
            $Stream = $WebRequest.GetRequestStream();
            Try{              
                $Stream.Write($ByteArray, 0, $ByteArray.Length);     
            } Catch {
                $err = $_.Exception.Message;
                Write-Log -Message "ERROR DATA encoding data,`r`n`t`t$err"  -Level Error  
            } Finally{
                $Stream.Close();
            }
        } Else {
            $WebRequest.ContentLength = 0;
        }

        #Get current SSL thumbprint
        
        # Set the callback to check for null certificate and thumbprint matching.
        $WebRequest.ServerCertificateValidationCallback = {
            $ThumbPrint = $SslThumbprint;
            $certificate = [System.Security.Cryptography.X509Certificates.X509Certificate2]$args[1]
            If ($certificate -eq $null)
            {
                return $false
            }
            #This line enables SSL pinning
            If($DisableCertificatePinning.IsPresent){
                return $true;
            } ElseIf (($certificate.Thumbprint -eq $ThumbPrint) -and ($certificate.SubjectName.Name -ne $certificate.IssuerName.Name)){
                return $true
            }
            $err="SSL thumbprint $Thumbprint does not match server, $($certificate.Thumbprint) or certificate is self signed."
            Write-Log -Message "ERROR SSL/TLS Security $err" -Level Error
            return $false
        }      
        # Get response stream
        Write-Log -Message "PROCESS REQUEST Requesting response from server." 
        $Response = $webrequest.GetResponse();
        $ResponseStream = $webrequest.GetResponse().GetResponseStream()
        # Create a stream reader and read the stream returning the string value.
        $StreamReader = New-Object System.IO.StreamReader -ArgumentList $ResponseStream
        Try{
            $Content = $StreamReader.ReadToEnd();
        } Catch {
            $err = "Unable to read response, $($_.Exception.Message)";
            Write-Log -Message "ERROR RESPONSE $err" -Level Error
        } Finally{
            $StreamReader.Close();
        }

        $CustomWebResponse = $Response | Select-Object Headers, ContentLength, ContentType, CharacterSet, LastModified, ResponseUri,
            @{N='StatusCode';E={$_.StatusCode.value__}},@{N='Content';E={$Content}},StatusDescription
            
        Write-Log -Message "END REQUEST Request completed." 
        return $CustomWebResponse;
    }
    Catch
    {
        $err=$_.Exception.InnerException.Message;
        $StatusCode = $_.Exception.InnerException.Response.StatusCode.value__;
        $StatusDescription = $_.Exception.InnerException.Response.Status;
        Write-Log -Message "END REQUEST Request failed due to $err, with status $StatusCode"  -Level Error 
        If(!($StatusCode)){
            $StatusCode = 999;
        } 
        return New-Object -TypeName PSCustomObject -ArgumentList @{"StatusCode"=$StatusCode;"Content"=$err}
    }

}

<#
.SYNOPSIS
Returns the current username portion only.
.DESCRIPTION
Reads Win32_ComputerSystem.Username and extracts the username from either DOMAIN\User or user@domain.
.OUTPUTS
String username or $null if not matched.
.EXAMPLE
Get-CurrentUsername
#>
function Get-CurrentUsername{
    $usernameLookup = Get-WMIObject -class Win32_ComputerSystem | select username;
    if($usernameLookup.username -match "([^\\]*)\\(.*)"){
        return $Matches[2]
    } elseif($usernameLookup.username -match "([^@]*)@(.*)"){
        return $Matches[1];
    }  
    return;
}

<#
.SYNOPSIS
Converts a hashtable to application/x-www-form-urlencoded format.
.DESCRIPTION
Accepts a hashtable and emits a string in the format key=value&key2=value2.
Values are not URL-encoded; ensure values are appropriately formatted for your API.
.PARAMETER Object
Hashtable to convert.
.OUTPUTS
String in www-form-encoded format.
.EXAMPLE
@{ grant_type='client_credentials'; client_id='abc' } | ConvertTo-WwwFormEncoded
#>
function ConvertTo-WwwFormEncoded{
    param(
         [CmdletBinding()]
         [Parameter(ValueFromPipeline)]
        $Object)
    $Type=$Object.GetType()
    $FormEncoded="";
    if($Type.Name -eq "Hashtable"){
        foreach($Key in $Object.Keys){
            if([string]::IsNullOrEmpty($FormEncoded) -eq $false){
                $FormEncoded += "&amp;"
            }
            $FormEncoded+=$Key + "=" + $Object[$Key]
        }
    }else{
        Throw "Cannot convert object of type, '$($Type.Name)', to type 'www-form-encoded'"
    }
    return $FormEncoded;
}

<#
.SYNOPSIS
Requests an OAuth token (client credentials grant) and returns the Authorization header value.
.DESCRIPTION
Builds an application/x-www-form-urlencoded body and posts it to the IdentityUri.
On HTTP 200, parses the JSON and returns "token_type access_token".
Certificate pinning is disabled in this call (relies on platform trust).
.PARAMETER IdentityUri
OAuth token endpoint (e.g., https://idp.example.com/oauth2/token).
.PARAMETER IdentityUriThumbprint
Unused here; reserved for future pinning logic.
.PARAMETER GrantType
Grant type (default: client_credentials).
.PARAMETER ClientId
OAuth client id.
.PARAMETER ClientSecret
OAuth client secret.
.PARAMETER Scope
Space-delimited scopes requested.
.OUTPUTS
String suitable for Authorization header on success, otherwise the raw response object.
.EXAMPLE
Invoke-OauthTokenRequest -IdentityUri $uri -ClientId $id -ClientSecret $secret -Scope "awapi openid"
#>
function Invoke-OauthTokenRequest{
    param([string]$IdentityUri, [string]$IdentityUriThumbprint, [string]$GrantType="client_credentials",[string]$ClientId,[string]$ClientSecret,[string]$Scope)
    $ProcInfo=GetLogPos -FileName $CurrentModuleFileName -FunctionName $MyInvocation.MyCommand.Name 

    $OauthBody=@{
        grant_type=$GrantType
        client_id=$ClientId
        client_secret=$ClientSecret
        scope=$Scope
    } | ConvertTo-WwwFormEncoded
    $AuthResponse=""
    
    Try{    
        $contentType='application/x-www-form-urlencoded'
        $AuthResponse=Invoke-SecureWebRequestEx -Endpoint $IdentityUri -Method "POST" -Accept $contentType -ContentType $contentType -Data $OauthBody -DisableCertificatePinning
        If($AuthResponse.StatusCode -eq "200"){
            $AuthObject=($AuthResponse.Content | ConvertFrom-Json)
            return "$($AuthObject.token_type) $($AuthObject.access_token)"
        }
    }Catch{
        $err=$_.Exception.Message;
        Write-Log -Message "An error has occured, $err" -Level Error
    }
    return $AuthResponse
}