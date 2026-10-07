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
