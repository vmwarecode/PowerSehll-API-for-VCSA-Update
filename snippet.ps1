Function Update-VCSA {
    <#
        .SYNOPSIS
            This function updates the VCSA to the specified version.
        .DESCRIPTION
            vCenter Appliance Update Function
        .EXAMPLE
            Update-VCSA -vcenter vcsa-lab00.domain.local -ssouser administrator@vsphere.local -vcupdateversion "7.0.3.00800"
        .EXAMPLE
            Update-VCSA -vcenter vcsa-lab00.domain.local -ssouser administrator@vsphere.local -vcupdateversion "7.0.3.00800" -forceupdate
    #>

    Param(
        [parameter(Mandatory = $false)][string] $vcenter,
        [parameter(Mandatory = $false)][string] $ssouser,
        [parameter(Mandatory = $false)][secureString] $ssopass,
        [parameter(Mandatory = $false)][string] $vcupdateversion,
        [parameter(Mandatory = $false)][switch] $forceupdate
    )


    $ErrorActionPreference = "Stop"
    if (!$vcenter) { $vcenter = Read-Host "Please Enter vCenter to update" }
    if (!$ssouser) { $ssouser = Read-Host "Please enter SSO administrator username (administrator@vsphere.local)" }
    if (!$ssopass) { $ssopass = Read-Host -assecurestring "Please Enter SSO Password" }
    
    $BaseUrl = "https://" + $vcenter + "/api"
    $AuthUrl = $BaseUrl + "/session"
    $systemBaseUrl = $BaseUrl + "/appliance/system"
    $systemVersionUrl = $systemBaseUrl + "/version"
    $systemUpdateUrl = $BaseUrl + "/appliance/update"
    $systemStagedUrl = $BaseUrl + "/appliance/update/staged"
    $systemPendingUrl = $systemUpdateUrl + "/pending"
    $systemCheckUpdateUrl = $systemPendingUrl + "?source_type=LOCAL_AND_ONLINE"
    
    
    # Create API Auth Session
    $auth = $ssouser + ':' + ($ssopass | ConvertFrom-SecureString -AsPlainText)
    $Encoded = [System.Text.Encoding]::UTF8.GetBytes($auth)
    $authorizationInfo = [System.Convert]::ToBase64String($Encoded)
    $headers = New-Object "System.Collections.Generic.Dictionary[[String],[String]]"
    $headers.Add("Authorization", "Basic $($authorizationInfo)")
 
    # Get API Session ID
    $apiSessionId = Invoke-WebRequest $AuthUrl -Method 'POST' -Headers $headers -SkipCertificateCheck
    $sessionId = $apiSessionId.Content | ConvertFrom-Json

    $headers = New-Object "System.Collections.Generic.Dictionary[[String],[String]]"
    $headers.Add("vmware-api-session-id", $sessionId)

    # Get VCSA Version
    $systemVersion = Invoke-WebRequest $systemVersionUrl -Method 'GET' -Headers $headers -SkipCertificateCheck
    $version = ($systemVersion.Content | ConvertFrom-Json) | Select-Object Version, Build

    # Get Update State
    $updateState = Invoke-WebRequest $systemUpdateUrl -Method 'GET' -Headers $headers -SkipCertificateCheck
    
    $currentUpdateState = ($updateState.Content | ConvertFrom-Json).state       

    #Set Default Variables
    if (!$vcupdateversion) { $vcupdateversion = Read-Host "Please provide the version to upgrade to. EXAMPLE:"7.0.3.00800"" }
    $systemUpdateInfoURL = $systemPendingUrl + "/" + $vcupdateversion
    $systemStageUpdateUrl = $systemPendingUrl + "/" + $vcupdateversion + "/" + "?action=stage"
    $systemUpdatePrecheckUrl = $systemUpdateInfoURL + "/" + "?action=precheck"
    $systemUpdateValidateUrl = $systemUpdateInfoURL + "/" + "?action=validate"
    $systemUpdateInstallUrl = $systemUpdateInfoURL + "/" + "?action=install"
    #Update vCenter
    if ($version.version -ne $vcupdateversion -and ($currentUpdateState -ne "UPDATES_PENDING") -or ($forceupdate)) {
        Write-Host "Current Version is $($version.version), updating to $vcupdateversion" -ForegroundColor DarkBlue

        #Check for Updates
        $systemCheckUpdateAPI = Invoke-WebRequest $systemCheckUpdateUrl -Method 'GET' -Headers $headers -SkipCertificateCheck
        if ($null -eq $systemCheckUpdateAPI) {
            Write-Host "Unable to check for updates." -ForegroundColor Yellow
        }
        else {
            #Stage Update
            Write-Host "Staging update $vcupdateversion to vCenter. This may take a while based on vCenter internet speed as it downloads the update." -ForegroundColor Green
            $systemStageUpdateAPI = Invoke-WebRequest $systemStageUpdateUrl -Method 'POST' -Headers $headers -SkipCertificateCheck
            if ($systemStageUpdateAPI.StatusCode -ne "204") {
                Write-Host $systemStageUpdateAPI.StatusCode -ForegroundColor Red
                Write-Host $systemStageUpdateAPI.StatusDescription -ForegroundColor Red
                Write-Host "Please resolve the above errors and re-run the update script." -ForegroundColor Yellow
                Exit
            }
            else {
                do {
                    try {
                        $systemStagedApi = Invoke-WebRequest $systemStagedUrl -Method 'GET' -Headers $headers -SkipCertificateCheck
                        $stagestatus = $systemStagedApi.Content | ConvertFrom-Json
                    }
                    catch {
                        $stagestatus = $null
                        Start-Sleep 5
                    }
                }
                while ($stagestatus.staging_complete -ne "True" -or (!$stagestatus))

                Write-Host "Staging update [DONE]" -ForegroundColor Green
                Write-Host "Running update prechecks..."
                
                $systemUpdatePrecheckAPI = Invoke-WebRequest $systemUpdatePrecheckUrl -Method 'POST' -Headers $headers -SkipCertificateCheck
                $precheckStatus = $systemUpdatePrecheckAPI.Content | ConvertFrom-Json

                if ($precheckStatus.issues.errors.count -ne 0 -or $precheckStatus.issues.warnings.count -ne 0) {
                    Write-Host $precheckStatus.issues.errors
                    Write-Host $precheckStatus.issues.warnings
                    Exit
                }
                else {
                    Write-Host "Prechecks completed successfully!" -ForegroundColor Green
                }
                
                #Validating Update
                Write-Host "Running update validation..."
                $pass = ($ssopass | Convertfrom-SecureString -AsPlainText)
                $body =
                "{""user_data"":
                        {
                            ""value"": ""$pass"",
                            ""key"": ""vmdir.password""
                        }
                    }"
                $headers.Add("Content-Type", "application/json")
                $systemUpdateValidateAPI = Invoke-WebRequest $systemUpdateValidateUrl -Method 'POST' -Headers $headers -body $body -SkipCertificateCheck
                $validationResults = $systemUpdateValidateAPI.Content | ConvertFrom-Json

                if ($validationResults.errors.count -ne 0 -or ($validationResults.warnings.count -ne 0)) {
                    Write-Error $validationResults.warnings
                    Write-Host $validationResults.errors
                    Exit
                }
                else {
                    Write-Host "Validation completed successfully!" -ForegroundColor Green
                }

                #Execute Upgrade
                $startTime = (Get-Date -Format "HH:mm:ss")
                Write-Host "Starting Update..."
                Write-Host "Start time is $startTime"
                $systemUpdateInstallApi = Invoke-WebRequest $systemUpdateInstallUrl -Method 'POST' -Headers $headers -body $body -SkipCertificateCheck
                if ($systemUpdateInstallApi.StatusCode -ne "204") {
                    Write-Host "Unable to start upgrade. Please see logs and VAMI for errors." -ForegroundColor Red
                    Exit
                }
                else {
                    do {
                        try {
                            # Create API Auth Session
                            $auth = $ssouser + ':' + ($ssopass | ConvertFrom-SecureString -AsPlainText)
                            $Encoded = [System.Text.Encoding]::UTF8.GetBytes($auth)
                            $authorizationInfo = [System.Convert]::ToBase64String($Encoded)
                            $headers = New-Object "System.Collections.Generic.Dictionary[[String],[String]]"
                            $headers.Add("Authorization", "Basic $($authorizationInfo)")
                        
                            # Get API Session ID
                            $apiSessionId = Invoke-WebRequest $AuthUrl -Method 'POST' -Headers $headers -SkipCertificateCheck
                            $sessionId = $apiSessionId.Content | ConvertFrom-Json
                    
                            $headers = New-Object "System.Collections.Generic.Dictionary[[String],[String]]"
                            $headers.Add("vmware-api-session-id", $sessionId)
                    
                            $updateState = Invoke-WebRequest $systemUpdateUrl -Method 'GET' -Headers $headers -SkipCertificateCheck
                            $currentUpdateState = ($updateState.Content | ConvertFrom-Json).state
                            Write-Host . -NoNewline
                        }
                        catch { $currentUpdateState = $null }
                        Start-Sleep 5
                    }
                    while ($currentUpdateState -eq "INSTALL_IN_PROGRESS" -or (!$currentUpdateState))
                    
                    if ($currentUpdateState -ne "UP_TO_DATE") {
                        Write-Error "Upgrade Failed! Please see logs and VAMI for further information."
                    }
                    else { 
                        Write-host "Update complete!" -ForegroundColor Green
                        $endTime = (Get-Date -Format "HH:mm:ss")
                        Write-Host "Completion time is $endTime"
                    }
                }
            }
        }
    } else {
        Write-Host "Current Version is $($version.version), no need to update"
    }
}