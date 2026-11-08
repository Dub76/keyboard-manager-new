# Keyboard Manager

Keyboard Manager ist eine native macOS-App zum Erfassen, Verwalten und Sichern mechanischer Tastatur-Sammlungen. Sie unterstützt Boards, Keycap-Sets, Artisans und Switch-Sets, lokale Fotos, Galerie und Detailansicht, PDF-/XLSX-Berichte sowie eine nicht-destruktive Übernahme bestehender Keyboard-Manager-V1-Daten.

Die frühere Electron-App dient ausschließlich als unveränderliche Migrationsreferenz. Diese App verwendet einen eigenen Quellcode und einen eigenen Nutzerdatenbereich.

## Lokal bauen

```bash
xcodebuild -project KeyboardManager.xcodeproj -scheme KeyboardManager -configuration Debug test
./script/build_and_run.sh --build
```

Der lokale Debug-Build liegt danach unter `dist/Keyboard Manager.app`.

Für Build und Start:

```bash
./script/build_and_run.sh
```

## Datenschutz

Sammlung und Fotos bleiben lokal. Beim Fotoimport und in Backups entfernt die App GPS-Standortdaten aus den Bildern. Eine externe Bildadresse wird nur nach sichtbarer Bestätigung und ausschließlich per HTTPS einmalig geladen. Details: [PRIVACY.md](PRIVACY.md).

## Release

**Releases dieses Forks** (`Dub76/keyboard-manager-new`) sind reine Apple-Silicon-Builds (`Keyboard-Manager-X.Y.Z-arm64.dmg`), ab macOS 14, nur ad hoc signiert und nicht von Apple notarisiert. macOS blockiert sie deshalb beim ersten Start; öffnen lassen sie sich über Systemeinstellungen → Datenschutz & Sicherheit → „Trotzdem öffnen“. Die App heißt dort „Keyboard Manager V2.app“, damit eine installierte V1 nicht überschrieben wird.

Der folgende Prozess beschreibt die signierten Releases des Originalprojekts:

Der auslieferbare Build ist ein Developer-ID-signiertes und von Apple notarisiertes universelles DMG. Anleitung, Voraussetzungen und GitHub-CI-Konfiguration: [RELEASE.md](RELEASE.md).

Die App prüft beim Start höchstens einmal täglich das neueste stabile GitHub-Release. Wenn eine neuere Version verfügbar ist, kann der Nutzer das DMG laden; vor dem Öffnen wird es gegen die mitveröffentlichte SHA-256-Datei geprüft. Diese Prüfsumme erkennt beschädigte oder unvollständige Downloads. Weil sie aus demselben Release stammt, belegt sie nicht die Herkunft.

## Dokumentation

- `PROJECT_SUMMARY.md`: V1-Inventur, Zielarchitektur und Datenmodell
- `documentation/Keyboard_Manager_V2_Fachliche_Beschreibung.md`: bebilderte fachliche Produktbeschreibung
- `FEATURE_PARITY.md`: vollständige Funktions- und Umsetzungs-Matrix
- `MIGRATION.md`: nicht destruktive V1→V2-Migrationsstrategie
- `RELEASE.md`: Release- und Notarisierungsprozess

## Lizenz

Ab Version 1.1.1 steht dieses Projekt unter [GNU GPL Version 3 oder später](LICENSE) (`GPL-3.0-or-later`). Frühere Releases behalten ihre MIT-Lizenz. Details und Hinweise zu zuvor MIT-lizenzierten Anteilen: [LICENSING.md](LICENSING.md). Hinweise zu ZIPFoundation: [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md). Der vollständige Quellcode jedes Releases ist über das gleichnamige Git-Tag verfügbar.
