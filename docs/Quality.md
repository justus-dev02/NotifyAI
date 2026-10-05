# Qualität der Analyse

Die funktionalen Tests prüfen, *ob* etwas funktioniert. `NotifyAITests/QualityEvaluationTests.swift`
misst, *wie gut* es funktioniert, auf gelabelten Daten. Jede Messung hat eine Untergrenze
(`QualityLevels`); fällt ein Wert darunter, schlägt der Test fehl und nennt den gemessenen Wert.

| Bereich | Daten | Kennzahl | Gemessen | Untergrenze |
|---|---|---|---|---|
| Suche, Fragen mit den Wörtern der Notiz | 10 Notizen, 10 Fragen | Recall@1 / MRR | 1,00 / 1,00 | 0,90 / 0,90 |
| Suche, umformulierte Fragen | 10 Notizen, 10 Paraphrasen | Recall@3 (hybrid) | 0,20 | 0,20 |
| | | MRR Volltext → hybrid | 0,08 → 0,15 | hybrid ≥ Volltext |
| Sprechererkennung | Gespräch, 6 Sätze, 2 Systemstimmen | Diarization Error Rate | 5,9 % | ≤ 10 % |
| Fristen („bis Freitag“, „in zwei Wochen“ …) | 20 Formulierungen | Genauigkeit | 100 % | 100 % |
| Fragenverständnis (Zeitraum, Person, Art) | 10 Fragen | Genauigkeit | 100 % | 100 % |
| Kapitelgrenzen | 50 Minuten, 4 Themen | mittlere Abweichung | 6,7 s | ≤ 30 s |

## Befunde

- **Umformulierte Fragen ohne Apple Intelligence:** Eine Notiz zählt nur mit einem Volltexttreffer;
  die Satz-Embeddings von Apple trennen deutsche Themen zu schwach, um allein zu entscheiden
  (`HybridRetriever.semanticWeight`). Synonyme liefert die Query-Erweiterung des Sprachmodells,
  die in Tests und auf Geräten ohne Apple Intelligence fehlt. Ohne sie wird nur jede fünfte
  Paraphrase gefunden. Wer hier verbessern will, hat mit diesem Test einen Maßstab.
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
