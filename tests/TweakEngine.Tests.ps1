# Pester-Tests fuer die TweakEngine (Pester 5+).
# Ausfuehren:  Invoke-Pester -Path .\tests
#
# Die Tests arbeiten gegen einen isolierten HKCU-Testschluessel
# (HKCU:\Software\WinOptimizerNG_Test) und lenken state.json/logs in %TEMP% um.
# Es werden KEINE echten System-Tweaks veraendert. Der Testschluessel wird nach
# jedem Test wieder entfernt. Kein Adminrecht noetig (nur HKCU).

BeforeAll {
    $enginePath = Join-Path (Split-Path $PSScriptRoot -Parent) 'engine\TweakEngine.psm1'
    Import-Module $enginePath -Force
}

AfterAll {
    Remove-Item 'HKCU:\Software\WinOptimizerNG_Test' -Recurse -Force -ErrorAction SilentlyContinue
}

Describe 'TweakEngine' {

    AfterEach {
        Remove-Item 'HKCU:\Software\WinOptimizerNG_Test' -Recurse -Force -ErrorAction SilentlyContinue
    }

    Context 'DWord-Vergleich (Regression: High-Bit-Werte wie 0xFFFFFFFF)' {

        It 'normalisiert Int32 -1 und uint32 4294967295 auf denselben Wert' {
            InModuleScope TweakEngine {
                (ConvertTo-UInt32 -1)         | Should -Be ([uint32]4294967295)
                (ConvertTo-UInt32 4294967295) | Should -Be ([uint32]4294967295)
                (ConvertTo-UInt32 0)          | Should -Be ([uint32]0)
            }
        }

        It 'erkennt einen High-Bit-DWord nach dem Anwenden als aktiv' {
            InModuleScope TweakEngine {
                $script:StateFile = Join-Path $env:TEMP ("wong-test-{0}.json" -f [guid]::NewGuid())
                $script:LogDir    = Join-Path $env:TEMP 'wong-test-logs'
                Remove-Item 'HKCU:\Software\WinOptimizerNG_Test' -Recurse -Force -ErrorAction SilentlyContinue

                $op = [pscustomobject]@{ hive = 'HKCU'; path = 'Software\WinOptimizerNG_Test'; name = 'HighBit'; type = 'DWord'; value = 4294967295 }
                $tweak = [pscustomobject]@{ id = 'test-highbit'; name = 'Test HighBit'; ops = @($op) }

                Test-TweakApplied $tweak | Should -BeFalse   # vor Anwendung
                Invoke-TweakApply $tweak
                Test-TweakApplied $tweak | Should -BeTrue    # Regression: frueher faelschlich $false

                Remove-Item $script:StateFile -Force -ErrorAction SilentlyContinue
            }
        }
    }

    Context 'Apply/Revert-Round-Trip' {

        It 'entfernt einen zuvor nicht vorhandenen Wert beim Revert' {
            InModuleScope TweakEngine {
                $script:StateFile = Join-Path $env:TEMP ("wong-test-{0}.json" -f [guid]::NewGuid())
                $script:LogDir    = Join-Path $env:TEMP 'wong-test-logs'
                Remove-Item 'HKCU:\Software\WinOptimizerNG_Test' -Recurse -Force -ErrorAction SilentlyContinue

                $op = [pscustomobject]@{ hive = 'HKCU'; path = 'Software\WinOptimizerNG_Test'; name = 'NewVal'; type = 'DWord'; value = 1 }
                $tweak = [pscustomobject]@{ id = 'test-newval'; name = 'Test NewVal'; ops = @($op) }

                Invoke-TweakApply $tweak
                (Get-RegCurrent $op).value | Should -Be 1
                Invoke-TweakRevert $tweak
                (Get-RegCurrent $op).valueExists | Should -BeFalse

                Remove-Item $script:StateFile -Force -ErrorAction SilentlyContinue
            }
        }

        It 'stellt einen vorher vorhandenen DWord-Wert wieder her' {
            InModuleScope TweakEngine {
                $script:StateFile = Join-Path $env:TEMP ("wong-test-{0}.json" -f [guid]::NewGuid())
                $script:LogDir    = Join-Path $env:TEMP 'wong-test-logs'
                Remove-Item 'HKCU:\Software\WinOptimizerNG_Test' -Recurse -Force -ErrorAction SilentlyContinue
                New-Item -Path 'HKCU:\Software\WinOptimizerNG_Test' -Force | Out-Null
                Set-ItemProperty -Path 'HKCU:\Software\WinOptimizerNG_Test' -Name 'Existing' -Value 5 -Type DWord

                $op = [pscustomobject]@{ hive = 'HKCU'; path = 'Software\WinOptimizerNG_Test'; name = 'Existing'; type = 'DWord'; value = 1 }
                $tweak = [pscustomobject]@{ id = 'test-existing'; name = 'Test Existing'; ops = @($op) }

                Invoke-TweakApply $tweak
                (Get-RegCurrent $op).value | Should -Be 1
                Invoke-TweakRevert $tweak
                (Get-RegCurrent $op).value | Should -Be 5

                Remove-Item $script:StateFile -Force -ErrorAction SilentlyContinue
            }
        }

        It 'stellt einen vorher vorhandenen String-Wert wieder her (MenuShowDelay-Fall)' {
            InModuleScope TweakEngine {
                $script:StateFile = Join-Path $env:TEMP ("wong-test-{0}.json" -f [guid]::NewGuid())
                $script:LogDir    = Join-Path $env:TEMP 'wong-test-logs'
                Remove-Item 'HKCU:\Software\WinOptimizerNG_Test' -Recurse -Force -ErrorAction SilentlyContinue
                New-Item -Path 'HKCU:\Software\WinOptimizerNG_Test' -Force | Out-Null
                Set-ItemProperty -Path 'HKCU:\Software\WinOptimizerNG_Test' -Name 'MenuDelay' -Value '400' -Type String

                $op = [pscustomobject]@{ hive = 'HKCU'; path = 'Software\WinOptimizerNG_Test'; name = 'MenuDelay'; type = 'String'; value = '150' }
                $tweak = [pscustomobject]@{ id = 'test-menudelay'; name = 'Test MenuDelay'; ops = @($op) }

                Invoke-TweakApply $tweak
                (Get-RegCurrent $op).value | Should -Be '150'
                Invoke-TweakRevert $tweak
                (Get-RegCurrent $op).value | Should -Be '400'

                Remove-Item $script:StateFile -Force -ErrorAction SilentlyContinue
            }
        }

        It 'loescht einen neu angelegten Schluessel beim Revert (deleteKeyOnRevert)' {
            InModuleScope TweakEngine {
                $script:StateFile = Join-Path $env:TEMP ("wong-test-{0}.json" -f [guid]::NewGuid())
                $script:LogDir    = Join-Path $env:TEMP 'wong-test-logs'
                Remove-Item 'HKCU:\Software\WinOptimizerNG_Test' -Recurse -Force -ErrorAction SilentlyContinue

                $op = [pscustomobject]@{ hive = 'HKCU'; path = 'Software\WinOptimizerNG_Test'; name = ''; type = 'String'; value = 'x'; deleteKeyOnRevert = $true }
                $tweak = [pscustomobject]@{ id = 'test-newkey'; name = 'Test NewKey'; ops = @($op) }

                Invoke-TweakApply $tweak
                Test-Path 'HKCU:\Software\WinOptimizerNG_Test' | Should -BeTrue
                Invoke-TweakRevert $tweak
                Test-Path 'HKCU:\Software\WinOptimizerNG_Test' | Should -BeFalse

                Remove-Item $script:StateFile -Force -ErrorAction SilentlyContinue
            }
        }

        It 'sichert den Originalwert nur beim ERSTEN Apply' {
            InModuleScope TweakEngine {
                $script:StateFile = Join-Path $env:TEMP ("wong-test-{0}.json" -f [guid]::NewGuid())
                $script:LogDir    = Join-Path $env:TEMP 'wong-test-logs'
                Remove-Item 'HKCU:\Software\WinOptimizerNG_Test' -Recurse -Force -ErrorAction SilentlyContinue
                New-Item -Path 'HKCU:\Software\WinOptimizerNG_Test' -Force | Out-Null
                Set-ItemProperty -Path 'HKCU:\Software\WinOptimizerNG_Test' -Name 'Once' -Value 5 -Type DWord

                $op = [pscustomobject]@{ hive = 'HKCU'; path = 'Software\WinOptimizerNG_Test'; name = 'Once'; type = 'DWord'; value = 1 }
                $tweak = [pscustomobject]@{ id = 'test-once'; name = 'Test Once'; ops = @($op) }

                Invoke-TweakApply $tweak                                 # Backup sichert Original 5
                Set-ItemProperty -Path 'HKCU:\Software\WinOptimizerNG_Test' -Name 'Once' -Value 9 -Type DWord
                Invoke-TweakApply $tweak                                 # darf Backup NICHT auf 9 ueberschreiben
                Invoke-TweakRevert $tweak
                (Get-RegCurrent $op).value | Should -Be 5                # nicht 9

                Remove-Item $script:StateFile -Force -ErrorAction SilentlyContinue
            }
        }
    }
}
