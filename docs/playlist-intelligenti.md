# Ascolti, voti e playlist intelligenti

## Conteggio degli ascolti (`PlayStats.swift`)

Ogni file locale aggiunto a MusicAmp ha una voce in `~/Library/Application Support/MusicAmp/stats.json`, indicizzata per percorso (o per URL `…cue#track=N` per le tracce dei `.cue`). Ogni voce contiene:

- ascolti, salti, ultimo ascolto, ultimo salto;
- voto (0–5) e data di aggiunta;
- gli ultimi tag letti (titolo, artista, album, artista album, durata), così le playlist intelligenti non devono riaprire i file.

**Regole:**

- **Ascolto:** il brano deve essere suonato davvero per metà della durata o per 4 minuti, la soglia più bassa delle due (come Last.fm). I brani sotto i 30 s devono suonare quasi per intero (90%). Conta il tempo di riproduzione, non la posizione: saltare alla fine non vale, e il tempo in pausa nemmeno. Si conta una volta per ascolto.
- **Salto:** si lascia il brano dopo almeno 3 s, prima della soglia e lontano dalla fine.
- Radio ed episodi di podcast non vengono contati.

Il controller chiama `PlayStats.observe` a ogni tick. Il file si salva 2 s dopo l'ultima modifica e all'uscita.

## Voti

- **Controlli → Rate Current Track**, da ⌥⌘1 a ⌥⌘5; ⌥⌘0 toglie il voto. La conferma appare nel titolo scorrevole.
- Nella playlist, **clic destro → Rating**, anche su più brani selezionati. Lo stesso menu dice quante volte il brano è stato ascoltato e saltato.
- Le stelle compaiono nella riga della playlist prima della durata, nel colore della skin, solo per i brani votati. Si possono nascondere in Impostazioni → Playlist.
- Nella finestra delle playlist intelligenti si vota cliccando le stelle.

I voti stanno nel database di MusicAmp, non nei tag dei file.

## Playlist intelligenti (`SmartPlaylists.swift`, `SmartPlaylistView.swift`)

**Vista → Smart Playlists (⌥⌘S)**; le playlist si avviano anche da **File → Smart Playlists**.

- **Brani considerati:** tutti quelli mai aggiunti a MusicAmp, più la libreria di Musica se è stata caricata nella finestra Libreria.
- **Regole**, da combinare con "tutte" o "almeno una":

| Tipo | Campi | Condizioni |
| --- | --- | --- |
| Testo | titolo, artista, album, artista album, percorso, formato | contiene, non contiene, è, non è, inizia con, finisce con (senza distinguere maiuscole e accenti) |
| Numero | durata (minuti), voto, ascolti, salti | è, non è, maggiore di, minore di |
| Data | ultimo ascolto, data di aggiunta | negli ultimi N giorni, non negli ultimi N giorni (mai = non negli ultimi) |

- **Limite** a N brani, con un ordine: casuale, più o meno ascoltati, voto più alto o più basso, ascoltati di recente o da più tempo, aggiunti di recente, album, artista, titolo.
- Con "Only files that exist" i file spariti vengono nascosti. Il menu "…" ha "Forget Tracks Whose Files Are Gone".
- **Play** sostituisce la playlist e la avvia; **Add to Playlist** aggiunge in coda. Doppio clic su un brano lo suona.
- **Playlist predefinite:** Top 25 Most Played, Recently Played (14 giorni), Recently Added (30 giorni), Top Rated (4–5 stelle), Never Played (50 a caso), Forgotten Favorites (4–5 stelle non ascoltate da 60 giorni), Often Skipped.
- Le playlist sono salvate in `smart-playlists.json`. I nomi sono disponibili anche a Siri e Comandi rapidi ("Play Top Rated in MusicAmp").

Test: `--test-stats` (archivio in memoria, non tocca `stats.json`).

## Mix per somiglianza sonora (Sonic Mix)

**Vista → Sonic Mix (⌥⌘X)**, oppure clic destro su un brano della playlist → **Sonic Radio from This Track** / **Sonic Journey to This Track**, oppure l'azione di Comandi rapidi **Play Sonic Radio** ("Play something like this in MusicAmp").

**Analisi** (`Sonic.swift`), sul Mac, di 45 s di ogni brano a partire da un quarto della durata: circa 0,07 s a brano nella build release, tre brani alla volta. Misura:
- il timbro: 13 coefficienti MFCC da 26 bande mel tra 60 Hz e 8 kHz;
- l'armonia: cromagramma a 12 note e la tonalità più probabile (profili di Krumhansl);
- il tempo in BPM: autocorrelazione dell'andamento degli attacchi, tra 60 e 200 BPM, con preferenza intorno a 120;
- volume, luminosità (baricentro spettrale), rumorosità (spectral flatness), dinamica, forza degli attacchi.

I risultati restano in `sonic.json` e si ricalcolano se il file cambia. Si analizza tutto ciò che MusicAmp conosce: i brani delle statistiche, la libreria di Musica caricata e la playlist.

**Distanza tra due brani:** timbro ed energia, ciascuno normalizzato su tutta la libreria, con lo stesso peso. Poi il tempo: un brano a metà o doppio tempo conta come vicino. Infine la tonalità sul circolo delle quinte, pesata per quanto è sicura la stima.

**Modi:**
- **Sonic Radio:** ogni brano è vicino al precedente e resta vicino a quello di partenza. Non ripete lo stesso artista due volte di fila e sceglie un po' a caso tra i tre più vicini ("Shuffle Again" ne crea un'altra).
- **Sonic Journey:** dal brano A al brano B, attraverso punti intermedi distribuiti in modo uniforme tra i due (il tempo su scala logaritmica). Per ogni punto prende il brano più vicino non ancora usato. Alla fine una passata 2-opt riordina i brani per evitare il percorso a zig-zag.
- **Similar Tracks:** i più vicini, con la percentuale di somiglianza.

**Play** sostituisce la playlist. Se il mix parte dal brano già in ascolto, quel brano continua senza interruzioni e gli altri lo seguono.

Test: `--test-sonic` (tempo ±3%, tonalità, somiglianze, radio, viaggio, riordino); `--sonic-analyze file …` per provarlo su file veri.
