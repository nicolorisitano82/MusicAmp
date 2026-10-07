# Strumenti di debug e test

L'eseguibile (`.build/debug/MusicAmp`, `.build/release/MusicAmp` o `MusicAmp.app/Contents/MacOS/MusicAmp`) accetta opzioni da riga di comando che eseguono un compito e terminano. I test stampano `PASS`/`FAIL` e chiudono con `ALL PASSED`, o con il numero di errori e codice d'uscita 1.

## Suite di test

| Comando | Cosa verifica |
| --- | --- |
| `--self-test [preset.eqf …]` | Preset EQ `.eqf`/`.q1`, coda, inserimento al punto di rilascio, skin Retina (bitmap e cursori `@2x`, Scale2x), playlist ad albero |
| `--test-transitions` | Gapless, crossfade, loudness EBU R128, lettura dei tag ReplayGain |
| `--test-ffmpeg` | Decodifica con FFmpeg di Ogg, Opus, WavPack e TTA (richiede `ffmpeg`) |
| `--test-radio URL [secondi]` | Riproduce una radio senza audio e stampa formato, titolo e livello |
| `--test-podcast` | Parser RSS (titoli, autori, copertine, durate, id degli episodi), OPML anche annidati, scaricamento e lettura di un feed reale, velocità e riproduzione in streaming con ripresa dal punto salvato |
| `--test-lyrics` | Parser LRC ed LRC esteso, tempi per parola, file `.lrc` affiancati, ricerca su LRCLIB (stampa solo conteggi, mai testi) |
| `--test-milkdrop [cartella]` | Equazioni NS-EEL, parsing dei `.milk`, traduzione e compilazione degli shader MD2, render offscreen dei preset inclusi (con PNG nella cartella, se indicata) |

## Strumenti

| Comando | Uso |
| --- | --- |
| `--snapshot skin.wsz out.png` | Immagine di finestra principale, EQ e playlist (normali e ridotte) per una skin; con `-` usa la predefinita |
| `--resolve-fonts "Nome" …` | Cerca dei font come fa la playlist e dice da dove arrivano |
| `--parse-cursor file.ani` | Fotogrammi, tempi e hotspot di un cursore |
| `--replaygain file …` | Tag ReplayGain e misura della loudness |
| `--retina-check skin.wsz` | Bitmap e cursori `@2x` presenti e avvisi |
| `--make-retina in.wsz out.wsz` | Aggiunge gemelli `@2x` (Scale2x) a una skin |
| `--milkdrop-verify cartella [report.txt] [campione]` | Traduce e compila in parallelo tutti i `.milk` di una cartella, elenca le cause d'errore più frequenti e renderizza un campione di preset (per trovare quelli neri o fermi) |
| `--milkdrop-msl preset.milk` | Mostra la traduzione Metal degli shader di un preset e gli errori del compilatore con la riga incriminata |
| `--milkdrop-snapshot preset.milk out.png [fotogrammi]` | Renderizza un preset con audio sintetico, stampa l'andamento (pixel accesi, decay, zoom…) e salva l'ultimo fotogramma |

## Variabili d'ambiente

| Variabile | Effetto |
| --- | --- |
| `MUSICAMP_RETINA=1` | `--snapshot` disegna a 2x usando i bitmap `@2x` |
| `MUSICAMP_TREE=1` | `--snapshot` mostra la playlist ad albero |
| `MUSICAMP_EGG=1` | `--snapshot` con l'easter egg della barra del titolo |
| `MUSICAMP_DEBUG_GROUPS=1` | Scrive nel log i gruppi di finestre agganciate (Mission Control) |
| `MUSICAMP_TEST_GROUPS=1` | Esegue all'avvio una sequenza di stacca/riaggancia e registra i gruppi |
| `MUSICAMP_DEBUG_HOTKEYS=1` | Registra le scorciatoie globali ricevute |

## Esempio: verifica di una raccolta di preset

```bash
swift build -c release
```

```bash
.build/release/MusicAmp --milkdrop-verify ~/Downloads/presets-cream-of-the-crop /tmp/report.txt 300
```

Il report elenca, per ogni preset con problemi, l'errore di traduzione o di compilazione di ogni shader. Con `--milkdrop-msl` si vede la riga Metal che lo ha causato.
