# Strumenti di debug e test

L'eseguibile (`.build/debug/MusicAmp`, `.build/release/MusicAmp` o `MusicAmp.app/Contents/MacOS/MusicAmp`) accetta opzioni da riga di comando che eseguono un compito e terminano. I test stampano `PASS`/`FAIL` e chiudono con `ALL PASSED`, o con il numero di errori e codice d'uscita 1.

## Suite di test

Tutte insieme, con un riepilogo e codice d'uscita 1 se qualcosa fallisce:

```bash
Scripts/test-all.sh
```

- `--offline` salta le suite che usano internet (AutoEq, LRCLIB, podcast, MusicBrainz).
- `--release` prova la build ottimizzata.
- `--package` controlla anche `build/MusicAmp.app` (dopo `./build-app.sh`): app, widget e FFmpeg universali, firma, avvio del widget da `NSExtensionMain`, sandbox del widget, le 19 azioni di Comandi rapidi, versioni allineate, schema `musicamp://`, licenza FFmpeg, versione Intel eseguita con Rosetta.
- `--ui` aggiunge la prova del trascinamento delle finestre, che apre MusicAmp per qualche secondo.
- Con dei nomi (`Scripts/test-all.sh sonic vocal`) esegue solo quelle suite.
- Ogni suite ha un tempo massimo. Fallisce con un codice d'uscita diverso da 0, una riga `FAIL` o il superamento del tempo. I log restano in una cartella temporanea.
- Le suite audio suonano a volume 0 e non cambiano mai la frequenza del dispositivo di uscita. Quelle che devono creare file di prova (tag, FFmpeg) richiedono l'ffmpeg di Homebrew, altrimenti vengono saltate. `MUSICAMP_TEST_RADIO_URL` aggiunge una radio vera.

Le singole suite:

| Comando | Cosa verifica |
| --- | --- |
| `--self-test [preset.eqf …]` | Preset EQ `.eqf`/`.q1`, coda, inserimento al punto di rilascio, skin Retina (bitmap e cursori `@2x`, Scale2x), playlist ad albero |
| `--test-transitions` | Gapless, crossfade, loudness EBU R128, lettura dei tag ReplayGain |
| `--test-ffmpeg` | Decodifica di Ogg, Opus, WavPack e TTA con l'FFmpeg scelto da MusicAmp (incluso, `MUSICAMP_FFMPEG_DIR` o installato); i file di prova si generano con un FFmpeg completo installato |
| `--test-radio URL [secondi]` | Riproduce una radio senza audio e stampa formato, titolo e livello |
| `--test-podcast` | Parser RSS (titoli, autori, copertine, durate, id degli episodi), OPML anche annidati, scaricamento e lettura di un feed reale, velocità e riproduzione in streaming con ripresa dal punto salvato |
| `--test-lyrics` | Parser LRC ed LRC esteso, tempi per parola, file `.lrc` affiancati, ricerca su LRCLIB (stampa solo conteggi, mai testi) |
| `--test-tags` | Scrittura e rilettura dei tag su MP3 (ID3v2.3+v1, 2.4), FLAC e M4A, audio intatto, verifica con `ffprobe`, modello dell'editor (serve un FFmpeg completo installato per i file di prova) |
| `--test-cue` | File con tre toni indicizzato da un `.cue`: parsing, espansione della cartella, segmenti suonati (nativo e via FFmpeg), passaggio gapless alla traccia dopo |
| `--test-peq` | Formato Equalizer APO, risposta calcolata, EQ parametrico misurato sul motore (+12 dB a 1 kHz), indice AutoEq |
| `--test-bitperfect` | Scelta della frequenza del dispositivo, grafo ricostruito a un'altra frequenza, diagnosi; non cambia la frequenza del dispositivo |
| `--test-musicbrainz` | Escape delle query, associazione file/tracce, ricerche reali su MusicBrainz e Cover Art Archive |
| `--test-schedule` | Orari della sveglia (giorni, una volta, ora legale), curve di dissolvenza, stato del widget, URL `musicamp://`, ring buffer del bridge Musica/Spotify |
| `--test-outputs` | Stream live AAC per le casse (HTTP, frame ADTS, tono decodificato, silenzio, copertina), AVPlayer muto sullo stream (AirPlay), messaggi Cast v2, descrizioni Sonos/DLNA; con `MUSICAMP_TEST_NET=1` elenca le casse in rete |
| `--test-tv [frame.png]` | Karaoke sulla TV: fotogramma (orientamento, riga cantata, tempo di disegno), stream HLS audio+video e solo audio (playlist, segmenti, tracce), AVPlayer muto sull'indirizzo di rete; salva i fotogrammi se si passa un percorso |
| `--test-livevideo [frame.png]` | Live Video: righe in scene, chiavi della cache, tempi delle scene, dissolvenza, fotogramma sopra un'immagine; con `MUSICAMP_TEST_SD=1` storyboard con Apple Intelligence e un'immagine con il modello installato |
| `--livevideo-diagnose` | Storyboard di Live Video su tutti i testi in cache: righe, gruppi, esito o errore esatto (filtri, rifiuto, contesto), scene di riserva, tempi; i testi non vengono mai stampati |
| `--test-i18n` | Stringhe italiane (specificatori di formato, menu e impostazioni coperti), scelta della lingua; con `-AppleLanguages '(it)'` nel bundle verifica il lookup in italiano |
| `--test-vocal` | Rimozione della voce su uno stereo generato: voce al centro a 440 Hz rimossa, strumento solo a sinistra e basso al centro conservati, forza al 50%, spenta = inalterato |
| `--test-smart` | Transizioni intelligenti: misura del silenzio in testa e in coda, nessun buco tra album diversi, silenzio conservato nello stesso album e con l'opzione spenta |
| `--test-sonic` | Analisi sonora su musica generata: tempo, tonalità, timbro; brani simili, Sonic Radio, viaggio sonoro e il suo riordino |
| `--test-ai` | Apple Intelligence: podcast sintetico (trascrizione, capitoli, riassunto, pubblicità), riordino dei tag, playlist a parole; "SKIP" se Apple Intelligence è spento |
| `--test-dock` | Modalità Dock a volume zero: il clic sull'icona suona e mette in pausa, menu del Dock, icona che avanza, esclusione con il Mini Tile, Show Player |
| `--test-spoken` | Podcast: trova le pause lunghe e ignora quelle brevi, la posizione avanza più del tempo reale con i silenzi accorciati, Voice Boost alza la voce bassa più di quella forte senza saturare |
| `--test-crossfeed` | Crossfeed: livello dei bassi passati all'altro canale per ogni preset, acuti quasi intatti, livello del mono invariato |
| `--test-waveform [cartella]` | Barra a forma d'onda: livelli di un file generato, segmento `.cue`, FFmpeg contro nativo, cache, render della barra (spenta = pixel identici, accesa = solo la scanalatura); con `MUSICAMP_WAVE_SKIN` e `MUSICAMP_WAVE_FILE` usa una skin e un brano veri e salva i PNG nella cartella |
| `--test-stats` | Conteggio degli ascolti (soglia, salti, ricerche, pausa), voti, regole e ordinamenti delle playlist intelligenti |
| `--test-milkdrop [cartella]` | Equazioni NS-EEL, parsing dei `.milk`, traduzione e compilazione degli shader MD2, render offscreen dei preset inclusi (con PNG nella cartella, se indicata) |

## Strumenti

| Comando | Uso |
| --- | --- |
| `--dock-snapshot out.png [copertina]` | Icona del Dock dinamica nei quattro stati: in riproduzione, in pausa, radio, senza copertina |
| `--ai-playlist "testo" …` | Playlist intelligenti generate dalla descrizione sulla libreria vera (non salvate) |
| `--ai-tags file …` | Tag proposti per file veri (non scritti) |
| `--ai-lyrics-check file [lingua]` | Precisione dei testi sincronizzati dall'audio rispetto ai tempi veri di LRCLIB (solo numeri) |
| `--sonic-analyze file …` | Tempo, tonalità, volume, luminosità e tempo di analisi di ogni file |
| `--snapshot skin.wsz out.png` | Immagine di finestra principale, EQ e playlist (normali e ridotte) per una skin; con `-` usa la predefinita |
| `--resolve-fonts "Nome" …` | Cerca dei font come fa la playlist e dice da dove arrivano |
| `--parse-cursor file.ani` | Fotogrammi, tempi e hotspot di un cursore |
| `--replaygain file …` | Tag ReplayGain e misura della loudness |
| `--retina-check skin.wsz` | Bitmap e cursori `@2x` presenti e avvisi |
| `--make-retina in.wsz out.wsz` | Aggiunge gemelli `@2x` (Scale2x) a una skin |
| `--milkdrop-verify cartella [report.txt] [campione]` | Traduce e compila in parallelo tutti i `.milk` di una cartella, elenca le cause d'errore più frequenti e renderizza un campione di preset (per trovare quelli neri o fermi) |
| `--milkdrop-msl preset.milk` | Mostra la traduzione Metal degli shader di un preset e gli errori del compilatore con la riga incriminata |
| `--karaoke-sweep` | Renderizza una riga karaoke a 330 istanti consecutivi (60 fps) attraverso una parola tenuta e cerca sfarfallii (fotogrammi che saltano e tornano) e cambi di dimensione; `KARAOKE_W` imposta la larghezza per provare gli a capo. Esce con codice 1 se ne trova |
| `--karaoke-snapshot out.png` | Renderizza righe karaoke (parole di prova) in istanti diversi: riempimento, parola tenuta, effetto dei bassi |
| `--milkdrop-snapshot preset.milk out.png [fotogrammi]` | Renderizza un preset con audio sintetico, stampa l'andamento (pixel accesi, decay, zoom…) e salva l'ultimo fotogramma |

## Variabili d'ambiente

| Variabile | Effetto |
| --- | --- |
| `MUSICAMP_FFMPEG_DIR=cartella` | Usa `ffmpeg`/`ffprobe` di quella cartella (per esempio `vendor/ffmpeg`) quando non c'è quello incluso nell'app |
| `MUSICAMP_RETINA=1` | `--snapshot` disegna a 2x usando i bitmap `@2x` |
| `MUSICAMP_SEARCH=testo` | `--snapshot` apre la ricerca della playlist con quel testo e stampa i risultati |
| `MUSICAMP_TREE=1` | `--snapshot` mostra la playlist ad albero |
| `MUSICAMP_EGG=1` | `--snapshot` con l'easter egg della barra del titolo |
| `MUSICAMP_DEBUG_GROUPS=1` | Scrive nel log i gruppi di finestre agganciate (Mission Control) |
| `MUSICAMP_TEST_GROUPS=1` | Esegue all'avvio una sequenza di stacca/riaggancia e registra i gruppi |
| `MUSICAMP_TEST_DRAG=1` | All'avvio trascina a passi il gruppo della finestra principale con il codice vero e verifica che ogni finestra segua il mouse e che il gruppo venga ricomposto (`DRAG OK`/`DRAG FAIL`), poi esce |
| `MUSICAMP_DEBUG_DRAG=1` | Scrive nel log inizio, passi e fine dei trascinamenti delle finestre |
| `MUSICAMP_TAG_DEMO=cartella` | Apre l'editor dei tag sui file audio di quella cartella (per prove e screenshot) |
| `MUSICAMP_DEBUG_HOTKEYS=1` | Registra le scorciatoie globali ricevute |
| `MUSICAMP_PREFS=timer` | Apre le impostazioni su una scheda (`general`, `audio`, `headphones`, `vis`, `playlist`, `timer`, `shortcuts`, `skins`); `smart` apre le playlist intelligenti |
| `MUSICAMP_DEMO=1` | `--snapshot` usa una playlist dimostrativa (artisti e album inventati) per gli screenshot del README |
| `MUSICAMP_SNAPSHOT_PARTS=cartella` | `--snapshot` salva anche ogni finestra in un PNG separato (`main`, `eq`, `playlist`, `file-info`…) |
| `MUSICAMP_HEADPHONES_DEMO=1` | Apre la scheda Cuffie in una finestra con un profilo AutoEq di esempio |

## Esempio: verifica di una raccolta di preset

```bash
swift build -c release
```

```bash
.build/release/MusicAmp --milkdrop-verify ~/Downloads/presets-cream-of-the-crop /tmp/report.txt 300
```

Il report elenca, per ogni preset con problemi, l'errore di traduzione o di compilazione di ogni shader. Con `--milkdrop-msl` si vede la riga Metal che lo ha causato.

## Feature flag

Funzioni costruite ma non ancora rilasciate. Sono spente di default e si accendono per singolo Mac (vedi `FeatureFlags.swift`); servono un riavvio di MusicAmp:

```bash
defaults write com.genomeup.musicamp feature.bridge -bool YES
```

| Flag | Funzione |
| --- | --- |
| `feature.bridge` | App Musica e Spotify come sorgente (Controlli → Sorgente): comando via AppleScript e cattura dell'audio con un process tap. Vedi [sorgenti-e-uscite.md](sorgenti-e-uscite.md) |
