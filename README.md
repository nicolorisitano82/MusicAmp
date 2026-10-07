# MusicAmp

Un player audio minimale e nativo per macOS, compatibile con le skin classiche di Winamp 2.x (`.wsz`), con visualizzazioni Milkdrop su Metal.

![Finestra principale, equalizzatore e playlist con la skin predefinita](docs/images/player.png)

## Funzioni principali

- **Skin di Winamp 2.x pixel per pixel:**
  - finestra principale, equalizzatore, playlist e le loro modalità ridotte;
  - finestre secondarie con la grafica della skin, `region.txt`, cursori `.cur`/`.ani`, font della skin;
  - [skin Retina](docs/skin-retina.md) opzionali, con bitmap `@2x` nello stesso `.wsz`.
- **Audio:**
  - gapless, crossfade, ReplayGain (dai tag o misurato con EBU R128);
  - EQ a 10 bande con i preset Winamp `.eqf`/`.q1`;
  - formati extra (Ogg, Opus, APE, WavPack, Musepack, WMA, DSD…) con FFmpeg già incluso;
  - AirPlay e scelta dell'uscita.
- **Radio internet** Icecast/SHOUTcast e HLS, con client nativo e catalogo radio-browser.info.
- **Podcast:** ricerca, RSS, OPML, download, velocità e intonazione, ripresa dal punto salvato negli audiolibri.
- **Testi** sincronizzati (LRCLIB, `.lrc`, tag) e **karaoke** a schermo intero con le parole evidenziate una alla volta.
- **Milkdrop** su Metal:
  - preset `.milk` di Milkdrop 1 e 2;
  - gli shader HLSL di Milkdrop 2 sono tradotti in Metal: compila il 99,9% della raccolta "cream of the crop" di projectM.
- **Playlist** piatta o ad albero artista → album → brano, con coda, Jump to file e libreria di Musica.
- **macOS:**
  - tasti multimediali e "In riproduzione", mini controller nella barra dei menu, notifiche;
  - VoiceOver e scorciatoie globali;
  - finestre agganciate viste come una sola in Mission Control.

| Playlist ad albero | Finestre secondarie con la grafica della skin |
| --- | --- |
| ![Playlist raggruppata per artista e album](docs/images/playlist-albero.png) | ![Finestra di informazioni sul file disegnata con gen.bmp](docs/images/finestra-skin.png) |

### Milkdrop

| | |
| --- | --- |
| ![Preset Bass Tunnel](docs/images/milkdrop-bass-tunnel.png) | ![Preset Shader Bloom, con shader Milkdrop 2](docs/images/milkdrop-shader-bloom.png) |
| ![Preset Chroma Tunnel, con shader Milkdrop 2](docs/images/milkdrop-chroma-tunnel.png) | ![Preset Beat Rings](docs/images/milkdrop-beat-rings.png) |

*Preset inclusi in MusicAmp, renderizzati con audio di prova. Le immagini dell'interfaccia usano la skin predefinita di MusicAmp.*

## Installazione

Scarica il DMG dall'ultima [release](https://github.com/nicolorisitano82/MusicAmp/releases), aprilo e trascina **MusicAmp** in Applicazioni. Serve macOS 13 o successivo.

L'app non è ancora firmata con un Developer ID né notarizzata, quindi alla prima apertura macOS la blocca. Aprila col **tasto destro → Apri**, oppure da **Impostazioni di Sistema → Privacy e sicurezza → Apri comunque**.

Le skin non sono incluse: trascina un file `.wsz` sul player per caricarlo. I preset Milkdrop vanno in `~/Library/Application Support/MusicAmp/Milkdrop`; 8 sono già inclusi.

## Compilare

```bash
./build-app.sh
```

Crea `build/MusicAmp.app` e `build/MusicAmp-<versione>.dmg`. Servono Swift 5.9 e macOS 13; non c'è un progetto Xcode. La prima build scarica e compila FFmpeg dai sorgenti ufficiali (circa un minuto).

## Documentazione

La [documentazione tecnica](docs/README.md) copre architettura, formato delle skin classiche e Retina, motore audio, Milkdrop e strumenti di test.

## Licenza

Pubblico dominio ([The Unlicense](LICENSE)). Skin, font e preset di terze parti restano dei rispettivi autori. L'FFmpeg incluso è distribuito con licenza LGPL 2.1 o successiva: licenza e sorgenti sono indicati nell'app (Preferenze → Audio) e nel DMG.
