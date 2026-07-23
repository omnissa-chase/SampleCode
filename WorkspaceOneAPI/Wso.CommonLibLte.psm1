<#
.SYNOPSIS
This function encodes the credentials for use with REST APIs
.DESCRIPTION
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


function ConvertTo-EncryptedFile{
    param([string]$FileContents)
    $ProcInfo=GetLogPos -FileName $CurrentModuleFileName -FunctionName $MyInvocation.MyCommand
    Try{
        $secured = ConvertTo-SecureString -String $FileContents -AsPlainText -Force;
        $encrypted = ConvertFrom-SecureString -SecureString $secured
    } Catch {
        $ErrorMessage = $_.Exception.Message;
        Write-Log2 -Path $CommonLogLocation -ProcessInfo $ProcInfo -Message "An error has occurrred.  Error: $ErrorMessage"
        return "Error";
    }
    return $encrypted;
}

function ConvertFrom-EncryptedFile{
    param([string]$FileContents)
    $ProcInfo=GetLogPos -FileName $CurrentModuleFileName -FunctionName $MyInvocation.MyCommand
    Try{
        $decrypter = ConvertTo-SecureString -String $FileContents.Trim() -ErrorAction Stop;
        $BSTR = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($decrypter)
        $api_settings = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($BSTR)
    } Catch {
        $ErrorMessage = $_.Exception.Message;
        Write-Log2 -Path $CommonLogLocation -ProcessInfo $ProcInfo -Message "An error has occurrred.  Error: $ErrorMessage"
        return "Error: $ErrorMessage";
    }
    return $api_settings
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

Function Get-LogPos {
    [Alias("GetLogPos")]
    param([string]$FileName,[string]$ClassName,[string]$FunctionName,[string]$SourceName="") 
    
    If($ClassName){
        $FileName = "$ClassName"
    }
    If($SourceName){
        $SourceName="$SourceName->"
    }
    return " ({0}) {3}[{1}::{2}] " -f ([Random]::new().Next(999)), $FileName, $FunctionName, $SourceName;
}