# WinOptimizerNG

Modulares Windows-Tuning-Tool in PowerShell — ein Test-Projekt, inspiriert vom
[WINDOWS-OPTIMIZER-PROJECT](https://github.com/WINDOWS-OPTIMIZER-PROJECT/WINDOWS-OPTIMIZER)
(GPL-3.0), aber von Grund auf neu konzipiert.

## Warum eine Neuentwicklung?

Das Original ist ein monolithisches VBScript mit >900 fest verdrahteten
Registry-Änderungen, ohne Einzelauswahl und ohne Undo. Außerdem ist VBScript
von Microsoft deprecated und wird aus Windows entfernt. WinOptimizerNG behebt
diese Punkte:

| | Original (VBScript) | WinOptimizerNG |
|---|---|---|
| Sprache | VBScript (deprecated) | PowerShell 5.1+ (in Windows enthalten) |
| Tweaks | ~900, alles-oder-nichts | kuratiert, jeder einzeln an/aus |
| Undo | nur globales Registry-Backup | echtes Undo pro Tweak (Originalwerte in `state.json`) |
| Fehlerbehandlung | `On Error Resume Next` überall | Logging in `logs\`, Fehler sichtbar |
| Veraltete Tweaks | XP/IE-Ära enthalten | nur dokumentierte, moderne Tweaks mit `minBuild`-Prüfung |
| Sicherheits-Eingriffe | u.a. Ransomware-Schutz deaktiviert | keine Eingriffe in Defender/Firewall |
| Dry-Run | nein | `-DryRun`-Parameter |

## Verwendung

```powershell
powershell -ExecutionPolicy Bypass -File .\WinOptimizerNG.ps1
# oder erst nur anschauen, was passieren würde:
powershell -ExecutionPolicy Bypass -File .\WinOptimizerNG.ps1 -DryRun
```

Das Script fordert selbst Admin-Rechte an und bietet beim ersten Lauf einen
Systemwiederherstellungspunkt an. Im Menü schaltet die Nummer eines Tweaks
diesen an bzw. wieder aus; `i <Nr>` zeigt Details inkl. der betroffenen
Registry-Werte.

## Aufbau

```
WinOptimizerNG.ps1        Einstieg: Elevation, interaktives Menü
engine\TweakEngine.psm1   Engine: Status, Apply, Revert, Backup, Log
tweaks\tweaks.json        Tweak-Definitionen als reine Daten
state.json                (zur Laufzeit) Originalwerte für Undo
logs\                     (zur Laufzeit) Tages-Logdateien
```

Neue Tweaks werden **nur** in `tweaks.json` ergänzt — kein Code nötig.
Felder: `id`, `name`, `category`, `description`, `recommended`, optional
`minBuild` (Windows-Build-Nummer, z.B. 22000 = Windows 11) und `note`,
dazu `ops` mit den Registry-Operationen.

## Grundsätze

1. **Kein Tweak ohne Beleg** — jeder Eintrag beschreibt, was er wirklich tut.
2. **Alles reversibel** — vor der ersten Anwendung wird der Originalzustand gesichert.
3. **Keine Sicherheitsfunktionen antasten** — Defender, Firewall und UAC bleiben unberührt.
4. **Opt-in statt Rundumschlag** — nichts wird ohne explizite Auswahl geändert.

## Lizenz

GPL-3.0 (siehe [LICENSE](LICENSE)), als abgeleitetes/inspiriertes Werk des
WINDOWS-OPTIMIZER-PROJECT.

**Status:** Test-/Lernprojekt, keine Gewähr. Änderungen erfolgen auf eigene
Verantwortung — der Wiederherstellungspunkt beim ersten Start ist empfohlen.
