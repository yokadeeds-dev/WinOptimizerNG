# Benchmark.psm1 - Systemstart-Analyse fuer WinOptimizerNG.
# Misst die Groessen, die die Tweaks tatsaechlich bewegen: Boot- und
# Nachstart-Zeit (aus dem Windows-Ereignisprotokoll Diagnostics-Performance)
# sowie Autostart-Eintraege und Start-Verzoegerungen. Anders als CPU-/RAM-/
# Disk-Mikrobenchmarks reagieren diese Werte auf Autostart- und Startverzoege-
# rungs-Tweaks (perf-startup-delay, priv-*, weniger Autostarts).
#
# WICHTIG: Boot-Werte stammen aus dem LETZTEN echten Systemstart. Sie aendern
# sich erst NACH einem Neustart. Ablauf fuer einen ehrlichen Vergleich:
#   1. Benchmark ('vorher') -> speichert aktuelle Boot-/Autostart-Werte
#   2. Tweaks anwenden
#   3. Windows neu starten
#   4. Benchmark ('nachher') -> vergleicht mit dem neuen Bootvorgang

$script:Root     = Split-Path $PSScriptRoot -Parent
$script:BenchDir = Join-Path $script:Root 'benchmarks'

function Get-BootPerformance {
    # Liest die letzte Boot-Leistungsmessung (Event 100) aus dem
    # Diagnostics-Performance-Log. Alle Zeiten in ms. $null, wenn das Log
    # leer/deaktiviert ist (Dienst DPS aus) oder der Zugriff scheitert.
    try {
        $ev = Get-WinEvent -FilterHashtable @{
            LogName = 'Microsoft-Windows-Diagnostics-Performance/Operational'
            Id      = 100
        } -MaxEvents 1 -ErrorAction Stop
    }
    catch {
        Write-Log "Boot-Leistungsdaten nicht verfuegbar: $($_.Exception.Message)" -Level WARN
        return $null
    }

    $data = @{}
    foreach ($d in ([xml]$ev.ToXml()).Event.EventData.Data) { $data[$d.Name] = $d.'#text' }
    [pscustomobject]@{
        bootTimeMs     = [int]$data['BootTime']          # Gesamt-Bootzeit
        mainPathBootMs = [int]$data['MainPathBootTime']  # bis nutzbarer Desktop
        postBootMs     = [int]$data['BootPostBootTime']  # Desktop -> System im Leerlauf (Autostart-Last)
        bootEventTime  = $ev.TimeCreated.ToString('yyyy-MM-dd HH:mm:ss')
    }
}

function Get-AutostartCount {
    # Anzahl der Autostart-Eintraege (Run-Keys + Startup-Ordner + Aufgaben).
    @(Get-CimInstance Win32_StartupCommand -ErrorAction SilentlyContinue).Count
}

function Get-StartupDelayMs {
    # StartupDelayInMSec: direkt von perf-startup-delay betroffen.
    # $null, wenn der Wert fehlt (dann gilt der Windows-Default).
    $p = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Serialize'
    if (Test-Path $p) {
        $v = (Get-ItemProperty $p -Name StartupDelayInMSec -ErrorAction SilentlyContinue).StartupDelayInMSec
        if ($null -ne $v) { return [int]$v }
    }
    $null
}

function Get-SystemSnapshot {
    $os = Get-CimInstance Win32_OperatingSystem
    [pscustomobject]@{
        cpu          = (Get-CimInstance Win32_Processor).Name
        totalRamGB   = [math]::Round($os.TotalVisibleMemorySize / 1MB, 1)
        freeRamGB    = [math]::Round($os.FreePhysicalMemory / 1MB, 1)
        processCount = (Get-Process).Count
        uptimeHours  = [math]::Round(((Get-Date) - $os.LastBootUpTime).TotalHours, 1)
    }
}

function Invoke-Benchmark {
    # Erfasst die aktuellen Systemstart-Kennzahlen, speichert sie und gibt sie
    # zurueck. Laeuft in Sekunden (nur Ereignisprotokoll- und WMI-Abfragen).
    param([string]$Label = '')

    $boot = Get-BootPerformance

    $result = [pscustomobject]@{
        timestamp      = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
        label          = $Label
        bootTimeMs     = if ($boot) { $boot.bootTimeMs }     else { $null }
        mainPathBootMs = if ($boot) { $boot.mainPathBootMs } else { $null }
        postBootMs     = if ($boot) { $boot.postBootMs }     else { $null }
        bootEventTime  = if ($boot) { $boot.bootEventTime }  else { $null }
        autostartCount = Get-AutostartCount
        startupDelayMs = Get-StartupDelayMs
        system         = Get-SystemSnapshot
    }

    if (-not (Test-Path $script:BenchDir)) {
        New-Item -ItemType Directory -Path $script:BenchDir | Out-Null
    }
    $file = Join-Path $script:BenchDir ("bench-{0}.json" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
    $result | ConvertTo-Json -Depth 4 | Set-Content $file -Encoding UTF8
    $result
}

function Get-BenchmarkHistory {
    # Alle gespeicherten Laeufe, aeltester zuerst.
    if (-not (Test-Path $script:BenchDir)) { return @() }
    Get-ChildItem $script:BenchDir -Filter 'bench-*.json' | Sort-Object Name | ForEach-Object {
        Get-Content $_.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
    }
}

function Compare-Benchmark {
    # Vergleichstabelle zweier Laeufe. Bei allen Start-Metriken ist weniger
    # besser. noisePct ist die uebliche Schwankung zwischen zwei echten Boots;
    # Deltas darunter gelten als Rauschen, nicht als Wirkung. autostartCount und
    # startupDelayMs sind exakte Zaehler/Einstellungen -> kein Rauschband.
    param($Before, $After)

    $metrics = @(
        @{ key = 'bootTimeMs';     name = 'Bootzeit gesamt (ms)';   noisePct = 12 },
        @{ key = 'mainPathBootMs'; name = 'Zeit bis Desktop (ms)';  noisePct = 12 },
        @{ key = 'postBootMs';     name = 'Autostart-Last (ms)';    noisePct = 20 },
        @{ key = 'autostartCount'; name = 'Autostart-Eintraege';    noisePct = 0  },
        @{ key = 'startupDelayMs'; name = 'Startverzoegerung (ms)'; noisePct = 0  }
    )

    # Gleicher Bootvorgang? Dann sind die Boot-Werte identisch - Hinweis geben.
    if ($Before.bootEventTime -and $Before.bootEventTime -eq $After.bootEventTime) {
        Write-Host ''
        Write-Host '  Hinweis: Beide Messungen stammen vom selben Bootvorgang.' -ForegroundColor Yellow
        Write-Host '  Fuer einen echten Boot-Vergleich bitte neu starten und danach erneut messen.' -ForegroundColor Yellow
    }

    Write-Host ''
    Write-Host ("  {0,-24} {1,12} {2,12} {3,10}  {4}" -f 'Metrik', 'Vorher', 'Nachher', 'Delta', 'Bewertung') -ForegroundColor Cyan
    Write-Host ('  ' + '-' * 74)

    foreach ($m in $metrics) {
        $bRaw = $Before.($m.key)
        $aRaw = $After.($m.key)

        # Nicht verfuegbare Werte (z.B. kein Boot-Log) sauber ausweisen.
        if ($null -eq $bRaw -or $null -eq $aRaw) {
            Write-Host ("  {0,-24} {1,12} {2,12} {3,10}  {4}" -f $m.name, '(n/v)', '(n/v)', '-', 'keine Daten') -ForegroundColor DarkGray
            continue
        }

        $b = [double]$bRaw
        $a = [double]$aRaw
        $delta = if ($b -eq 0) { if ($a -eq 0) { 0 } else { 100 } } else { (($a - $b) / $b) * 100 }
        $improved = $a -lt $b   # bei allen Start-Metriken: weniger = besser

        if ([math]::Abs($delta) -lt $m.noisePct) {
            $color = 'DarkGray'; $verdict = "Rauschen (<$($m.noisePct)%)"
        }
        elseif ($a -eq $b) {
            $color = 'DarkGray'; $verdict = 'unveraendert'
        }
        elseif ($improved) {
            $color = 'Green'; $verdict = 'besser'
        }
        else {
            $color = 'Red'; $verdict = 'schlechter'
        }
        Write-Host ("  {0,-24} {1,12:N0} {2,12:N0} {3,9:+0.0;-0.0}%  {4}" -f $m.name, $b, $a, $delta, $verdict) -ForegroundColor $color
    }
    Write-Host ''
    Write-Host '  Boot-Werte stammen aus dem letzten Systemstart und aendern sich erst nach einem Neustart.' -ForegroundColor DarkGray
}

Export-ModuleMember -Function Invoke-Benchmark, Get-BenchmarkHistory, Compare-Benchmark
