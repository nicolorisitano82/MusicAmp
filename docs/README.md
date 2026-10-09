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
| [Sorgenti, uscite e lingue](sorgenti-e-uscite.md) | Apple Music e Spotify come sorgente, stream live per più casse AirPlay, Chromecast, Sonos e UPnP, traduzione dei testi, lingua dell'interfaccia |
| [Ascolti, voti e playlist intelligenti](playlist-intelligenti.md) | Conteggio degli ascolti, voti, regole e ordinamenti delle playlist intelligenti |
| [Integrazione con macOS](sistema.md) | Comandi rapidi (App Intents senza Xcode), widget WidgetKit, URL `musicamp://` |
| [Milkdrop](milkdrop.md) | Motore di visualizzazione: preset `.milk`, equazioni, pipeline Metal, shader MD2 tradotti |
| [Strumenti di debug e test](strumenti-debug.md) | Opzioni da riga di comando e variabili d'ambiente |

Lo stato delle funzioni e la roadmap stanno nel documento condiviso "MusicAmp — Funzionalità e Roadmap".

## Compilare

```bash
./build-app.sh
```

Crea `build/MusicAmp.app` (release Apple Silicon, con FFmpeg LGPL incluso: la prima volta lo compila da ffmpeg.org con `Scripts/build-ffmpeg.sh`) e l'immagine disco `build/MusicAmp-<versione>.dmg`, con l'app, un collegamento ad Applicazioni e la licenza. La versione è `CFBundleShortVersionString` di `Resources/Info.plist`. Con `--no-dmg` si crea solo l'app. Il pacchetto Swift richiede macOS 26 su Apple Silicon e Swift 6; non c'è un progetto Xcode, ma serve Xcode installato perché `build-app.sh` genera i metadati di Comandi rapidi e widget con `appintentsmetadataprocessor` (vedi [sistema.md](sistema.md)). L'app contiene l'estensione widget `PlugIns/MusicAmpWidget.appex`, firmata con i suoi entitlement di sandbox.

**Firma.** Se nel portachiavi di login c'è il certificato autofirmato "MusicAmp Dev", `build-app.sh` firma con quello; altrimenti la firma è ad hoc.
- Con il certificato, il requisito di firma resta identico tra una build e l'altra: identificatore più impronta del certificato. macOS quindi ricorda i permessi già dati (cartella Musica, registrazione audio, Rete locale) invece di richiederli a ogni build. Con una firma ad hoc, ogni build sembra un'app nuova.
- `MUSICAMP_SIGN=<impronta o nome>` sceglie un'altra identità; `MUSICAMP_SIGN=-` forza la firma ad hoc.

Il certificato si crea una volta per Mac, è valido 10 anni e la chiave privata resta solo nel portachiavi:

```bash
openssl req -new -x509 -newkey rsa:2048 -nodes -keyout key.pem -out cert.pem -days 3650 \
  -subj "/CN=MusicAmp Dev" -addext "extendedKeyUsage=critical,codeSigning" -addext "keyUsage=critical,digitalSignature"
openssl pkcs12 -export -inkey key.pem -in cert.pem -out id.p12 -name "MusicAmp Dev" -passout pass:tmp
security import id.p12 -k ~/Library/Keychains/login.keychain-db -P tmp -T /usr/bin/codesign
rm key.pem id.p12
```

Non serve impostarne la fiducia: codesign lo usa tramite l'impronta.

In ogni caso non ci sono Developer ID né notarizzazione: su un altro Mac Gatekeeper blocca la prima apertura. Si apre col tasto destro → Apri, oppure da Impostazioni di Sistema → Privacy e sicurezza.
