# Run once on sword, from an elevated PowerShell. Registers a startup task that
# boots WSL Ubuntu, whose systemd then starts the sword-td GitHub Actions
# runner for dominics/td. Without it nothing starts WSL after a reboot.
$ErrorActionPreference = 'Stop'
$action = New-ScheduledTaskAction -Execute 'C:\Windows\System32\wsl.exe' `
  -Argument '-d Ubuntu -u root -- systemctl start actions.runner.dominics-td.sword-td.service'
$trigger = New-ScheduledTaskTrigger -AtStartup
$principal = New-ScheduledTaskPrincipal -UserId 'Dominic' -LogonType S4U -RunLevel Highest
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
  -ExecutionTimeLimit (New-TimeSpan -Minutes 5)
Register-ScheduledTask -TaskName 'StartWslForTdRunner' -Action $action -Trigger $trigger `
  -Principal $principal -Settings $settings -Force `
  -Description 'Boots WSL Ubuntu so the sword-td GitHub Actions runner for dominics/td starts.' | Out-Null
Start-ScheduledTask -TaskName 'StartWslForTdRunner'
Start-Sleep 10
Get-ScheduledTaskInfo -TaskName 'StartWslForTdRunner' | Select-Object LastRunTime, LastTaskResult | Format-List
