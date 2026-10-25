# Hinweise zu Drittanbieter-Software

NotifyAI selbst steht unter der [MIT-Lizenz](LICENSE). Die App enthält die folgenden Bibliotheken und lädt auf
Wunsch die folgenden Modelle. Dieselben Angaben stehen in der App unter **Einstellungen → Allgemein → Lizenzen**,
mit den vollständigen Lizenztexten aus `NotifyAI/Licenses/` (unverändert aus den Paketen kopiert).

Stand: Versionen aus `Package.resolved` (FluidAudio 0.17.7, Jinja 1.3.0, swift-collections 1.7.1,
swift-transformers 0.1.15, WhisperKit `f31370f`, Sparkle 2.10.0). Bei einem Update der Pakete diese Liste und die
Lizenztexte prüfen.

## In der App enthaltene Bibliotheken

| Bibliothek | Lizenz | Copyright | Hinweis |
|---|---|---|---|
| [WhisperKit](https://github.com/argmaxinc/WhisperKit) | MIT | © 2024 argmax, inc. | |
| [FluidAudio](https://github.com/FluidInference/FluidAudio) | Apache-2.0 | Fluid Inference | Ohne die optionalen Teile für Sprachsynthese (Trait `NemoTextProcessing` abgewählt) |
| [VBx](https://github.com/BUTSpeechFIT/VBx) | Apache-2.0 | © 2021–2024 BUT Speech@FIT | Teil von FluidAudio |
| [fastcluster](https://danifold.net/fastcluster.html) | BSD-2-Clause | © 2011 Daniel Müllner, © Google Inc. | Teil von FluidAudio |
| [swift-transformers](https://github.com/huggingface/swift-transformers) | Apache-2.0 | © 2022 Hugging Face SAS | über WhisperKit |
| [Jinja](https://github.com/johnmai-dev/Jinja) | MIT | © 2024 John Mai | über swift-transformers |
| [Swift Collections](https://github.com/apple/swift-collections) | Apache-2.0 mit Runtime Library Exception | Apple Inc. und die Swift-Autoren | über WhisperKit |
| [Sparkle](https://github.com/sparkle-project/Sparkle) | MIT (enthält Code unter BSD- und MIT-artigen Lizenzen) | © 2006–2013 Andy Matuschak u. a. | nur macOS |

`swift-argument-parser` wird nur für Kommandozeilenwerkzeuge der Pakete gebraucht und ist nicht in der App enthalten.

## Modelle (nicht in der App, Download auf Wunsch von Hugging Face)

| Modell | Lizenz | Namensnennung | Änderungen |
|---|---|---|---|
| [Whisper](https://huggingface.co/argmaxinc/whisperkit-coreml) | MIT | © 2022 OpenAI; Core-ML-Fassung argmax, inc. | in Core ML umgewandelt (argmax) |
| [Parakeet Ultra](https://huggingface.co/FluidInference/parakeet-ultra-coreml) | [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/) | NVIDIA ([parakeet-tdt-0.6b-v3](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3)), Moondream ([parakeet-ultra](https://huggingface.co/moondream/parakeet-ultra)), Fluid Inference | nachtrainiert (Moondream), in Core ML umgewandelt, Encoder 8 Bit (Fluid Inference) |
| [Speaker Diarization Community-1](https://huggingface.co/FluidInference/speaker-diarization-coreml) | [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/) | pyannote ([speaker-diarization-community-1](https://huggingface.co/pyannote/speaker-diarization-community-1)), WeSpeaker, BUT Speech@FIT (PLDA), Fluid Inference | in Core ML umgewandelt (Fluid Inference) |

Die Sprechererkennung nutzt die Community-1-Dateien des Repos (`Segmentation`, `FBank`, `Embedding`, `PldaRho`,
`plda-parameters.json`); deren Lizenzumfang beschreibt die
[NOTICE.md](https://huggingface.co/FluidInference/speaker-diarization-coreml/blob/main/NOTICE.md) des Repos.

Apples Systemmodelle (Apple Intelligence, `NLContextualEmbedding`, Apple Speech) gehören zum Betriebssystem und sind
hier nicht aufgeführt.
