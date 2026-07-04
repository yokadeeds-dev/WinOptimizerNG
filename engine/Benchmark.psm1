# Benchmark.psm1 - Vorher/Nachher-Leistungsmessung fuer WinOptimizerNG.
# Vier schnelle Micro-Benchmarks (~10 Sekunden gesamt). Ergebnisse werden als
# JSON in benchmarks\ gespeichert; Compare-Benchmark zeigt die Differenz
# zweier Laeufe. Unterschiede unter ~5% sind Messrauschen, keine Wirkung.

$script:Root     = Split-Path $PSScriptRoot -Parent
$script:BenchDir = Join-Path $script:Root 'benchmarks'

function Measure-CpuScore {
    # SHA256-Hashes pro Sekunde ueber 2 Sekunden - reine CPU-Last, single-thread.
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $buf = [byte[]]::new(8192)
    $ops = 0
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt 2000) {
        [void]$sha.ComputeHash($buf)
        $ops++
    }
    $sw.Stop()
    $sha.Dispose()
    [math]::Round($ops / $sw.Elapsed.TotalSeconds)
}

function Measure-MemoryScore {
    # Speicher-Durchsatz in MB/s: 64-MB-Block mehrfach kopieren.
    $size = 64MB
    $src = [byte[]]::new($size)
    $dst = [byte[]]::new($size)
    $copies = 0
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt 2000) {
        [Array]::Copy($src, $dst, $size)
        $copies++
    }
    $sw.Stop()
    [math]::Round(($copies * 64) / $sw.Elapsed.TotalSeconds)
}

function Measure-DiskScore {
    # Sequenzielles Schreiben und Lesen einer 100-MB-Datei in MB/s.
    # Das Lesen erfolgt direkt nach dem Schreiben und profitiert vom
    # Windows-Cache - fuer Vorher/Nachher-Vergleiche trotzdem brauchbar,
    # da beide Laeufe gleich behandelt werden.
    $file = Join-Path $env:TEMP 'winoptng-bench.tmp'
    $sizeMB = 100
    $buf = [byte[]]::new(1MB)
    (New-Object Random).NextBytes($buf)
    try {
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $fs = [System.IO.File]::Create($file)
        for ($i = 0; $i -lt $sizeMB; $i++) { $fs.Write($buf, 0, $buf.Length) }
        $fs.Flush($true)
        $fs.Close()
        $sw.Stop()
        $writeMBs = [math]::Round($sizeMB / $sw.Elapsed.TotalSeconds)

        $sw.Restart()
        $fs = [System.IO.File]::OpenRead($file)
        while ($fs.Read($buf, 0, $buf.Length) -gt 0) { }
        $fs.Close()
        $sw.Stop()
        $readMBs = [math]::Round($sizeMB / $sw.Elapsed.TotalSeconds)

        [pscustomobject]@{ writeMBs = $writeMBs; readMBs = $readMBs }
    }
    finally {
        Remove-Item $file -Force -ErrorAction SilentlyContinue
    }
}

function Measure-ProcessSpawn {
    # Durchschnittliche Zeit in ms, um einen Prozess zu starten und zu beenden.
    # Reagiert auf Systemlast durch Hintergrunddienste.
    $runs = 8
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    for ($i = 0; $i -lt $runs; $i++) {
        $p = Start-Process cmd.exe -ArgumentList '/c exit' -WindowStyle Hidden -PassThru
        $p.WaitForExit()
    }
    $sw.Stop()
    [math]::Round($sw.Elapsed.TotalMilliseconds / $runs, 1)
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
    # Fuehrt alle Messungen aus, speichert das Ergebnis und liefert es zurueck.
    param([string]$Label = '')

    Write-Host '  Messe CPU...' -ForegroundColor DarkGray
    $cpu = Measure-CpuScore
    Write-Host '  Messe RAM-Durchsatz...' -ForegroundColor DarkGray
    $mem = Measure-MemoryScore
    Write-Host '  Messe Datentraeger...' -ForegroundColor DarkGray
    $disk = Measure-DiskScore
    Write-Host '  Messe Prozessstart...' -ForegroundColor DarkGray
    $spawn = Measure-ProcessSpawn

    $result = [pscustomobject]@{
        timestamp    = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
        label        = $Label
        cpuHashesSec = $cpu
        memCopyMBs   = $mem
        diskWriteMBs = $disk.writeMBs
        diskReadMBs  = $disk.readMBs
        spawnMs      = $spawn
        system       = Get-SystemSnapshot
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
    # Gibt eine Vergleichstabelle zweier Laeufe aus. HigherIsBetter gilt fuer
    # alle Metriken ausser spawnMs.
    param($Before, $After)

    $metrics = @(
        @{ key = 'cpuHashesSec'; name = 'CPU (Hashes/s)';        higherBetter = $true },
        @{ key = 'memCopyMBs';   name = 'RAM-Durchsatz (MB/s)';  higherBetter = $true },
        @{ key = 'diskWriteMBs'; name = 'Disk schreiben (MB/s)'; higherBetter = $true },
        @{ key = 'diskReadMBs';  name = 'Disk lesen (MB/s)';     higherBetter = $true },
        @{ key = 'spawnMs';      name = 'Prozessstart (ms)';     higherBetter = $false }
    )

    Write-Host ''
    Write-Host ("  {0,-24} {1,12} {2,12} {3,10}" -f 'Metrik', 'Vorher', 'Nachher', 'Delta') -ForegroundColor Cyan
    Write-Host ('  ' + '-' * 62)

    foreach ($m in $metrics) {
        $b = [double]$Before.($m.key)
        $a = [double]$After.($m.key)
        if ($b -eq 0) { continue }
        $delta = (($a - $b) / $b) * 100
        $improved = if ($m.higherBetter) { $delta -gt 0 } else { $delta -lt 0 }
        $color = if ([math]::Abs($delta) -lt 5) { 'DarkGray' }      # Messrauschen
                 elseif ($improved)            { 'Green' }
                 else                          { 'Red' }
        Write-Host ("  {0,-24} {1,12:N0} {2,12:N0} {3,9:+0.0;-0.0}%" -f $m.name, $b, $a, $delta) -ForegroundColor $color
    }
    Write-Host ''
    Write-Host '  Hinweis: Unterschiede unter 5% sind normales Messrauschen.' -ForegroundColor DarkGray
}

Export-ModuleMember -Function Invoke-Benchmark, Get-BenchmarkHistory, Compare-Benchmark
