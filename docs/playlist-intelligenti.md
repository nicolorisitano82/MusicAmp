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
