# Skin Retina

Una skin Retina è una normale skin `.wsz` con, in più, versioni a doppia risoluzione di bitmap e cursori, con suffisso `@2x`, nello stesso archivio. Winamp ignora i file in più e usa la skin come sempre. MusicAmp, su uno schermo Retina o in dimensione doppia, disegna la grafica `@2x` con le stesse coordinate degli sprite.

Codice: `RetinaSkin.swift` (caricamento, verifica, Scale2x, strumenti), `Renderer.blit` (scelta del foglio), `SkinView.pixelScale`.

## Formato

Ogni bitmap della skin può avere un gemello con lo stesso nome più `@2x`, in PNG (consigliato, ammette la trasparenza) o BMP. Il gemello:

- ha **esattamente** il doppio di larghezza e altezza della versione 1x presente nella skin;
- ha la stessa disposizione degli sprite: quello che in `main.bmp` sta a (16, 88, 23×18) in `main@2x.png` sta a (32, 176, 46×36);
- è cercato senza distinguere maiuscole e minuscole, come i file classici.

| Bitmap 1x | Misura 1x (px) | Gemello @2x | Misura @2x (px) |
| --- | --- | --- | --- |
| `main.bmp` | 275 × 116 | `main@2x.png` | 550 × 232 |
| `titlebar.bmp` | 344 × 87 | `titlebar@2x.png` | 688 × 174 |
| `cbuttons.bmp` | 136 × 36 | `cbuttons@2x.png` | 272 × 72 |
| `numbers.bmp` / `nums_ex.bmp` | 99 × 13 / 108 × 13 | `numbers@2x.png` / `nums_ex@2x.png` | 198 × 26 / 216 × 26 |
| `text.bmp` | 155 × 74 | `text@2x.png` | 310 × 148 |
| `posbar.bmp` | 307 × 10 | `posbar@2x.png` | 614 × 20 |
| `volume.bmp` / `balance.bmp` | 68 × 433 | `volume@2x.png` / `balance@2x.png` | 136 × 866 |
| `shufrep.bmp` | 92 × 85 | `shufrep@2x.png` | 184 × 170 |
| `playpaus.bmp` | 42 × 9 | `playpaus@2x.png` | 84 × 18 |
| `monoster.bmp` | 58 × 24 | `monoster@2x.png` | 116 × 48 |
| `eqmain.bmp` | 275 × 315 | `eqmain@2x.png` | 550 × 630 |
| `eq_ex.bmp` | 275 × 82 | `eq_ex@2x.png` | 550 × 164 |
| `pledit.bmp` | 280 × 186 | `pledit@2x.png` | 560 × 372 |
| `gen.bmp` | 194 × 109 | `gen@2x.png` | 388 × 218 |
| `genex.bmp` | 130 × 75 | `genex@2x.png` | 260 × 150 |
| `cursore.cur` / `.ani` | 32 × 32 per fotogramma | `cursore@2x.cur` / `@2x.ani` | 64 × 64 per fotogramma |

Le misure 1x sono quelle della skin base 2.91. Il vincolo vero è "doppio della 1x presente nella skin", qualunque sia. Una skin può fornire solo alcuni gemelli: i bitmap senza `@2x` vengono ingranditi dalla versione 1x.

## Regole di validazione

| Caso | Cosa fa MusicAmp |
| --- | --- |
| `@2x` esattamente 2× la 1x | Accettato |
| `@2x` di misura diversa, anche di 1 px | Scartato con un avviso in `--retina-check`; si usa la 1x ingrandita |
| Solo `@2x`, nessuna 1x | Accettato; la 1x è ricavata prendendo il pixel in alto a sinistra di ogni blocco 2×2. Winamp però non vedrà quel bitmap |
| PNG e BMP dello stesso gemello | Vince il PNG |
| `balance@2x` assente ma `volume@2x` presente | Si usa `volume@2x`, come Winamp fa con `volume.bmp` |
| `.cur` `@2x` | Unito al cursore 1x come seconda risoluzione, stesso hotspot in punti |
| `.ani` `@2x` | Accettato se ha lo stesso numero di fotogrammi del `.ani` 1x; tempi, sequenza e hotspot restano quelli 1x. Altrimenti scartato con avviso |

Per restare compatibile con Winamp, una skin Retina deve contenere sempre tutti i bitmap 1x: i gemelli si aggiungono, non sostituiscono.

## Cosa resta in coordinate 1x

- `region.txt`: i poligoni restano in pixel 1x e vengono scalati, quindi la sagoma è già nitida a 2x.
- `viscolor.txt` e `pledit.txt`: invariati.
- Colori letti dai pixel (linea del grafico EQ in `eqmain` a 115,294; colori dei testi in `genex`; separazione delle lettere in `gen`): sempre dalla 1x, che resta la fonte di verità per i colori.
- Coordinate degli sprite, aree cliccabili e misure delle finestre: invariate. La finestra principale resta 275 × 116 punti.

## Rendering

- `SkinView.pixelScale` = fattore dello schermo × dimensione della finestra, arrotondato (da 1 a 4). Il framebuffer del `Renderer` ha quel numero di pixel per pixel della skin e il CTM scalato di conseguenza, così il codice di disegno continua a usare coordinate 1x.
- Gli sprite vengono presi dal gemello `@2x` (rettangolo sorgente ×2) solo se l'opzione *Preferenze → Skin → Usa la grafica Retina* è attiva, la skin ha almeno un gemello valido e `pixelScale` ≥ 2. Altrimenti si usa la 1x ingrandita a pixel pieni, con un risultato identico a prima.
- Il testo vettoriale della playlist è sempre disegnato alla risoluzione dello schermo, con qualsiasi skin.
- Spostando una finestra tra schermi Retina e non Retina il ridisegno è automatico (`viewDidChangeBackingProperties`).

## Strumenti per autori

| Comando | Cosa fa |
| --- | --- |
| `MusicAmp --make-retina in.wsz out.wsz` | Copia la skin e aggiunge un gemello `@2x.png` per ogni bitmap e un `@2x.cur`/`@2x.ani` per ogni cursore, ingranditi con Scale2x (hotspot raddoppiato, tempi delle animazioni invariati). È un punto di partenza da ritoccare |
| `MusicAmp --retina-check skin.wsz` | Elenca le misure 1x e `@2x` di ogni bitmap, i cursori `@2x` e gli avvisi |
| `MUSICAMP_RETINA=1 MusicAmp --snapshot skin.wsz out.png` | Immagine di finestra principale, EQ e playlist disegnate a 2x |

Flusso consigliato:

1. generare la base con `--make-retina`;
2. ridisegnare i gemelli a 2x partendo dalla 1x;
3. controllare con `--retina-check` e con lo snapshot;
4. provare la skin in Winamp per assicurarsi che sia rimasta intatta.

## Limiti

- Scale2x lavora sull'intero foglio: ai bordi di uno sprite può prendere il colore dello sprite vicino. Questi puntini vanno ripuliti a mano.
- Il visualizzatore resta a blocchi di 1 pixel della skin.
- Non c'è `@3x`: oltre il 2x si ingrandisce la versione `@2x`.
