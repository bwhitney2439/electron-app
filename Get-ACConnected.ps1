Param (
    [Parameter(Mandatory = $false)]
    [ValidateNotNullOrEmpty()]
    [switch]$PassThru = $false
)
    
Begin {

    ## Variables: Environment
    If (Test-Path -LiteralPath 'variable:HostInvocation') { $InvocationInfo = $HostInvocation } Else { $InvocationInfo = $MyInvocation }
    [string]$scriptDirectory = Split-Path -Path $MyInvocation.MyCommand.Definition -Parent

    ## Dot source the required App Deploy Toolkit Functions
    Try {
        [string]$moduleAppDeployToolkitMain = "$scriptDirectory\AppDeployToolkit\AppDeployToolkitMain.ps1"
        # [string]$moduleAppDeployToolkitMain = "$scriptDirectory\Helper-Functions.ps1"
        If (-not (Test-Path -LiteralPath $moduleAppDeployToolkitMain -PathType 'Leaf')) { Throw "Module does not exist at the specified location [$moduleAppDeployToolkitMain]." }
        If ($DisableLogging) { . $moduleAppDeployToolkitMain -DisableLogging } Else { . $moduleAppDeployToolkitMain }
    }
    Catch {
        If ($mainExitCode -eq 0) { [int32]$mainExitCode = 60008 }
        Write-Error -Message "Module [$moduleAppDeployToolkitMain] failed to load: `n$($_.Exception.Message)`n `n$($_.InvocationInfo.PositionMessage)" -ErrorAction 'Continue'
        ## Exit the script, returning the exit code to SCCM
        If (Test-Path -LiteralPath 'variable:HostInvocation') { $script:ExitCode = $mainExitCode; Exit } Else { Exit $mainExitCode }
    }

    ## Get the name of this function and write header
    [string]${CmdletName} = $PSCmdlet.MyInvocation.MyCommand.Name
    Write-FunctionHeaderOrFooter -CmdletName ${CmdletName} -CmdletBoundParameters $PSBoundParameters -Header
    
    ## PowerStatus class found in this assembly is more reliable than WMI in cases where the battery is failing.
    Add-Type -Assembly 'System.Windows.Forms' -ErrorAction 'SilentlyContinue'
    
    ## Initialize a hashtable to store information about system type and power status
    [hashtable]$SystemTypePowerStatus = @{ }
}
Process {
    Write-Log -Message 'Check if system is using AC power or if it is running on battery...' -Source ${CmdletName}
    
    [Windows.Forms.PowerStatus]$PowerStatus = [Windows.Forms.SystemInformation]::PowerStatus
    
    ## Get the system power status. Indicates whether the system is using AC power or if the status is unknown. Possible values:
    #	Offline : The system is not using AC power.
    #	Online  : The system is using AC power.
    #	Unknown : The power status of the system is unknown.
    [string]$PowerLineStatus = $PowerStatus.PowerLineStatus
    $SystemTypePowerStatus.Add('ACPowerLineStatus', $PowerStatus.PowerLineStatus)
    
    ## Get the current battery charge status. Possible values: High, Low, Critical, Charging, NoSystemBattery, Unknown.
    [string]$BatteryChargeStatus = $PowerStatus.BatteryChargeStatus
    $SystemTypePowerStatus.Add('BatteryChargeStatus', $PowerStatus.BatteryChargeStatus)
    
    ## Get the approximate amount, from 0.00 to 1.0, of full battery charge remaining.
    #  This property can report 1.0 when the battery is damaged and Windows can't detect a battery.
    #  Therefore, this property is only indicative of battery charge remaining if 'BatteryChargeStatus' property is not reporting 'NoSystemBattery' or 'Unknown'.
    [single]$BatteryLifePercent = $PowerStatus.BatteryLifePercent
    If (($BatteryChargeStatus -eq 'NoSystemBattery') -or ($BatteryChargeStatus -eq 'Unknown')) {
        [single]$BatteryLifePercent = 0.0
    }
    $SystemTypePowerStatus.Add('BatteryLifePercent', $PowerStatus.BatteryLifePercent)
    
    ## The reported approximate number of seconds of battery life remaining. It will report –1 if the remaining life is unknown because the system is on AC power.
    [int32]$BatteryLifeRemaining = $PowerStatus.BatteryLifeRemaining
    $SystemTypePowerStatus.Add('BatteryLifeRemaining', $PowerStatus.BatteryLifeRemaining)
    
    ## Get the manufacturer reported full charge lifetime of the primary battery power source in seconds.
    #  The reported number of seconds of battery life available when the battery is fully charged, or -1 if it is unknown.
    #  This will only be reported if the battery supports reporting this information. You will most likely get -1, indicating unknown.
    [int32]$BatteryFullLifetime = $PowerStatus.BatteryFullLifetime
    $SystemTypePowerStatus.Add('BatteryFullLifetime', $PowerStatus.BatteryFullLifetime)
    
    ## Determine if the system is using AC power
    [boolean]$OnACPower = $false
    If ($PowerLineStatus -eq 'Online') {
        Write-Log -Message 'System is using AC power.' -Source ${CmdletName}
        $OnACPower = $true
    }
    ElseIf ($PowerLineStatus -eq 'Offline') {
        Write-Log -Message 'System is using battery power.' -Source ${CmdletName}
    }
    ElseIf ($PowerLineStatus -eq 'Unknown') {
        If (($BatteryChargeStatus -eq 'NoSystemBattery') -or ($BatteryChargeStatus -eq 'Unknown')) {
            Write-Log -Message "System power status is [$PowerLineStatus] and battery charge status is [$BatteryChargeStatus]. This is most likely due to a damaged battery so we will report system is using AC power." -Source ${CmdletName}
            $OnACPower = $true
        }
        Else {
            Write-Log -Message "System power status is [$PowerLineStatus] and battery charge status is [$BatteryChargeStatus]. Therefore, we will report system is using battery power." -Source ${CmdletName}
        }
    }
    $SystemTypePowerStatus.Add('IsUsingACPower', $OnACPower)
    
    ## Determine if the system is a laptop
    [boolean]$IsLaptop = $false
    If (($BatteryChargeStatus -eq 'NoSystemBattery') -or ($BatteryChargeStatus -eq 'Unknown')) {
        $IsLaptop = $false
    }
    Else {
        $IsLaptop = $true
    }
    #  Chassis Types
    [int32[]]$ChassisTypes = Get-WmiObject -Class 'Win32_SystemEnclosure' | Where-Object { $_.ChassisTypes } | Select-Object -ExpandProperty 'ChassisTypes'
    Write-Log -Message "The following system chassis types were detected [$($ChassisTypes -join ',')]." -Source ${CmdletName}
    ForEach ($ChassisType in $ChassisTypes) {
        Switch ($ChassisType) {
            { $_ -eq 9 -or $_ -eq 10 -or $_ -eq 14 } { $IsLaptop = $true } # 9=Laptop, 10=Notebook, 14=Sub Notebook
            { $_ -eq 3 } { $IsLaptop = $false } # 3=Desktop
        }
    }
    #  Add IsLaptop property to hashtable
    $SystemTypePowerStatus.Add('IsLaptop', $IsLaptop)
    
    If ($PassThru) {
        Write-Output -InputObject $SystemTypePowerStatus
    }
    Else {
        Write-Output -InputObject $OnACPower
    }
}
End {
    Write-FunctionHeaderOrFooter -CmdletName ${CmdletName} -Footer
}