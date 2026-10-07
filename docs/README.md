# Documentazione tecnica di MusicAmp

Riferimenti per chi lavora sul codice o crea contenuti (skin, preset) per MusicAmp.

| Documento | Di cosa parla |
| --- | --- |
| [Architettura](architettura.md) | Struttura del codice, controller centrale, finestre, ridisegno, gruppi di finestre |
| [Skin classiche](skin-classiche.md) | Formato `.wsz` di Winamp 2.x supportato e come viene disegnato |
| [Skin Retina](skin-retina.md) | Specifica dei bitmap e cursori `@2x` opzionali dentro il `.wsz` |
| [Motore audio](audio.md) | Grafo AVAudioEngine, gapless, crossfade, ReplayGain, FFmpeg, radio, podcast |
| [Milkdrop](milkdrop.md) | Motore di visualizzazione: preset `.milk`, equazioni, pipeline Metal, shader MD2 tradotti |
| [Strumenti di debug e test](strumenti-debug.md) | Opzioni da riga di comando e variabili d'ambiente |

Lo stato delle funzioni e la roadmap stanno nel documento condiviso "MusicAmp — Funzionalità e Roadmap".

## Compilare

```bash
./build-app.sh
```

Crea `build/MusicAmp.app` (release, firma ad hoc). Il pacchetto Swift richiede macOS 13 e Swift 5.9; non c'è un progetto Xcode.
