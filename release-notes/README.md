# Release-Notes

Pro Version eine Datei `<version>.md`, z. B. `0.2.0.md`. `scripts/release.sh` verlangt sie,
zeigt sie im Update-Fenster der App an und verwendet sie als Text des GitHub-Releases.

Unterstützt werden für das Update-Fenster: `## Überschrift`, `- Aufzählung` und normale Absätze.

```markdown
## Neu
- Updates direkt in der App (Einstellungen → Updates)

## Behoben
- Aufnahme startet wieder nach dem Wechsel des Ausgabegeräts
```
