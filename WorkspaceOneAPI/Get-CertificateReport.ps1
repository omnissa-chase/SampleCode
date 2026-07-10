$CsvFilename=".\DeviceCertificates$((Get-Date).ToString("yyyy-MM-dd")).csv"

#Get common library items.
Unblock-File "$PSScriptRoot\Wso.ApiLib.psm1"
$module = Import-Module "$PSScriptRoot\Wso.ApiLib.psm1" -ErrorAction Stop -PassThru -Force;

$ApiConfig=@{
    "Server"="https://asXXXX.awmdm.com";  #Put your cn # in the X.  'as' is for the api server
    "Username"="administrator";  #admin username (you may need to create a local admin in the console.)  Should copy exactly what is in the console and dont forget to check that the account has the API enabled.
    "Password"='PASSWORD'; #admin password (don't mind sharing this since its unused)
    "ApiKey"="H5ItI7rka2YfmEU0am9B8dlIu7cTn0LqYOrJOqRLPis=";  # All Settings -> General -> Advanced -> API (you should be able to copy the top key)
    "OrganizationGroupId"=470 #Not required but you can get this from the Organization Group page by inspecting the URI in your browser

}

$ApiSettings=New-Object -TypeName PSCustomObject -Property $ApiConfig

$DevicesEndpoint= "api/mdm/devices/search"

$Devices = Invoke-WorkspaceOneAPICommand -Endpoint $DevicesEndpoint -ApiSettings $ApiSettings -ApiVersion 2
$DeviceIds=$Devices.Devices | Select Id
$Certificates=@()
foreach($Device in $DeviceIds){
    $CertificatePath="api/mdm/devices/$($Device.Id.Value)/certificates"
    $DeviceCertificates = @(Invoke-WorkspaceOneAPICommand -Endpoint $CertificatePath -ApiSettings $ApiSettings -ApiVersion 1)
    if(($DeviceCertificates | Measure).Count -gt 0){
        $Certificates += $DeviceCertificates[0].DeviceCertificates
    }
}

$Certificates | ConvertTo-Csv | Out-File "$PSScriptRoot\$CsvFilename"