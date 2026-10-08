# Documentazione tecnica di MusicAmp

Riferimenti per chi lavora sul codice o crea contenuti (skin, preset) per MusicAmp.

| Documento | Di cosa parla |
| --- | --- |
| [Architettura](architettura.md) | Struttura del codice, controller centrale, finestre, ridisegno, gruppi di finestre |
| [Skin classiche](skin-classiche.md) | Formato `.wsz` di Winamp 2.x supportato e come viene disegnato |
| [Skin Retina](skin-retina.md) | Specifica dei bitmap e cursori `@2x` opzionali dentro il `.wsz` |
| [Editor dei tag e vista copertina](tag.md) | Modifica dei tag su più file (MP3, FLAC, M4A), ricerca su MusicBrainz e Cover Art Archive, vista grande della copertina |
| [Motore audio](audio.md) | Grafo AVAudioEngine, gapless, crossfade, bit-perfect, EQ parametrico e AutoEq, file CUE, timer e sveglia, ReplayGain, FFmpeg, radio, podcast |
| [Intelligenza artificiale sul Mac](ai.md) | Testi sincronizzati dall'audio, podcast trascritti con capitoli/riassunto/pubblicità, playlist a parole, umore e stile, riordino dei tag |
| [Ascolti, voti e playlist intelligenti](playlist-intelligenti.md) | Conteggio degli ascolti, voti, regole e ordinamenti delle playlist intelligenti |
| [Integrazione con macOS](sistema.md) | Comandi rapidi (App Intents senza Xcode), widget WidgetKit, URL `musicamp://` |
| [Milkdrop](milkdrop.md) | Motore di visualizzazione: preset `.milk`, equazioni, pipeline Metal, shader MD2 tradotti |
| [Strumenti di debug e test](strumenti-debug.md) | Opzioni da riga di comando e variabili d'ambiente |

Lo stato delle funzioni e la roadmap stanno nel documento condiviso "MusicAmp — Funzionalità e Roadmap".

## Compilare

```bash
./build-app.sh
```

Crea `build/MusicAmp.app` (release Apple Silicon, firma ad hoc, con FFmpeg LGPL incluso: la prima volta lo compila da ffmpeg.org con `Scripts/build-ffmpeg.sh`) e l'immagine disco `build/MusicAmp-<versione>.dmg`, con l'app, un collegamento ad Applicazioni e la licenza. La versione è `CFBundleShortVersionString` di `Resources/Info.plist`. Con `--no-dmg` si crea solo l'app. Il pacchetto Swift richiede macOS 26 su Apple Silicon e Swift 6; non c'è un progetto Xcode, ma serve Xcode installato perché `build-app.sh` genera i metadati di Comandi rapidi e widget con `appintentsmetadataprocessor` (vedi [sistema.md](sistema.md)). L'app contiene l'estensione widget `PlugIns/MusicAmpWidget.appex`, firmata con i suoi entitlement di sandbox.

La firma è ad hoc, senza Developer ID né notarizzazione: su un altro Mac Gatekeeper blocca la prima apertura. Si apre col tasto destro → Apri, oppure da Impostazioni di Sistema → Privacy e sicurezza.
