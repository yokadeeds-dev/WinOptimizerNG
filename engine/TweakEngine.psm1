# TweakEngine.psm1 - Kernlogik von WinOptimizerNG.
# Tweaks sind reine Daten (tweaks\tweaks.json). Die Engine prueft ihren Status,
# wendet sie an und setzt sie zurueck. Vor der ersten Anwendung eines Tweaks
# werden die Originalwerte in state.json gesichert - jede Aenderung ist damit
# vollstaendig rueckgaengig machbar.

$script:Root      = Split-Path $PSScriptRoot -Parent
$script:StateFile = Join-Path $script:Root 'state.json'
$script:LogDir    = Join-Path $script:Root 'logs'
$script:TweakFile = Join-Path $script:Root 'tweaks\tweaks.json'

function Write-Log {
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('INFO', 'WARN', 'ERROR')][string]$Level = 'INFO'
    )
    if (-not (Test-Path $script:LogDir)) {
        New-Item -ItemType Directory -Path $script:LogDir | Out-Null
    }
    $logFile = Join-Path $script:LogDir ("winoptng-{0}.log" -f (Get-Date -Format 'yyyy-MM-dd'))
    $line = "{0} [{1,-5}] {2}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    Add-Content -Path $logFile -Value $line -Encoding UTF8
}

function Get-Tweaks {
    # Liefert alle Tweaks, die zur laufenden Windows-Version passen.
    $data = Get-Content $script:TweakFile -Raw -Encoding UTF8 | ConvertFrom-Json
    $build = [Environment]::OSVersion.Version.Build
    $data.tweaks | Where-Object {
        -not $_.PSObject.Properties['minBuild'] -or $build -ge $_.minBuild
    }
}

function Get-RegKeyPath {
    param($Op)
    "{0}:\{1}" -f $Op.hive, $Op.path
}

function Get-RegValueName {
    param($Op)
    if ([string]::IsNullOrEmpty($Op.name)) { '(default)' } else { $Op.name }
}

function Get-RegCurrent {
    # Liest den Ist-Zustand eines Registry-Werts inkl. Existenz von Wert und Schluessel.
    param($Op)
    $key = Get-RegKeyPath $Op
    if (-not (Test-Path $key)) {
        return [pscustomobject]@{ keyExists = $false; valueExists = $false; value = $null }
    }
    $item = Get-Item $key
    $name = if ([string]::IsNullOrEmpty($Op.name)) { '' } else { $Op.name }
    if ($item.GetValueNames() -notcontains $name) {
        return [pscustomobject]@{ keyExists = $true; valueExists = $false; value = $null }
    }
    [pscustomobject]@{ keyExists = $true; valueExists = $true; value = $item.GetValue($name) }
}

function Set-RegValue {
    param($Op)
    $key = Get-RegKeyPath $Op
    if (-not (Test-Path $key)) {
        New-Item -Path $key -Force | Out-Null
    }
    $value = if ($Op.type -eq 'DWord') { [uint32]$Op.value } else { [string]$Op.value }
    Set-ItemProperty -Path $key -Name (Get-RegValueName $Op) -Value $value -Type $Op.type -Force
}

function Get-State {
    if (Test-Path $script:StateFile) {
        Get-Content $script:StateFile -Raw -Encoding UTF8 | ConvertFrom-Json
    }
    else {
        [pscustomobject]@{}
    }
}

function Save-State {
    param($State)
    $State | ConvertTo-Json -Depth 6 | Set-Content $script:StateFile -Encoding UTF8
}

function Test-TweakApplied {
    # true, wenn alle Registry-Werte des Tweaks dem Zielwert entsprechen.
    param($Tweak)
    foreach ($op in $Tweak.ops) {
        $cur = Get-RegCurrent $op
        if (-not $cur.valueExists -or "$($cur.value)" -ne "$($op.value)") {
            return $false
        }
    }
    $true
}

function Invoke-TweakApply {
    param($Tweak, [switch]$DryRun)

    # Originalzustand nur beim ersten Anwenden sichern, damit Undo immer auf
    # den echten Ursprungszustand zurueckfuehrt.
    $state = Get-State
    $hasBackup = [bool]$state.PSObject.Properties[$Tweak.id]
    $backup = @()

    foreach ($op in $Tweak.ops) {
        $cur = Get-RegCurrent $op
        $backup += [pscustomobject]@{
            hive              = $op.hive
            path              = $op.path
            name              = $op.name
            type              = $op.type
            keyExisted        = $cur.keyExists
            valueExisted      = $cur.valueExists
            originalValue     = $cur.value
            deleteKeyOnRevert = [bool]$op.PSObject.Properties['deleteKeyOnRevert']
        }
        if ($DryRun) {
            Write-Log "DRY-RUN: wuerde setzen $(Get-RegKeyPath $op)\$(Get-RegValueName $op) = $($op.value)"
        }
        else {
            Set-RegValue $op
        }
    }

    if (-not $DryRun) {
        if (-not $hasBackup) {
            $state | Add-Member -NotePropertyName $Tweak.id -NotePropertyValue $backup -Force
            Save-State $state
        }
        Write-Log "Angewendet: $($Tweak.id) ($($Tweak.name))"
    }
}

function Invoke-TweakRevert {
    param($Tweak, [switch]$DryRun)

    $state = Get-State
    $prop = $state.PSObject.Properties[$Tweak.id]
    if (-not $prop) {
        throw "Kein Backup fuer '$($Tweak.name)' vorhanden - wurde der Tweak mit diesem Tool angewendet?"
    }

    foreach ($b in $prop.Value) {
        $key = "{0}:\{1}" -f $b.hive, $b.path
        $name = if ([string]::IsNullOrEmpty($b.name)) { '(default)' } else { $b.name }

        if ($DryRun) {
            Write-Log "DRY-RUN: wuerde zuruecksetzen $key\$name"
            continue
        }

        if ($b.valueExisted) {
            $value = if ($b.type -eq 'DWord') { [uint32]$b.originalValue } else { [string]$b.originalValue }
            Set-ItemProperty -Path $key -Name $name -Value $value -Type $b.type -Force
        }
        elseif ($b.keyExisted) {
            Remove-ItemProperty -Path $key -Name $name -Force -ErrorAction SilentlyContinue
        }
        elseif ($b.deleteKeyOnRevert) {
            # Schluessel wurde erst durch den Tweak angelegt -> komplett entfernen.
            Remove-Item -Path $key -Recurse -Force -ErrorAction SilentlyContinue
        }
        else {
            Remove-ItemProperty -Path $key -Name $name -Force -ErrorAction SilentlyContinue
        }
    }

    if (-not $DryRun) {
        $state.PSObject.Properties.Remove($Tweak.id)
        Save-State $state
        Write-Log "Zurueckgesetzt: $($Tweak.id) ($($Tweak.name))"
    }
}

function New-SystemRestorePoint {
    try {
        Write-Log "Erstelle Systemwiederherstellungspunkt..."
        Checkpoint-Computer -Description 'WinOptimizerNG' -RestorePointType 'MODIFY_SETTINGS' -ErrorAction Stop
        Write-Log "Wiederherstellungspunkt erstellt."
        $true
    }
    catch {
        # Haeufigste Ursache: Windows erlaubt nur einen Punkt pro 24h,
        # oder die Systemwiederherstellung ist fuer C: deaktiviert.
        Write-Log "Wiederherstellungspunkt fehlgeschlagen: $($_.Exception.Message)" -Level WARN
        $false
    }
}

function Clear-TempFiles {
    param([switch]$DryRun)
    $targets = @($env:TEMP, "$env:SystemRoot\Temp")
    $freed = 0
    foreach ($dir in $targets) {
        if (-not (Test-Path $dir)) { continue }
        foreach ($item in Get-ChildItem $dir -Force -ErrorAction SilentlyContinue) {
            $size = if ($item.PSIsContainer) {
                (Get-ChildItem $item.FullName -Recurse -Force -ErrorAction SilentlyContinue |
                    Measure-Object Length -Sum).Sum
            }
            else { $item.Length }
            if (-not $DryRun) {
                # Dateien in Benutzung lassen sich nicht loeschen - still ueberspringen.
                Remove-Item $item.FullName -Recurse -Force -ErrorAction SilentlyContinue
                if (Test-Path $item.FullName) { continue }
            }
            $freed += [long]$size
        }
    }
    Write-Log ("Temp-Bereinigung: {0:N1} MB freigegeben (DryRun={1})" -f ($freed / 1MB), [bool]$DryRun)
    [math]::Round($freed / 1MB, 1)
}

Export-ModuleMember -Function Get-Tweaks, Test-TweakApplied, Invoke-TweakApply,
    Invoke-TweakRevert, New-SystemRestorePoint, Clear-TempFiles, Write-Log
