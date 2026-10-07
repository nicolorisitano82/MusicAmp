# Skin classiche (.wsz)

MusicAmp carica le skin di Winamp 2.x: archivi zip con estensione `.wsz`, ma anche `.zip` o cartelle. Le skin Modern (`.wal`) non sono supportate.

## Caricamento (`Skin.load`)

- L'archivio viene estratto con `/usr/bin/unzip` in una cartella temporanea. Il codice 1 (avvisi) è accettato.
- I file sono indicizzati senza distinguere maiuscole e minuscole; a parità di nome vince quello meno annidato. `__MACOSX` è ignorata.
- I bitmap sono letti in BMP o PNG e convertiti in RGBA a 32 bit.
- `main.bmp` è obbligatorio. Ogni altro bitmap mancante viene preso dalla skin predefinita disegnata via codice (`DefaultSkin`), come Winamp fa con la sua base skin.
- Se manca `balance.bmp` si usa `volume.bmp`, come in Winamp.

## Bitmap

| File | Contenuto |
| --- | --- |
| `main` | Sfondo della finestra principale |
| `titlebar` | Barra del titolo (attiva/inattiva), modalità ridotta, easter egg |
| `cbuttons` | Pulsanti di trasporto |
| `numbers`, `nums_ex` | Cifre del tempo (`nums_ex` ha il segno meno) |
| `text` | Font bitmap 5×6 del titolo che scorre e dei testi piccoli |
| `posbar`, `volume`, `balance` | Barre e cursori |
| `shufrep`, `playpaus`, `monoster` | Interruttori e indicatori |
| `eqmain`, `eq_ex` | Equalizzatore e sua modalità ridotta |
| `pledit` | Cornice, pulsanti e menu della playlist |
| `gen`, `genex` | Finestre secondarie (preferenze, libreria…) con i colori della skin |

## File di configurazione

| File | Uso |
| --- | --- |
| `viscolor.txt` | 24 colori del visualizzatore |
| `pledit.txt` | Colori della playlist (`Normal`, `Current`, `NormalBG`, `SelectedBG`) e nome del font |
| `region.txt` | Poligoni che danno forma alle finestre (sezioni `Normal`, `Equalizer`, `WindowShade`, `EqualizerWS`) |
| `*.cur`, `*.ani` | Cursori, anche animati (RIFF `ACON`); vedi `SkinCursor.swift` |
| `*.ttf`, `*.otf` | Font allegati alla skin, registrati per la playlist |

## Font della playlist

`FontResolver` cerca il font di `pledit.txt` in quest'ordine:

1. un font già scaricato o sostituito in precedenza, salvato in `Fonts/`;
2. i font allegati alla skin;
3. i font installati nel sistema;
4. se il download automatico è disattivo, un font simile già presente;
5. altrimenti una ricerca online, che non blocca il disegno.

Finché non trova niente usa Arial. Il font bitmap `text.bmp` si usa per il titolo che scorre e il tempo, come in Winamp.

## Disegno

Le coordinate degli sprite sono quelle di Winamp, in pixel della skin. `Renderer` offre:

- `blit` copia una porzione di un foglio; se il rettangolo sorgente esce dal foglio salta la parte mancante, come Winamp;
- `tileX`/`tileY` ripetono uno sprite;
- `fill` e `clip`;
- `text` scrive col font `text.bmp`, `ttf` col font vettoriale.

La skin di riserva (`DefaultSkin`) disegna via codice ogni foglio con le stesse coordinate, quindi ogni sprite esiste sempre.

## Barra di avanzamento a forma d'onda

Opzione **Impostazioni → Visualization → Waveform in the position bar** (anche nel menu Visualization), spenta di default: con l'opzione spenta ogni skin è disegnata esattamente come prima.

- **Dove:** dentro la barra di `posbar.bmp`, tra le due posizioni estreme del cursore (219 px, x 30–249 della finestra principale), così il centro del cursore è sempre sull'istante in riproduzione. Sfondo e cursore restano quelli della skin; il cursore è disegnato sopra l'onda.
- **Altezza:** la scanalatura scura della barra, trovata dalla luminosità delle righe di `posbar.bmp` (più un pixel sopra e sotto); se la barra non ha una scanalatura chiara (per esempio è trasparente) si usano 8 px. Il disegno è ritagliato su quel rettangolo e non tocca mai il resto della skin.
- **Colori:** da `viscolor.txt`. Si preferisce un colore della metà bassa dello spettro (il verde della skin classica); se contrasta poco con una delle righe della scanalatura, si sceglie fra gli altri colori dello spettro e dell'oscilloscopio quello più leggibile. La parte già suonata è piena, quella da suonare al 60%, con un bordo di un pixel nel tono opposto che la stacca da qualsiasi sfondo (anche dalle barre senza scanalatura, come i tubi chiari di Winamp5 Classified).
- **Risoluzione:** una colonna per pixel del dispositivo: sugli schermi Retina l'onda ha il doppio del dettaglio, mentre gli sprite restano a pixel pieni.
- **Dati (`WaveformStore`):** 512 livelli RMS per brano (o per traccia di un `.cue`), stirati tra il fondo del brano (metà del 10° percentile) e il bucket più forte, perché anche i master molto compressi mostrino strofe e pause. Calcolo in background alla prima riproduzione (AVAudioFile con vDSP, ~0,3 s per un MP3 di 4 minuti in release; FFmpeg a 4 kHz mono per gli altri formati), poi cache in `Application Support/MusicAmp/Waveforms` (512 byte per brano, chiave = URL + dimensione + data del file). Finché non è pronta si vede la barra classica.
- Radio ed episodi in streaming tengono la barra classica. La modalità ridotta non cambia.
- La stessa onda sostituisce la barra della **vista copertina** quando l'opzione è attiva.

Test: `--test-waveform [cartella]` (forma, segmento `.cue`, FFmpeg contro nativo, cache, e il render della barra a 1x e 2x: con l'opzione spenta i pixel devono essere identici, accesa può cambiare solo la scanalatura). `MUSICAMP_WAVE_SKIN` e `MUSICAMP_WAVE_FILE` provano una skin e un brano veri.
