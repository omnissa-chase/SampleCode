<#
.AUTHOR
cbradley@vmware.com
.SYNOPSIS

.DESCRIPTION


#>
$CurrentVersion="250403.0"
$Current_path = $PSScriptRoot;
$ModuleInstallPath = "HKLM:\Software\AIRWATCH\Extensions\WsoApiLite" 

$TLSVersion=""

#Removed TLS1.3 stub as it is currently incompatible with native WebRequest library

Unblock-File "$currentPath\Wso.WebLib.psm1"
#Unblock-File "$currentPath\Wso.CommonLib.psd1"
$module = Import-Module "$currentPath\Wso.WebLib.psm1" -ErrorAction Stop -PassThru -Force;  
    

#Attempts to set the default TLS version for connection to TLS 1.2
If(!($TLSVersion)){
    Try {
        If( [System.Net.ServicePointManager]::SecurityProtocol -ne [System.Net.SecurityProtocolType]::Tls12){ 
            [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
            Write-Log2 -Path $WSOLogLocation -ProcessInfo $ProcInfo -Message "TLS 1.2 has been successfully enabled." -Level Info
        }
    } Catch {
        $err=$_.Exception.Message;
        Write-Log2 -Path $WSOLogLocation -ProcessInfo $ProcInfo -Message "An error has occurred enabling Tls1.2: $err`r`nExiting..." -Level Error
        return
    }
}

<#
.AUTHOR
cbradley@vmware.com
.SYNOPSIS
Gets the currently logged in Windows User
.DESCRIPTION
Lightweight version of Get-CurrentLoggedonUser
.OUTPUTS
Returns a custom PS object that has the following attributes
    Username - user1
    Domain - domain.com
    FullName - domain.com\user1 or user1@domain.com
#>
function Install-WorkspaceOneAPILite{
    If(!(Test-Path "$ModuleInstallPath")){
        $RegResults=New-Item -Path $ModuleInstallPath -Force | Out-Null
    }
    $Configuration=(Get-Item -Path $ModuleInstallPath | Select Configuration -ExpandProperty Configuration -ErrorAction SilentlyContinue) 
}



<#
.AUTHOR
cbradley@vmware.com
.SYNOPSIS
Gets the currently logged in Windows User
.DESCRIPTION
Lightweight version of Get-CurrentLoggedonUser
.OUTPUTS
Returns a custom PS object that has the following attributes
    Username - user1
    Domain - domain.com
    FullName - domain.com\user1 or user1@domain.com
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
        $WebRequest = Invoke-SecureWebRequestEx -Endpoint $Endpoint -Method $Method -Accept $Accept -ContentType $ContentType -Headers $Headers -Data $Data -ClientCertificate $ClientCertificate -SslThumbprint $SslThumbprint -DisableCertificatePinning
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
Gets the currently logged in Windows User
.DESCRIPTION
Lightweight version of Get-CurrentLoggedonUser
.OUTPUTS
Returns a custom PS object that has the following attributes
    Username - user1
    Domain - domain.com
    FullName - domain.com\user1 or user1@domain.com
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


function Get-NextApiPage{
    param($Endpoint, $ReturnObj)
    $PageSize=500
    If($Endpoint -match "pagesize\=([0-9]{1,4})"){
        [int]::TryParse($Matches[1], [ref]$PageSize)
    }
    $Divider="?"
    If($Endpoint -match "([^?]*)\?") { $Divider="&" }
                       
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

