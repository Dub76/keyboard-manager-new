# Keyboard Manager V2 – Feature-Parität

Stand: 26. Juli 2026 · Referenz: Electron V1.3.2 · fachliche Restparität abgeschlossen

Statusdefinitionen:

- **Inventarisiert:** Verhalten und Daten wurden in V1 nachvollzogen.
- **Gerüst:** native Struktur oder Oberfläche existiert, aber noch ohne produktive Implementierung.
- **Dry-Run:** Quelle wird vollständig nur lesend geprüft und transformiert; noch kein persistierender Import.
- **Offen:** für eine Folgephase vorgesehen.
- **Nicht übernehmen:** bewusst entfallender technischer V1-Mechanismus; die Nutzerfunktion wird nativ ersetzt.

## App-Rahmen und Navigation

| V1-Funktion | V1-Verhalten | V2-Status | Zielphase / Abnahmekriterium |
| --- | --- | --- | --- |
| Hauptfenster | 1800 × 1200 Electron-Fenster | Phase 2 implementiert | großzügige Startgröße 1600 × 900, Mindestgröße 980 × 640, Light/Dark und responsiver Editor ohne seitlichen Überlauf |
| Erfassen / Übersicht / Galerie | linke App-Navigation | Phase 3 implementiert | native Sidebar, Editoren, Übersicht und adaptive Galerie |
| Inventartyp-Umschaltung | Boards, Keycaps, Artisans, Switches | Phase 2 implementiert | stabile Auswahl je Bereich |
| Hauptaktion „Neues Board“ | öffnet neuen Board-Entwurf | Phase 2 implementiert | Toolbar und `⌘N`, Fokus im Namensfeld |
| Deutsch / Englisch | Laufzeit-Übersetzung und Persistenz | Restparität implementiert + Tests | vollständiger String Catalog, Live-Umschaltung, SQLite-/V1-Metadatenübernahme und sprachkonsistente Berichte |
| Hell / Dunkel | eigener Theme-Schalter | Nicht übernehmen | Systemdarstellung plus optionale Systemeinstellung; kein Web-CSS-Theme |
| Version / Speicherstatus | Sidebar-/Kopfzeilenanzeige | Implementiert | Sidebar zeigt Version, Speicherzeitpunkt sowie Lade-, Speicher- und Backupfehler; „Über Keyboard Manager“ mit Lizenz, Quellcode und Datenort |
| Ungespeicherte Änderungen | Bestätigungsdialog beim Wechsel/Schließen | Phase 5 vollständig + UI-Test | sichtbarer Editor-Button „Verwerfen“, Navigation/Typwechsel und roter Fensterschalter schützen den Entwurf; Abbrechen und bestätigtes Verwerfen sind geprüft |
| Kontextmenü | Undo/Redo/Cut/Copy/Paste/Select All | Restparität implementiert + UI-Abnahme | app-weites Responder-Kontextmenü, native Textfeldmenüs und spezialisierte Tabellen-/Galerieaktionen einschließlich „Name kopieren“ |
| App-Icon | eigenes V1-Programmicon | Restparität implementiert + Buildprüfung | eigener macOS-Assetkatalog von 16 bis 1024 Pixel; Xcode erzeugt und installiert `AppIcon.icns` |
| App schließen auf macOS | Prozess bleibt nach letztem Fenster aktiv | Gerüst | normales macOS-Lebenszyklusverhalten |

## Boards

| V1-Funktion | V1-Verhalten | V2-Status | Zielphase / Abnahmekriterium |
| --- | --- | --- | --- |
| Anlegen/Bearbeiten/Löschen | Name Pflicht, Bestätigung beim Löschen | Phase 2 implementiert | vollständiger CRUD mit Fehlerzuständen |
| Felder | Hersteller, Format, Plate, PCB, Stabs, Keycaps, Switches, Bemerkung | Phase 2 implementiert | verlustfreie Erfassung aller Felder |
| Dynamische Bibliothekswerte | „+ Neu“ ergänzt Listen | Phase 2 implementiert | frei editierbare Auswahl, dedupliziert und persistent |
| Keycap-Verknüpfung | optionales Keycap-Set, Name wird gespiegelt | Phase 2 implementiert | eine kanonische Beziehung, konsistente Rückseite |
| Switch-Verknüpfungen | mehrere Sets plus Menge | Phase 2 implementiert | normalisierte Installationen, keine doppelte Wahrheit |
| Kurzvorschau | Badges, PCB/Plate, Fotozahl, Bemerkung | Phase 2 implementiert | live aktualisierte native Vorschau |
| Übersicht | KPI, Filter, Tabelle, Aktionen | Restparität implementiert + Tests | Volltextsuche, Hersteller-/Formatfilter, lokale Fotovorschau mit echtem Leerzustand, Keycaps, Switches samt Menge, stabile Sortierung und CRUD |
| Galerie | Karten mit Hauptfoto und Feldern | Phase 3 implementiert | adaptives natives Grid mit Hauptfoto, Metadaten und Trefferzahl |
| Spotlight | Detail, Navigation, Bearbeiten/Löschen | Phase 3 implementiert | Großansicht mit Pfeilnavigation, Escape, Inspector und stabiler Auswahl |

## Keycap-Sets

| V1-Funktion | V1-Verhalten | V2-Status | Zielphase / Abnahmekriterium |
| --- | --- | --- | --- |
| CRUD | eigener Editor und Übersicht | Phase 2 implementiert | vollständiger nativer CRUD |
| Felder | Name, Hersteller, Profil, Material, Status | Phase 2 implementiert | Pflicht-/Wertevalidierung |
| Kits | eine Zeile je Kit | Phase 2 implementiert | geordnete, deduplizierte Liste |
| Quelle | Shop und HTTPS-Link | Phase 3 implementiert | validierter HTTPS-Link und erneute Prüfung vor dem Öffnen im Detailbereich |
| Montage | optional genau ein Board | Phase 2 implementiert | Beziehung synchron zu Board |
| Notizen | Freitext | Phase 2 implementiert | nativer TextEditor |
| Lokale Fotos | mehrere, Hauptfoto | Phase 3 implementiert | Foto-Service plus persistenter 640-Pixel-Thumbnail-Cache |
| Externe Bilder | Cover/externe URLs aus Importen | Restparität implementiert + Tests | keine Hintergrundabrufe; erst nach Host-Anzeige und Bestätigung per HTTPS laden, mit MIME-/ImageIO-/Größenprüfung lokal übernehmen |
| Trello-Provenienz | card/list-Felder im Datenbestand | Modell | als Migrationsmetadaten erhalten |
| Übersicht/Galerie/Spotlight | Filter, Tabelle, Karten, Detail | Restparität implementiert + Tests | kombinierbare Filter, lokale Fotovorschau, Kits und montiertes Board in der Tabelle, Grid und Großansicht |

## Artisans

| V1-Funktion | V1-Verhalten | V2-Status | Zielphase / Abnahmekriterium |
| --- | --- | --- | --- |
| CRUD | eigener Editor und Übersicht | Phase 2 implementiert | vollständiger nativer CRUD |
| Felder | Name, Hersteller, Profil, Material, Status | Phase 2 implementiert | verlustfreie Migration und Bearbeitung |
| Tags | eine Zeile je Tag | Phase 2 implementiert | geordnete, deduplizierte Tags |
| Quelle / Montage / Notizen | analog Keycaps | Phase 2 implementiert | gleiche native Qualität |
| Fotos / Hauptfoto | lokal plus externe Importbilder | Restparität implementiert + Tests | lokale Fotos und Cache; externe Adressen bleiben Metadaten, bis der bestätigte sichere Download sie in lokale Fotos umwandelt |
| Übersicht/Galerie/Spotlight | Filter, Tabelle, Karten, Detail | Restparität implementiert + Tests | kombinierbare Filter, lokale Fotovorschau, Tags und montiertes Board in der Tabelle, Grid und Großansicht |

## Switch-Sets

| V1-Funktion | V1-Verhalten | V2-Status | Zielphase / Abnahmekriterium |
| --- | --- | --- | --- |
| CRUD | eigener Editor und Übersicht | Phase 2 implementiert | vollständiger nativer CRUD |
| Technische Felder | Typ, Housing, Stem, Feder, Wege, Kräfte | Phase 2 implementiert | alle Werte verlustfrei und editierbar |
| Pins | `3 PIN`, `5 PIN`, `HE` | Phase 2 implementiert | geschlossener Swift-Typ und kompatible V1-Codierung |
| Optionen | LED-Diffusor, Factory Lubed | Phase 2 implementiert | native Toggles |
| Gesamtbestand | nicht negative Menge | Phase 2 implementiert | Validierung und formatierte Anzeige |
| Board-Installationen | mehrere Boards, Menge je Board | Phase 2 implementiert | kanonische n:m-Relation |
| Verfügbar | Gesamt minus verbaut | Phase 2 implementiert + Test | nie negativ, konsistent nach jeder Änderung |
| Import-Provenienz | Quelltext, Zeile, Schlüssel, Zuordnungen, Warnungen | Modell | im Migrationsbericht und Detail sichtbar |
| Importwarnungen löschen | Aktion im Spotlight | Implementiert + Test | „Hinweise entfernen …“ im Spotlight mit Bestätigung; Wortlaut und Datum werden in den Notizen protokolliert |
| Fotos / Hauptfoto | lokale Bilder | Phase 2 implementiert | Foto-Service |
| Übersicht / Spotlight | Filter, Tabelle und Detail | Restparität implementiert + Tests | Suche, lokale Fotovorschau mit Leerzustand, Typ/Kraft/Pins, Bestand/Verbaut/Verfügbar, Boards samt Menge, Mengensortierung und Aktionen |
| Galerie | in V1 nicht vorhanden | — | Produktentscheidung in späterer Phase |

## Fotos und Medien

| V1-Funktion | V1-Verhalten | V2-Status | Zielphase / Abnahmekriterium |
| --- | --- | --- | --- |
| Besitzer | Board, Keycap, Artisan oder Switch | Dry-Run + Test | exakt ein typisierter Besitzer |
| Formate | JPEG, PNG, WebP, GIF; realer Export enthält falsch deklarierte HEIC-Daten | Dry-Run + Modell | ImageIO-Typ prüfen; HEIC verlustfrei als HEIC normalisieren |
| Größenlimit | 30 MiB je Datei | Dry-Run + Test | vor Prüfung und jeder späteren Kopie erzwingen |
| Skalierung | max. 1920 × 1080 | Phase 2 implementiert | ImageIO-basiert; Orientierungstransformation bei Skalierung |
| Verwalteter Ordner | Dateien neben SQLite | Phase 1B implementiert | `Current`, Staging, Backup und Rollback |
| Hauptfoto | ID muss zur Fotoliste gehören | Phase 2 implementiert + Test | Editor- und Repository-Invariante |
| Großansicht | Lightbox, Pfeile, Escape | Phase 3 implementiert | native Spotlight-Ansicht mit Vollbildfoto, Thumbnail-Leiste, Pfeilen und Escape |
| Externe Importbilder | V1 lädt Cover/URLs automatisch, wenn lokale Fotos fehlen | Restparität implementiert + Tests | Galerie/Spotlight kennzeichnen sie ohne Netzabruf; Editor zeigt Hosts und übernimmt sie nur bestätigt, HTTPS-only und geprüft in den lokalen Fotobestand |
| Verwaiste Fotos | beim Start gelöscht | Inventarisiert | erst nach Repository-Reparaturbericht löschen |

## Suche, Filter und Darstellung

| V1-Funktion | V1-Verhalten | V2-Status | Zielphase / Abnahmekriterium |
| --- | --- | --- | --- |
| Board-Suche | Name und Textfelder | Phase 3 implementiert + Test | diakritik-/großkleinschreibungsunabhängig |
| Board-Filter | Hersteller, Format | Phase 3 implementiert + Test | kombinierbar, zurücksetzbar |
| Keycap-/Artisan-Filter | Hersteller, Profil, Status | Phase 3 implementiert | kombinierbar, zurücksetzbar |
| Switch-Filter | Typ, Operating Force, Pins | Phase 3 implementiert + Test | `HE` vollständig berücksichtigt |
| Sortierungen | typabhängige Name-/Feld-/Datum-/Mengenoptionen | Restparität implementiert + Test | stabile Sortierung mit lokalem Collator; konkrete Bezeichnung „Format“, „Profil“ oder „Typ“ statt internem Sammelbegriff |
| Trefferzahlen | je Bereich | Phase 3 implementiert | reaktiv und korrekt bei Filtern |
| Rückkehr nach Bearbeiten | vorherige Tabellenposition/Fokus | Restparität implementiert + Tests | typbezogene Filter/Sortierung/Auswahl bleiben erhalten; Pixel-Scrollposition und Tastaturfokus werden nach Speichern oder Verwerfen wiederhergestellt |
| Erfassen nach Bearbeiten | normaler Aufruf beginnt eine Neuanlage | Restparität implementiert + Test | der Sidebar-Aufruf „Erfassen“ verwirft keine Daten, übernimmt aber niemals den zuletzt bearbeiteten Eintrag als Entwurf |

## Backup, Migration und Berichte

| V1-Funktion | V1-Verhalten | V2-Status | Zielphase / Abnahmekriterium |
| --- | --- | --- | --- |
| ZIP-Backup Export | Schema 6, Manifest + Fotos | Phase 4 implementiert + Rundlauftest | reproduzierbarer Export, atomare Zieldatei, Rückleseprüfung; HEIC nur in Exportkopie als JPEG |
| ZIP-Backup Import | Schema 3–6, validiert, ersetzt nach Bestätigung | Phase 4 vollständig | gemeinsamer gehärteter Reader, historische Schemata sichtbar normalisiert |
| JSON-Backup Import | Legacy-Datei | Phase 4 vollständig | eingebettete Fotos im V2-Staging trennen, Quelle unverändert lassen, danach gemeinsamer Commit-/Rollbackpfad |
| IndexedDB/localStorage Migration | automatisch wenn SQLite leer | Inventarisiert | nur für direkte Altinstallationen; kein Web-Speicher in V2 |
| Direkte SQLite-Migration | V1-intern nicht nötig | Restparität implementiert + Integrationstests | installierte V1 automatisch finden oder Ordner manuell wählen; DB/WAL/SHM nur in V2-Staging kopieren, dort per SQLite Backup API fixieren, Snapshot erneut validieren und rollback-sicher aktivieren |
| PDF-Bestandsbericht | A4 quer, Kopf/Fuß, optional Bilder | Phase 4 implementiert + Renderprüfung | natives Deckblatt, Bereichsseiten, wiederholte Köpfe, Seitenzahlen und maximal 200 lokale Hauptbilder |
| XLSX-Bestandsliste | Übersicht + Blatt je Typ | Phase 4 implementiert + Import-/Renderprüfung | native OOXML-Arbeitsmappe mit V1-Spalten, Freeze-Panes, Autofilter, typisierten Werten und HTTPS-Links |
| Filter im Bericht | aktueller Bereich oder alle Typen | Phase 4 implementiert + Test | Filter und Sortierung werden je Typ behalten; Filter lassen sich für den Export vollständig deaktivieren |

## Updates, Sicherheit und Distribution

| V1-Funktion | V1-Verhalten | V2-Status | Zielphase / Abnahmekriterium |
| --- | --- | --- | --- |
| Updateprüfung | GitHub latest release, 24-h Cache | Implementiert + Test | automatische Prüfung höchstens einmal täglich, manuelle Prüfung jederzeit; Fehlschläge zählen nicht |
| Download | nur vertrauenswürdige GitHub-Release-URL | Inventarisiert | Allowlist bleibt verpflichtend |
| Externe Links | ausschließlich HTTPS | Phase 3 implementiert | `NSWorkspace` ausschließlich nach erneuter URL-Validierung |
| Sender-/Navigation-Härtung | Electron IPC- und Navigation-Schutz | Nicht übernehmen | native App besitzt keine Renderer-/IPC-Angriffsfläche |
| Developer-ID / Notarisierung | V1 Releaseprozess | Offen | eigene V2-Identität, später separat beauftragt |
| GitHub / Release | öffentliches V1-Repo | Nicht Teil | ausdrücklich keine Veröffentlichung in Phase 0 |

## Phase-0-Abnahme

- [x] V1-Quellcode, Screenshots, Persistenz, Backup, Export, Updatepfad und Tests inventarisiert
- [x] Zielarchitektur und normalisiertes Datenmodell festgelegt
- [x] Migrationsstrategie dokumentiert
- [x] natives Xcode-Projekt und SwiftUI-Grundstruktur angelegt
- [x] lokale Git-Historie initialisiert
- [x] Build und Unit-Tests erfolgreich; lokaler Debug-Bundle unter `dist/Keyboard Manager.app`
- [ ] GitHub/Release – absichtlich nicht durchgeführt

## Phase-1A-Abnahme

- [x] Schema-6-ZIP nur lesend öffnen; Größen-, Pfad- und CRC-Grenzen erzwingen
- [x] Manifest vollständig in V2-Modelle transformieren und Beziehungen validieren
- [x] alle referenzierten Bilder über ImageIO dekodieren und tatsächlichen MIME-Typ bestimmen
- [x] nativer Dateidialog, Fortschritt, Zähler, Warnungen und Fehlerzustände
- [x] synthetische Tests für gültiges ZIP, Path Traversal und nicht unterstütztes Schema
- [x] privater V1.3.2-Export vollständig geprüft: 0 blockierende Fehler
- [x] persistierender Import/Commit – umgesetzt in Phase 1B
- [ ] GitHub/Release – nicht beauftragt

## Phase-1B-Abnahme

- [x] SQLite-Repository mit Transaktion, WAL, vollständiger Synchronisation und Integritätsprüfung
- [x] Quell-ZIP vor dem Schreiben in eindeutiges Staging kopiert und erneut per SHA-256 validiert
- [x] Fotos ausschließlich aus der geprüften Staging-Kopie extrahiert und per CRC/Größe verifiziert
- [x] SQLite-Snapshot geschrieben, zurückgelesen und mit dem Dry-Run verglichen
- [x] explizite Bestätigung vor dem produktiven Import
- [x] vorhandener V2-`Current`-Bestand wird vor dem Ersetzen gesichert
- [x] Fehlerinjektion nach dem Backup-Schritt stellt den vorherigen Bestand vollständig wieder her
- [x] lokaler JSON-Abschlussbericht im aktiven Bestand und im Berichtarchiv
- [x] privater V1.3.2-Export vollständig in ein isoliertes V2-Layout committed
- [x] ZIP-Schema 3–5 mit Besitzer-Fallback und denselben Sicherheitsgrenzen wie Schema 6
- [x] Legacy-JSON mit eingebetteten Fotos nur lesend kanonisiert, erneut geprüft und rollback-sicher committed
- [x] direkte V1-SQLite-Quelle manuell auswählen, ausschließlich lesend und WAL-konsistent in V2-Staging überführen
- [ ] GitHub/Release – nicht beauftragt

## Phase-2-Abnahme

- [x] alle vier Inventartypen nativ anlegen, bearbeiten, validieren und bestätigt löschen
- [x] Editor-Entwürfe getrennt vom persistenten Snapshot; Speichern ausschließlich über das Repository
- [x] Keycap-/Board-Rückseiten und Switch-Installationen zentral und konsistent aktualisiert
- [x] nicht negative Mengen und Gesamtbestand gegen Installationssummen validiert
- [x] V1-Bibliothekswerte auswählbar; neue freie Werte dedupliziert im Snapshot gespeichert
- [x] lokale Bilder geprüft, bei Bedarf skaliert und atomar in den verwalteten Fotoordner übernommen
- [x] Hauptfoto-, Foto-Besitzer- und HTTPS-Invarianten vor dem Commit geprüft
- [x] native Tabelle mit Suche, Herstellerfilter, Sortierung, Doppelklick, Kontextmenü und CRUD-Aktionen
- [x] Live-Vorschau, sichtbarer Speicherzustand, `⌘S`, Undo und Verwerfbestätigung beim Navigieren
- [x] Unit-/Integrationstests für Beziehungen, Mengen, Löschen, Bibliothekswerte und Fotoablage
- [x] Thumbnail-Cache und Galerie/Spotlight – umgesetzt in Phase 3
- [x] Fenster-Schließen-Warnung schützt geänderte Editoren
- [ ] GitHub/Release – nicht beauftragt

## Phase-3-Abnahme

- [x] adaptive Galerie für Boards, Keycap-Sets und Artisans mit lokalen Hauptfotos
- [x] Spotlight-Großansicht für alle vier Typen mit Pfeiltasten, Escape, Thumbnail-Leiste und Detailmetadaten
- [x] Bearbeiten, bestätigt Löschen und validiertes Öffnen von HTTPS-Quellen aus Spotlight
- [x] kombinierbare, zurücksetzbare typabhängige Filter in Übersicht und Galerie
- [x] diakritik-, breiten- und großkleinschreibungsunabhängige Suche
- [x] stabile typabhängige Sortierung einschließlich Switch-Menge
- [x] persistenter ImageIO-Thumbnail-Cache ohne Änderung der Originalfotos
- [x] Tests für Filterkombinationen, HE/Pin-Regeln, Mengensortierung und Cache-Wiederverwendung
- [x] externe Importbilder bleiben bis zur expliziten, hosttransparenten Download-Bestätigung Metadaten
- [ ] GitHub/Release – nicht beauftragt

## Phase-4-Abnahme

- [x] Schema-6-ZIP mit Manifest, allen Inventartypen, Beziehungen und lokalen Fotos exportieren
- [x] V1-Limits, ID-/Dateinamensicherheit und vollständige Rückleseprüfung vor der Zielaktivierung
- [x] identischer Snapshot und Exportzeitpunkt erzeugen ein byteidentisches Archiv
- [x] verwaltete Originalfotos bleiben beim Export unverändert
- [x] HEIC wird nur für die V1-kompatible Exportkopie als JPEG kodiert und sichtbar gezählt
- [x] nativer Speichern-Dialog sowie sichtbare Arbeits-, Erfolgs- und Fehlerzustände
- [x] ZIP-Schema 3–5 und Legacy-JSON als weitere einmalige Importquellen
- [x] PDF-Bestandsbericht mit dokumentierter Bereichs-/Filtersemantik und visueller Prüfung aller Seiten
- [x] XLSX-Bestandsliste mit Übersicht, typbezogenen Blättern und visueller Prüfung aller Blätter
- [ ] GitHub/Release – nicht beauftragt

## Phase-5-Abnahme

- [x] Warnung beim roten Fensterschalter schützt einen geänderten Editor
- [x] sauberer Editor schließt ohne unnötigen Dialog
- [x] Abbrechen erhält den Entwurf; bestätigtes Verwerfen schließt das Fenster
- [x] UI-Tests laufen mit isoliertem V2-Datenbereich und lokal signiertem Test-Runner
- [x] Navigationsreihenfolge **Übersicht → Galerie → Erfassen** im laufenden App-Prozess geprüft
- [x] Accessibility-Audit der Übersicht; technische SF-Symbolnamen aus der Sprachausgabe entfernt
- [x] Performance-Benchmark für Suche und Sortierung auf 5.000 synthetischen Boards
- [x] 43 Unit-/Integrations-/Performance-Tests und 2 UI-Tests erfolgreich
- [ ] GitHub/Release – nicht beauftragt

## Fachliche Restparität – laufend

- [x] direkter V1-SQLite-Reader mit echter synthetischer WAL-Datenbank
- [x] Originaldatenbank, WAL, SHM und Fotodatei bleiben bei Prüflauf und Commit bytegenau unverändert
- [x] Quellhash, normalisierter Snapshot und Foto-Stagingplan werden vor dem Commit erneut verglichen
- [x] geänderte V1-Quelle blockiert die Aktivierung; vorhandener Commit-/Backup-/Rollbackpfad bleibt verbindlich
- [x] automatische Dateisystem-Discovery für die bekannten V1-App-Support-Namen; Schema nur an einer V2-eigenen DB-/WAL-/SHM-Kopie prüfen
- [x] laufende V1 anhand der Bundle-ID erkennen; direkte Prüfung und Commit bis zum Beenden blockieren
- [x] externe Importbilder in Galerie/Spotlight ohne Hintergrundabruf sichtbar kennzeichnen
- [x] bestätigter HTTPS-Download ohne Cookies/persistenten Cache; Weiterleitungen, MIME, ImageIO und 30-MiB-Grenze prüfen
- [x] Download zunächst nur als ungespeicherte lokale Fotos vorbereiten; Abbruch lässt Metadaten und Bestand unverändert
- [x] 65 Unit-/Integrations-/Performance-Tests erfolgreich
- [x] normaler Aufruf von „Erfassen“ startet nach jeder vorherigen Bearbeitung für alle vier Inventartypen mit einem leeren Entwurf
- [x] vollständige Deutsch-/Englisch-Lokalisierung einschließlich Fachfehlern, Migration und Berichten
- [x] Tabellenposition, typbezogene Filter/Sortierung, Auswahl und Fokus nach dem Bearbeiten wiederherstellen
- [x] V1-Übersichtsspalten für Boards, Keycaps, Artisans und Switches einschließlich normalisierter Beziehungen und lokaler Fotovorschau wiederhergestellt
- [x] nativer Foto-Leerzustand für Einträge ohne hochgeladenes Bild; kein künstliches Ersatzbild im Datenbestand erforderlich
- [x] künstliche 350-Punkte-Leerfläche im Übersichtskopf entfernt; Tabelle schließt direkt an Filter und Kennzahlen an
- [x] app-weites natives Bearbeiten-Kontextmenü sowie „Name kopieren“ in Tabellen und Galerie
- [x] konkreter Sortierbegriff je Inventartyp statt „Fachfeld“
- [x] vollständiger macOS-AppIcon-Assetkatalog gebaut und im lokalen Bundle geprüft
- [x] selten benötigte Sidebar-Gruppe „Daten“ als native, persistent aufklappbare Section; bei Erstnutzung geschlossen und bei gezielter Migration automatisch geöffnet
- [x] Großbildansicht nutzt die Pfeiltasten zum Wechseln lokaler Fotos, ohne den zugrunde liegenden Spotlight-Eintrag zu wechseln
- [x] 66 Unit-/Integrations-/Performance-Tests erfolgreich
- [x] 4 UI-Tests als Gesamtsatz auf entsperrter macOS-Sitzung erneut ausgeführt; alle Szenarien grün
- [ ] GitHub/Release – nicht beauftragt
