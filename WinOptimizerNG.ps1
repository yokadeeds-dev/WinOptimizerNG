# WinOptimizerNG - modulares Windows-Tuning-Tool (PowerShell 5.1+).
# Inspiriert vom WINDOWS-OPTIMIZER-PROJECT (GPL-3.0), komplett neu umgesetzt:
# jeder Tweak einzeln schaltbar, mit Backup, Undo und Logging.
#
# Start:  Rechtsklick > "Mit PowerShell ausfuehren"  (fordert selbst Admin-Rechte an)
# Oder:   powershell -ExecutionPolicy Bypass -File .\WinOptimizerNG.ps1 [-DryRun]

[CmdletBinding()]
param(
    # Zeigt nur an, was geaendert wuerde - schreibt nichts in die Registry.
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'

# --- Selbst-Elevation -------------------------------------------------------
$identity = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $identity.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    $argList = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
    if ($DryRun) { $argList += ' -DryRun' }
    Start-Process powershell.exe -ArgumentList $argList -Verb RunAs
    exit
}

Import-Module (Join-Path $PSScriptRoot 'engine\TweakEngine.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'engine\Benchmark.psm1') -Force

function Show-Menu {
    param($Tweaks)

    Clear-Host
    Write-Host ''
    Write-Host '  WinOptimizerNG v0.1.0' -ForegroundColor Cyan
    if ($DryRun) { Write-Host '  *** DRY-RUN: Es wird nichts geaendert ***' -ForegroundColor Yellow }
    Write-Host '  ---------------------------------------------------------------'

    $i = 0
    $lastCategory = ''
    foreach ($t in $Tweaks) {
        $i++
        if ($t.category -ne $lastCategory) {
            $lastCategory = $t.category
            Write-Host ''
            Write-Host "  $($t.category)" -ForegroundColor DarkCyan
        }
        $applied = Test-TweakApplied $t
        $marker = if ($applied) { '[AKTIV]' } else { '[     ]' }
        $color = if ($applied) { 'Green' } else { 'Gray' }
        $star = if ($t.recommended) { '*' } else { ' ' }
        Write-Host ("  {0,3}. {1} {2}{3}" -f $i, $marker, $star, $t.name) -ForegroundColor $color
    }

    Write-Host ''
    Write-Host '  ---------------------------------------------------------------'
    Write-Host '  Nummer  = Tweak umschalten (an/aus)   * = empfohlen'
    Write-Host '  i <Nr>  = Details zu einem Tweak'
    Write-Host '  a       = alle empfohlenen Tweaks anwenden'
    Write-Host '  b       = Systemstart analysieren (Boot-/Autostart-Vergleich)'
    Write-Host '  w       = Wiederherstellungspunkt erstellen'
    Write-Host '  t       = Temp-Dateien bereinigen'
    Write-Host '  q       = Beenden'
    Write-Host ''
}

function Invoke-Toggle {
    param($Tweak)
    if (Test-TweakApplied $Tweak) {
        Invoke-TweakRevert $Tweak -DryRun:$DryRun
        Write-Host "  '$($Tweak.name)' zurueckgesetzt." -ForegroundColor Yellow
    }
    else {
        Invoke-TweakApply $Tweak -DryRun:$DryRun
        Write-Host "  '$($Tweak.name)' angewendet." -ForegroundColor Green
    }
    if ($Tweak.PSObject.Properties['note'] -and $Tweak.note) {
        Write-Host "  Hinweis: $($Tweak.note)" -ForegroundColor DarkYellow
    }
}

$tweaks = @(Get-Tweaks | Sort-Object category, name)
if (-not $tweaks) {
    Write-Host 'Keine Tweak-Definitionen gefunden (tweaks\tweaks.json fehlt?).' -ForegroundColor Red
    exit 1
}

Write-Log "Gestartet (DryRun=$([bool]$DryRun), Build=$([Environment]::OSVersion.Version.Build))"

# Beim ersten echten Lauf einen Wiederherstellungspunkt anbieten.
if (-not $DryRun -and -not (Test-Path (Join-Path $PSScriptRoot 'state.json'))) {
    $answer = Read-Host 'Vor der ersten Aenderung einen Systemwiederherstellungspunkt erstellen? (j/n)'
    if ($answer -match '^[jJyY]') {
        if (New-SystemRestorePoint) {
            Write-Host 'Wiederherstellungspunkt erstellt.' -ForegroundColor Green
        }
        else {
            Write-Host 'Konnte keinen Wiederherstellungspunkt erstellen (siehe Log). Fortfahren auf eigene Verantwortung.' -ForegroundColor Yellow
        }
    }
}

while ($true) {
    Show-Menu $tweaks
    $choice = (Read-Host '  Auswahl').Trim()

    try {
        switch -Regex ($choice) {
            '^q$' {
                Write-Log 'Beendet.'
                return
            }
            '^a$' {
                foreach ($t in $tweaks | Where-Object { $_.recommended -and -not (Test-TweakApplied $_) }) {
                    Invoke-TweakApply $t -DryRun:$DryRun
                    Write-Host "  '$($t.name)' angewendet." -ForegroundColor Green
                }
            }
            '^b$' {
                $history = @(Get-BenchmarkHistory)
                $label = if ($history.Count -eq 0) { 'vorher' } else { 'nachher' }
                Write-Host "  Lese Systemstart-Daten ('$label')..." -ForegroundColor Cyan
                $result = Invoke-Benchmark -Label $label
                if ($null -ne $result.bootTimeMs) {
                    Write-Host ("  Bootzeit: {0:N0} ms | bis Desktop: {1:N0} ms | Autostart-Last: {2:N0} ms | Autostarts: {3} | Start-Delay: {4}" -f `
                        $result.bootTimeMs, $result.mainPathBootMs, $result.postBootMs, $result.autostartCount, `
                        $(if ($null -ne $result.startupDelayMs) { "$($result.startupDelayMs) ms" } else { 'Default' })) -ForegroundColor Green
                }
                else {
                    Write-Host ("  Keine Boot-Leistungsdaten verfuegbar (Diagnostics-Performance-Log leer). Autostarts: {0}" -f $result.autostartCount) -ForegroundColor Yellow
                }
                if ($history.Count -gt 0) {
                    Write-Host "  Vergleich mit erstem Lauf ($($history[0].timestamp)):"
                    Compare-Benchmark -Before $history[0] -After $result
                }
                else {
                    Write-Host '  Basiswert gespeichert. Wende jetzt Tweaks an, starte Windows NEU und miss danach erneut.' -ForegroundColor DarkYellow
                }
            }
            '^w$' {
                if (New-SystemRestorePoint) {
                    Write-Host '  Wiederherstellungspunkt erstellt.' -ForegroundColor Green
                }
                else {
                    Write-Host '  Fehlgeschlagen - Details im Log. (Windows erlaubt nur einen Punkt pro 24h.)' -ForegroundColor Yellow
                }
            }
            '^t$' {
                $mb = Clear-TempFiles -DryRun:$DryRun
                Write-Host "  $mb MB freigegeben." -ForegroundColor Green
            }
            '^i\s+\d+$' {
                $idx = [int]($choice -replace '^i\s+') - 1
                if ($idx -ge 0 -and $idx -lt $tweaks.Count) {
                    $t = $tweaks[$idx]
                    Write-Host ''
                    Write-Host "  $($t.name)" -ForegroundColor Cyan
                    Write-Host "  $($t.description)"
                    foreach ($op in $t.ops) {
                        Write-Host ("  -> {0}:\{1} | {2} = {3}" -f $op.hive, $op.path, $op.name, $op.value) -ForegroundColor DarkGray
                    }
                }
            }
            '^\d+$' {
                $idx = [int]$choice - 1
                if ($idx -ge 0 -and $idx -lt $tweaks.Count) {
                    Invoke-Toggle $tweaks[$idx]
                }
                else {
                    Write-Host '  Ungueltige Nummer.' -ForegroundColor Red
                }
            }
            default {
                Write-Host '  Unbekannte Eingabe.' -ForegroundColor Red
            }
        }
    }
    catch {
        Write-Log "Fehler bei Auswahl '$choice': $($_.Exception.Message)" -Level ERROR
        Write-Host "  Fehler: $($_.Exception.Message)" -ForegroundColor Red
    }

    Write-Host ''
    Read-Host '  Weiter mit Enter' | Out-Null
}
