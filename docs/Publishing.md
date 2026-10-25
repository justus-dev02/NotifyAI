# NotifyAI veröffentlichen

NotifyAI wird auf zwei Wegen verteilt:

| Plattform | Weg | Werkzeug |
|---|---|---|
| iPhone, iPad | App Store | `scripts/release-ios.sh` → App Store Connect → Prüfung durch Apple |
| Mac | Download von der Website, Updates über Sparkle | `scripts/release.sh` → notarisiertes DMG im GitHub-Release, Website unter `website/` |

Die Mac-App ist nicht im Mac App Store. Sie wird mit einer **Developer ID** signiert und von Apple
**notarisiert**. Dadurch öffnet sie sich ohne Gatekeeper-Warnung, und macOS behält die Mikrofon- und
Systemaudio-Freigaben über Updates hinweg.

```
                       ┌─▶ NotifyAI-x.y.z.dmg + NotifyAI.dmg ─▶ Website-Button „Für Mac laden“
scripts/release.sh ────┤
                       └─▶ NotifyAI-x.y.z.zip + appcast.xml ──▶ Sparkle-Updates in installierten Apps

scripts/release-ios.sh ──▶ App Store Connect ──▶ TestFlight ──▶ App-Prüfung ──▶ App Store
```

---

## 1. Einmalige Einrichtung

### 1.1 Apple-Konto

- [ ] **Xcode → Einstellungen → Accounts:** Apple-ID des Developer-Accounts hinzufügen, Team
      `36B9A7K3RP` muss erscheinen.
- [ ] **Developer-ID-Zertifikat:** dort auf *Manage Certificates … → + → Developer ID Application*.
      Nur der Account Holder darf das. Das Zertifikat samt privatem Schlüssel zusätzlich sichern
      (Schlüsselbundverwaltung → Rechtsklick → Exportieren als `.p12`, Passwort setzen, im
      Passwortmanager ablegen).
- [ ] **Notarisierung:** auf [account.apple.com](https://account.apple.com) → *Anmelden und Sicherheit →
      App-spezifische Passwörter* ein Passwort „notarytool“ anlegen, dann:
      ```sh
      xcrun notarytool store-credentials NotifyAI-Notary --apple-id <deine Apple-ID> --team-id 36B9A7K3RP
      ```
      Das Passwort landet im Schlüsselbund. `release.sh` nutzt das Profil `NotifyAI-Notary`.
- [ ] **App Store Connect → Business:** die Vereinbarungen akzeptieren. Für eine kostenlose App
      reicht die Standardvereinbarung. Steuer- und Bankdaten brauchst du erst für kostenpflichtige
      Apps oder In-App-Käufe.
- [ ] **EU-Händlerstatus (Digital Services Act):** in App Store Connect unter *Business* angeben.
      Ohne diese Angabe erscheint die App in der EU nicht. Als **Händler** werden Adresse, Telefon und
      E-Mail im App Store öffentlich angezeigt. Wer die App kostenlos und ohne Gewinnabsicht anbietet,
      kann **kein Händler** angeben. Im Zweifel rechtlich beraten lassen.

### 1.2 Sparkle-Schlüssel (Mac-Updates)

Siehe [CI.md, Abschnitt 2.1](CI.md#21-einmalig-schlüssel-erzeugen). Ohne `SUPublicEDKey` bricht
`release.sh` ab.

### 1.3 App-Eintrag in App Store Connect

[appstoreconnect.apple.com](https://appstoreconnect.apple.com) → *Apps → + → Neue App*:

| Feld | Wert |
|---|---|
| Plattform | iOS (iPadOS ist darin enthalten) |
| Name | `NotifyAI`. Der Name muss im ganzen App Store frei sein. Ist er belegt, z. B. „NotifyAI – Meeting-Notizen“. |
| Primäre Sprache | English (U.S.) |
| Bundle-ID | `com.justus.NotifyAI`. Erscheint, nachdem Xcode einmal signiert hat. Sonst unter developer.apple.com → Identifiers anlegen. |
| SKU | `notifyai` (nur intern sichtbar) |

### 1.4 Website

- [ ] In `website/impressum.html` und `website/datenschutz.html` alle Stellen mit **BITTE AUSFÜLLEN**
      ersetzen (Name, ladungsfähige Anschrift, E-Mail), ebenso die E-Mail in `website/index.html`.
      Das Impressum ist in Deutschland Pflicht, die Datenschutzerklärung verlangt Apple.
- [ ] GitHub → *Settings → Pages → Source: GitHub Actions*. Beim nächsten Push auf `main`, der
      `website/` ändert, veröffentlicht `.github/workflows/pages.yml` die Seite unter
      **https://justus-dev02.github.io/NotifyAI/**. Von Hand: *Actions → Website → Run workflow*.
- [ ] Optional eine eigene Domain (z. B. `notifyai.app`): unter *Settings → Pages → Custom domain*
      eintragen und beim Domain-Anbieter einen CNAME auf `justus-dev02.github.io` setzen.

Solange noch Platzhalter in `website/` stehen, bricht der Website-Workflow bewusst ab. Ein
Impressum ohne Anschrift soll nicht online gehen.

Der Download-Button verlinkt `…/releases/latest/download/NotifyAI.dmg`. Er funktioniert ab dem
ersten Release mit `release.sh`.

### 1.5 Releases über GitHub Actions

*Actions → Release → Run workflow* läuft auf deinem Mac (self-hosted Runner). Der Ablauf:

1. **Voraussetzungen prüfen** (`release.sh --check`): sauberer Stand, Release-Notes,
   `SUPublicEDKey`, Developer-ID-Zertifikat, Notarisierungs-Zugang. Dauert Sekunden.
2. Komplette CI (`scripts/ci.sh`).
3. macOS: bauen, notarisieren, GitHub-Release, `appcast.xml`.
4. iOS: Upload zu App Store Connect.

Benötigte Secrets (*Settings → Secrets and variables → Actions*):

| Secret | Pflicht | Inhalt |
|---|---|---|
| `SPARKLE_ED_PRIVATE_KEY` | für macOS | privater Sparkle-Schlüssel (`generate_keys -x`) |
| `ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_PRIVATE_KEY` | optional | App-Store-Connect-API-Schlüssel (Rolle Admin, Inhalt der `.p8`). Ohne sie nutzt der Runner Zertifikat, Notarisierungs-Profil und Xcode-Account aus deinem Schlüsselbund. |

Das erste Release einmal **lokal im Terminal** starten (`scripts/release.sh 1.0.0`, ohne `--publish`)
und die Schlüsselbund-Abfrage von `codesign` mit **Immer erlauben** bestätigen. Danach klappt es auch
über den Runner (siehe [CI.md](CI.md#22-ein-release-veröffentlichen)).

### 1.6 Prüfen vor der ersten Einreichung

- [ ] App auf einem **echten iPhone** über TestFlight testen: Aufnahme im Hintergrund, Live Activity,
      Modell-Download, App-Sperre, Export, Widgets.
- [ ] Auf einem Gerät **ohne Apple Intelligence** testen. Die Prüfer nutzen oft solche Geräte. Die
      einfache Zusammenfassung muss funktionieren und verständlich gekennzeichnet sein.
- [ ] Das notarisierte DMG auf einem **anderen Mac** oder in einem neuen Benutzerkonto öffnen:
      Es darf keine Gatekeeper-Warnung erscheinen. Danach ein Update über Sparkle testen
      (zweites Release, z. B. 1.0.1).
- [ ] Keine Platzhalter, „Beta“-Hinweise oder Testdaten in der App.

---

## 2. Texte für App Store Connect

Primäre Sprache des Eintrags: **English (U.S.)**. Grenzen: Untertitel 30 Zeichen, Werbetext 170,
Schlüsselwörter 100, Beschreibung 4000. Die Texte können ohne neuen Build geändert werden, der
Werbetext sogar ohne neue Prüfung.

**Name**

> NotifyAI

**Subtitle** (29 Zeichen)

> Record, transcribe, summarize

**Promotional Text** (148 Zeichen)

> Record meetings, lectures and interviews, read along live and get summaries with Apple Intelligence – entirely on your device. No account, no cloud.

**Short description** (für Portfolio, Website, Social Media; kein Feld in App Store Connect)

> NotifyAI records conversations and meetings, transcribes them live and turns them into summaries with key points, decisions and tasks – privately, on your iPhone, iPad and Mac.

**Description**

> NotifyAI turns conversations, meetings, lectures and interviews into searchable notes. Record,
> read along as the transcript appears, and get a summary with key points, decisions and tasks.
> Everything happens on your iPhone or iPad – your recordings never leave the device.
>
> RECORD AND READ ALONG
> • Live transcript while you record
> • Mark important moments with a single tap
> • Keeps recording in the background, with Live Activity and Dynamic Island
> • Three speech engines: Apple Speech, Whisper and Parakeet
>
> SUMMARIES THAT POINT TO THE SOURCE
> • Overview, key points, tasks, decisions and open questions with Apple Intelligence
> • Tap any point to jump to the moment it was said
> • Custom templates with your own sections and instructions
> • Long recordings of several hours, split into chapters
>
> ORGANIZE AND FIND
> • Detects and names speakers, and recognizes voices in later recordings
> • Ask questions across all your notes – answers cite their sources
> • All open tasks in one list, sorted by due date
> • Labels and related notes
>
> SHARE
> • Export as Markdown, PDF, Word and subtitles, optionally anonymized
> • Obsidian, Notion and webhooks for Zapier, Make or n8n
>
> PRIVATE BY DESIGN
> No account, no cloud, no ads, no tracking. An optional app lock with Face ID keeps your notes
> private.
>
> Summaries with Apple Intelligence require a device that supports Apple Intelligence. Without
> it, NotifyAI creates a simpler, clearly labelled summary.

**Keywords** (97 Zeichen; keine fremden Marken wie „Whisper“ oder „Zoom“, das lehnt Apple ab;
Wörter aus Name und Untertitel nicht wiederholen)

> transcribe,transcription,meeting,notes,minutes,dictation,lecture,interview,summary,recorder,voice

**What’s New** (Version 1.0.0)

> The first release of NotifyAI. Record, transcribe and summarize – privately, on your device.

**Deutsche Lokalisierung (optional):** In App Store Connect unter *Lokalisierungen → Deutsch*
hinzufügen, sonst sehen deutsche Nutzer den englischen Eintrag. Die App selbst ist bereits
zweisprachig.

**Weitere Felder**

| Feld | Wert |
|---|---|
| Support-URL | `https://justus-dev02.github.io/NotifyAI/#support` |
| Marketing-URL | `https://justus-dev02.github.io/NotifyAI/` |
| Datenschutzrichtlinien-URL | `https://justus-dev02.github.io/NotifyAI/datenschutz.html` |
| Kategorie | Produktivität (zweite: Wirtschaft) |
| Copyright | `2026 <dein Name>` |
| Preis | Kostenlos |
| Altersfreigabe | Fragebogen: überall „Nein“ / „Keine“ → 4+ |
| App-Datenschutz | „Daten werden nicht erfasst“. Das stimmt: Der Entwickler erhält keine Daten. Was die App auf Wunsch an Notion oder Webhooks sendet, zählt nicht, weil es an Dienste des Nutzers geht. |
| Exportkontrolle | erledigt: `ITSAppUsesNonExemptEncryption = NO` in `NotifyAI-Info.plist` |

**Screenshots** (Pflicht, je Gerätegröße mindestens einer, höchstens zehn):

```sh
scripts/screenshots.sh     # → ~/Downloads/NotifyAI-Screenshots
```

Das Skript startet die App im Simulator mit englischer Oberfläche und englischen Beispielnotizen
(nur in Debug-Builds enthalten) und speichert die Bildschirme für iPhone 6,9″ (1320 × 2868) und
iPad 13″ (2064 × 2752). Das sind genau die Größen, die App Store Connect verlangt. Die Navigation
steht in `NotifyAIUITests/ScreenshotTests.swift`, die Notizen in
`Packages/NotifyAIKit/Sources/NotifyAIServices/ScreenshotSampleData.swift`.

**Hinweise für die App-Prüfung** (*App Review Information → Notes*):

> NotifyAI needs no account. All processing happens on device.
> - Recording: tap the record button. The app uses the "audio" background mode so recordings continue when the app is in the background or the screen is locked (Live Activity shows the running recording).
> - Summaries use Apple Intelligence (Foundation Models). On devices without Apple Intelligence the app creates a simpler, clearly labelled summary.
> - Optional speech models (Whisper, Parakeet) are downloaded from Hugging Face only when the user starts the download in Settings → Recording. Apple Speech works without any download.
> - "processing" background mode: long recordings are summarized with BGContinuedProcessingTask / BGProcessingTask.

---

## 3. Eine Version veröffentlichen

### Vorbereitung

1. Versionsnummer festlegen, z. B. `1.0.0`. Mac und iOS bekommen dieselbe.
2. `release-notes/1.0.0.md` schreiben (siehe `release-notes/README.md`), committen und auf `main` pushen.

### Mac (Website + Sparkle)

3. `scripts/release.sh 1.0.0 --publish` lokal ausführen oder GitHub → *Actions → Release → Run workflow*
   mit Plattform „nur macOS“ bzw. „macOS und iOS“.
   Das Skript baut, signiert mit Developer ID, notarisiert App und DMG, legt Tag und GitHub-Release
   mit `NotifyAI-1.0.0.dmg`, `NotifyAI.dmg` und `NotifyAI-1.0.0.zip` an und pusht `appcast.xml`.
4. Prüfen: Website-Button lädt das neue DMG, eine installierte ältere Version meldet das Update.

### iOS (App Store)

5. `scripts/release-ios.sh 1.0.0` (oder im Workflow mit Plattform „iOS“). Der Build wird zu App Store
   Connect hochgeladen.
6. Nach 10–30 Minuten: App Store Connect → *TestFlight*. Build auf dem eigenen iPhone testen.
7. *App Store → Version 1.0.0* (beim ersten Mal *+ Version*): Build auswählen, Neuerungen eintragen
   (Text aus den Release-Notes), Screenshots und Texte prüfen.
8. *Zur Prüfung hinzufügen → Zur Prüfung einreichen.* Die Prüfung dauert meist 1–2 Tage.
   Bei Ablehnung steht der Grund im *Resolution Center*: beheben oder dort antworten, neuen Build
   hochladen, erneut einreichen.
9. Nach der Freigabe: Veröffentlichung automatisch oder per Klick. Danach in `website/index.html` den
   App-Store-Button aktivieren (Kommentar dort), committen, pushen.

### Häufige Fehler

| Meldung | Ursache, Lösung |
|---|---|
| `Anmeldung für die Notarisierung fehlgeschlagen` | Profil fehlt: Abschnitt 1.1, `notarytool store-credentials` |
| `No signing certificate "Developer ID Application" found` | Zertifikat fehlt: Abschnitt 1.1 |
| `Apple hat … nicht notarisiert` | Das Log darüber nennt die Datei. Meist fehlt die Hardened Runtime oder ein eingebettetes Binary ist unsigniert. |
| Upload: `The bundle version must be higher …` | Diese Build-Nummer ist schon hochgeladen. Neuen Commit machen, die Build-Nummer ist die Anzahl der Commits. |
| Upload: `No suitable application records were found` | App-Eintrag fehlt: Abschnitt 1.3 |
