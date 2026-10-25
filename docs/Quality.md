# Qualität der Analyse

Die funktionalen Tests prüfen, *ob* etwas funktioniert. `NotifyAITests/QualityEvaluationTests.swift`
misst, *wie gut* es funktioniert, auf gelabelten Daten. Jede Messung hat eine Untergrenze
(`QualityLevels`); fällt ein Wert darunter, schlägt der Test fehl und nennt den gemessenen Wert.

| Bereich | Daten | Kennzahl | Gemessen | Untergrenze |
|---|---|---|---|---|
| Suche ohne Bedeutungsvektoren, Fragen mit den Wörtern der Notiz | 25 Notizen, 25 Fragen | Recall@1 | 0,96 | 0,90 |
| | 8 Fragen ohne Antwort | Anteil mit (falschem) Treffer | 0,25 | ≤ 0,25 |
| Suche mit Bedeutungsvektoren, Fragen mit den Wörtern der Notiz | 25 Fragen | Recall@1 | 0,96 | 0,90 |
| Suche mit Bedeutungsvektoren, umformulierte Fragen | 48 Fragen | Recall@1 / Recall@3 / MRR | 0,44 / 0,58 / 0,52 | 0,40 / 0,50 / 0,45 |
| | | MRR gegenüber Volltext allein | 0,52 gegenüber 0,25 | + 0,15 |
| | 8 Fragen ohne Antwort | Anteil mit (falschem) Treffer | 0,125 | ≤ 0,25 |
| Verwandte Notizen | 9 zusammengehörige Paare | gefunden unter den ersten 3 / Präzision | 0,44 / 0,20 | 0,40 / 0,18 |
| Sprechererkennung | Gespräch, 6 Sätze, 2 Systemstimmen | Diarization Error Rate | 5,9 % | ≤ 10 % |
| Fristen („bis Freitag“, „in zwei Wochen“ …) | 20 Formulierungen | Genauigkeit | 100 % | 100 % |
| Fragenverständnis (Zeitraum, Person, Art) | 10 Fragen | Genauigkeit | 100 % | 100 % |
| Kapitelgrenzen | 50 Minuten, 4 Themen | mittlere Abweichung | 6,7 s | ≤ 30 s |

## Befunde

### Suche (Oktober 2026)

Prüfkorpus: `NotifyAITests/SearchEvaluationCorpus.json`, 25 Transkripte in Alltagssprache, darunter absichtlich
ähnliche (zwei Bewerbungsgespräche, zwei Vorlesungen, zwei Gespräche mit demselben Kunden), 25 Fragen mit den Wörtern
der Notiz, 48 umformulierte, 5 sprachübergreifende und 8 ohne Antwort. Alle Werte ohne die Query-Erweiterung von Apple
Intelligence, die in Tests fehlt.

| | Wortgleich R@1 | Umformuliert R@1 / R@3 / MRR | Fehltreffer |
|---|---|---|---|
| Vorher: BM25 + `NLEmbedding`, Rangfusion, Treffer nur mit Volltext | 0,68 | 0,21 / 0,35 / 0,29 | 0,50 |
| Vorher, nur Volltext (BM25) | 0,84 | 0,25 / 0,40 / 0,32 | 0,50 |
| **Jetzt, ohne Bedeutungsvektoren** (Abdeckung ab 0,22) | **0,96** | 0,23 / 0,27 / 0,25 | 0,25 |
| **Jetzt, mit Bedeutungsvektoren** (0,7 · Ähnlichkeit + 0,3 · Abdeckung ab 0,32) | **0,96** | **0,44 / 0,58 / 0,52** | **0,125** |

Wie die Entscheidungen zustande kamen, jeweils gemessen:

- **Modell.** Nur mit Vektoren, ohne Volltext, findet `NLContextualEmbedding` umformulierte Fragen als ersten Treffer
  in 50 % der Fälle, `NLEmbedding.sentenceEmbedding` in 15 %. Die alten Vektoren verschlechterten die Suche sogar
  (wortgleich 0,68 statt 0,84 mit Volltext allein); sie fließen nicht mehr ein.
- **Mittel aller Token** statt nur der Inhaltswörter: Inhaltswörter allein helfen wortgleichen Fragen, verlieren aber
  ein Drittel der umformulierten (0,48 → 0,33).
- **Hintergrund abziehen.** Das Mittel fester Alltagssätze abzuziehen trennt Themen; das Mittel der eigenen Notizen
  abzuziehen schadete und wäre bei kleinen Bibliotheken instabil.
- **Fenster von 25 Wörtern.** 70 Wörter: 35 % umformulierte Fragen zuerst gefunden, 25 Wörter: 50 %, einzelne
  Sätze: 48 % bei fünfmal so vielen Vektoren.
- **8 Bit** statt `Float32`: keine Kennzahl ändert sich.
- **Wertfusion statt Rangfusion.** Die Rangfusion (RRF) ließ einen guten Volltext-Rang von einem mittelmäßigen
  Bedeutungsrang überholen und warf weg, *wie* ähnlich ein Abschnitt ist. Die Abdeckung ist im Gegensatz zu BM25
  zwischen Fragen vergleichbar; erst dadurch trägt eine feste Schwelle, und erst die Schwelle macht „nichts gefunden“
  möglich.
- **Gegen Überanpassung:** Gewicht und Schwelle wurden auf einer Hälfte der Fragen gewählt und auf der anderen geprüft.
  Aggressivere Werte (0,8 / 0,28) gewinnen auf der eigenen Hälfte und liefern auf der anderen 75 % Fehltreffer; 0,7 /
  0,32 hält auf beiden (umformuliert MRR 0,57 / 0,48, Fehltreffer 0,00 / 0,25). Mit nur 8 Fragen ohne Antwort ist die
  Fehltrefferquote grob; die Untergrenze lässt eine zusätzliche zu.
- **Geglättete Seltenheit über die ganze Bibliothek.** Mit den Gewichten von BM25 und über die gefilterten Notizen
  gerechnet fand „Samsung: Wie hoch ist das Budget?“ nichts: In den zwei Samsung-Notizen steht „Budget“ überall,
  „hoch“ nirgends, und das fehlende Wort überstimmte alles. Am Korpus kostet die Glättung eine umformulierte Frage,
  die ihre Notiz nicht mehr als erste findet (R@1 0,46 → 0,44); alles andere bleibt gleich.

Offen:

- **Sprachübergreifend** (englische Frage zu deutscher Notiz und umgekehrt) findet die Suche die Notiz in keinem der
  5 Fälle unter den ersten drei, vorher in einem. Das Modell legt beide Sprachen in einen Raum, trennt dort aber zu
  schwach.
- **Fragen ohne Antwort**, die ein seltenes Wort mit einer Notiz teilen, ergeben weiter Treffer (1 von 8).
- Die Belegverknüpfung der Zusammenfassung verwendet weiter `NLEmbedding`: Ihre Schwellen sind auf dieses Modell
  abgestimmt, und das neue Modell wäre für jedes Zwei-Segment-Fenster zehnmal langsamer. Umstellen nur mit eigener
  Messung.

### Verwandte Notizen

Neun vorgegebene Paare, die zusammengehören, ohne ihre Schlagwörter zu teilen (Kundengespräch und Nachverhandlung,
Sprint-Planung und Ausfall beim Login, Arzttermin und Rückruf der Praxis …). Gemessen wird, ob jede Notiz die andere
unter ihren ersten drei verwandten Notizen nennt, und welcher Anteil aller genannten Verbindungen vorgegeben ist.
Nicht vorgegebene Verbindungen sind nicht unbedingt falsch; die Präzision ist eine Untergrenze.

| | Gefunden | Präzision | Genannte Verbindungen |
|---|---|---|---|
| Vorher: `NLEmbedding`, Abstand zum Durchschnitt in Standardabweichungen (im neuen Index gemessen) | 0,22 | 0,13 | 32 |
| Jetzt: kontextuelle Vektoren, nach Abzug des Mittels aller Notizen, voll ab 0,4 | **0,44** | **0,20** | 41 |

Niedrigere Schwellen finden mehr Paare (0,3: 0,61), nennen aber zu fast jeder Notiz drei verwandte. Inhalt allein
bleibt ein mittelstarkes Signal („Umzug“ ↔ „Wohnungsbesichtigung“ erkennt das Modell kaum); in echten Notizen kommen
Personen, Organisationen, Labels und die Stichworte der Zusammenfassung hinzu.

### Frühere Befunde

- **„in zwei Wochen“** wurde vor der Messung nicht erkannt (nur Ziffern). Behoben; „in einem
  Monat“ bleibt bewusst offen, weil es meist vage gemeint ist.

## Messdaten

- Die Sprechererkennung verwendet echte, synthetisierte Sprache (`AVSpeechSynthesizer`, eine
  weibliche und eine weitere deutsche Systemstimme) mit bekannter Zeitleiste. Fehlen die
  Stimmen, wird der Test übersprungen.
- Die Fehlerrate zählt gesprochene Zeit, die dem falschen oder keinem Sprecher zugeordnet wird,
  bei bester Zuordnung der erkannten zu den wahren Sprechern.

Verbessert sich ein Wert dauerhaft, wird die Untergrenze angehoben. Sie zu senken braucht eine
Begründung im Commit.
