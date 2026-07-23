$ExtensionPath="HKLM:\Software\AIRWATCH\Extensions"

$current_path = $PSScriptRoot;
if(!($current_path)){
    $current_path=Get-ItemProperty "$ExtensionPath" | Select-Object "SharedPath" -ExpandProperty "SharedPath" -ErrorAction SilentlyContinue
}

if(!($current_path)){
    Throw "An error has occured. Path not set"
}

$RootPath=Split-Path $current_path -Parent


Unblock-File "$currentPath\Wso.CommonLibLte.psm1"
#Unblock-File "$currentPath\Wso.CommonLib.psd1"
$module = Import-Module "$currentPath\Wso.CommonLibLte.psm1" -ErrorAction Stop -PassThru -Force;  
$ExportedFunctions+=$module.ExportedCommands.Keys

$CurrentModuleFileName = (Split-Path $PSCommandPath -Leaf).Replace(".psm1","").Replace(".ps1","")
$ExtensionPath="HKLM:\Software\AIRWATCH\Extensions"

$LibPaths=Get-ModulePaths -ExtensionPath $ExtensionPath -ModulePath "WorkspaceOne" -CurrentPath $RootPath -WritePath
$CurrentModuleFileName = (Split-Path $PSCommandPath -Leaf).Replace(".psm1","").Replace(".ps1","")

$LogLocation="$($LibPaths.LogPath)\Wso.Web.Log"

 <#
.SYNOPSIS
This function creates a web request
.DESCRIPTION
#> 
function Invoke-SecureWebRequestEx{
    param([string]$Endpoint, [string]$Method="GET", [string]$Accept="application/json;version=1", 
        [string]$ContentType="application/json;version=1", $Headers=@{}, $Data="", [string]$SslThumbprint="", 
        $ClientCertificate, [switch]$DisableCertificatePinning)
    $ProcInfo=Get-LogPos -FileName $CurrentModuleFileName -FunctionName $MyInvocation.MyCommand.Name 
        
    Write-Log -Path $LogLocation -ProcessInfo $ProcInfo -Message "BEGIN REQUEST '$Method $Endpoint'"
    $Content=$null
    Try
    {
        If($DisableCertificatePinning.IsPresent){
            Write-Log -Path $LogLocation -ProcessInfo $ProcInfo -Message "CONNECTION IS NOT SECURE.  SSL PINNING IS CURRENTLY DISABLED.  CREDENTIALS CAN BE EASILY INTERCEPTED BY PROXIES OR OTHER MALICIOUS ACTORS." -Level Warn
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

        If($ClientCertificate){ $WebRequest.ClientCertificates.Add($ClientCertificate) }
            
        #Data stream for POST/PUT data
        If($Data){ 
            $ByteArray = [System.Text.Encoding]::UTF8.GetBytes($Data);
            $WebRequest.ContentLength = $ByteArray.Length;  
            $Stream = $WebRequest.GetRequestStream();
            Try{              
                $Stream.Write($ByteArray, 0, $ByteArray.Length);     
            } Catch {
                $err = $_.Exception.Message;
                Write-Log -Path $LogLocation -ProcessInfo $ProcInfo -Message "ERROR DATA encoding data,`r`n`t`t$err"  -Level Error  
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
            Write-Log -Path $LogLocation -ProcessInfo $ProcInfo -Message "ERROR SSL/TLS Security $err" -Level Error
            return $false
        }      
        # Get response stream
        Write-Log -Path $LogLocation -ProcessInfo $ProcInfo -Message "PROCESS REQUEST Requesting response from server." 
        $Response = $webrequest.GetResponse();
        $ResponseStream = $webrequest.GetResponse().GetResponseStream()
        # Create a stream reader and read the stream returning the string value.
        $StreamReader = New-Object System.IO.StreamReader -ArgumentList $ResponseStream
        Try{
            $Content = $StreamReader.ReadToEnd();
        } Catch {
            $err = "Unable to read response, $($_.Exception.Message)";
            Write-Log -Path $LogLocation -ProcessInfo $ProcInfo -Message "ERROR RESPONSE $err" -Level Error
        } Finally{
            $StreamReader.Close();
        }

        $CustomWebResponse = $Response | Select-Object Headers, ContentLength, ContentType, CharacterSet, LastModified, ResponseUri,
            @{N='StatusCode';E={$_.StatusCode.value__}},@{N='Content';E={$Content}},StatusDescription
            
        Write-Log -Path $LogLocation -ProcessInfo $ProcInfo -Message "END REQUEST Request completed." 
        return $CustomWebResponse;
    }
    Catch
    {
        $err=$_.Exception.InnerException.Message;
        $StatusCode = $_.Exception.InnerException.Response.StatusCode.value__;
        $StatusDescription = $_.Exception.InnerException.Response.Status;
        #Write-Log2 -Path $LogLocation -ProcessInfo $ProcInfo -Message "END REQUEST Request completed."  -Level Warn 
        If(!($StatusCode)){
            $StatusCode = 999;
        } 
        return New-Object -TypeName PSCustomObject -ArgumentList @{"StatusCode"=$StatusCode;"Content"=$err}
    }

}

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
.AUTHOR
cbradley@vmware.com
.SYNOPSIS
Gets the requested certificate from the certificate store
#>
function Get-ClientAuthCert{
    param([string]$CertificateAttribute="Subject", [string]$Filter="*", [hashtable]$CertificateFilters, [string]$CertStore="Cert:\LocalMachine\My")
    $CurrentUsername=Get-CurrentUsername
    $LookupValues = @{"{Username}"=$CurrentUsername}

    If($CertificateAttribute -and $Filter -and !($CertificateFilters)){
        $CertificateFilters = @{$CertificateAttribute=$Filter}
    }
    
    If($CertificateFilters){
        $Cert=Get-ChildItem -Path $CertStore
        ForEach($FilterKey in $CertificateFilters.Keys){
            $Filter = $CertificateFilters[$FilterKey]
            If($Filter -like "{*}"){
                ForEach($LookupValue in $LookupValues.Keys){
                    $Filter=$Filter.Replace($LookupValue, $LookupValues[$LookupValue]);
                }
            }
            $Cert=$Cert | Where "$FilterKey" -like "*$Filter*"
        }
    }
    # Serial
    # Distinguished
    # 
    If(($Cert | Measure).Count -eq 1){
        return $Cert
    }ElseIf(($Cert | Measure).Count -eq 2){
        return $Cert[0]
    }Else{
        return
    }
}


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
                $FormEncoded += "&"
            }
            $FormEncoded+=$Key + "=" + $Object[$Key]
        }
    }else{
        Throw "Cannot convert object of type, '$($Type.Name)', to type 'www-form-encoded'"
    }
    return $FormEncoded;
}

<#function Invoke-OauthTokenRequest{
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
        Write-Log2 -Path $LogLocation -ProcessInfo $ProcInfo -Message "An error has occured, $err" -Level Error
    }
    return $AuthResponse
}#>


$ExportedFunctions+=@("Invoke-SecureWebRequestEx","Get-ClientAuthCert","Invoke-OauthTokenRequest")

Export-ModuleMember -Function $ExportedFunctions