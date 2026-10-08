# Intelligenza artificiale sul Mac

Tutto gira **sul Mac**: niente server e niente account, e nulla esce dal computer. Servono:
- **macOS 26 su Apple Silicon**: è il requisito di MusicAmp dalla 0.5;
- **Apple Intelligence attivo**, per le funzioni che usano il modello linguistico.

La trascrizione funziona anche senza Apple Intelligence, purché la lingua sia supportata dal riconoscimento vocale del sistema.

Codice comune: `AI.swift`.
- **Modello linguistico:** `SystemLanguageModel` di Foundation Models. MusicAmp usa la generazione guidata (`@Generable`), così il modello restituisce direttamente dati strutturati: regole, tag, capitoli. Ogni compito apre una sessione nuova, perché la memoria di lavoro del modello è piccola.
- **Trascrizione:** `SpeechAnalyzer` e `SpeechTranscriber` di macOS 26, con il tempo di ogni parola. Il modello vocale della lingua viene scaricato dal sistema la prima volta.
- **Lingua:** riconosciuta da NaturalLanguage sul testo disponibile (testo della canzone, titolo e descrizione dell'episodio).

Se Apple Intelligence non è disponibile, i pulsanti si disattivano e spiegano il motivo (`AI.unavailableReason`).

## Testi sincronizzati dall'audio

Pannello Testi e karaoke. Quando LRCLIB ha solo il testo semplice, o non ha nulla:
- Il brano viene trascritto sul Mac: una canzone di 4 minuti richiede circa 2,5 s.
- **Con il testo semplice:** le parole sentite vengono allineate alle parole del testo con un allineamento globale (Needleman–Wunsch) e un confronto approssimato (Levenshtein ≥ 0,6). Le parole non riconosciute prendono un tempo intermedio tra le vicine; ogni riga parte dalla sua prima parola. Risultato: un LRC con il tempo di ogni parola.
- **Senza testo:** quello che si sente diventa il testo, diviso in righe alle pause.
- Il risultato va nella cache dei testi, con la fonte "Synced on this Mac" o "Heard on this Mac".
- Di default la sincronizzazione parte da sola quando il pannello o il karaoke mostrano un testo senza tempi. Si spegne nel menu "…" del pannello.
- Misura con `--ai-lyrics-check` su un brano con i tempi veri di LRCLIB: errore mediano 0,39 s, 92% delle righe entro un secondo.

## Podcast intelligenti

Clic destro su un episodio → **Transcribe, Summarise and Find Ads…** (`PodcastInsights.swift`). Serve l'episodio scaricato.
1. **Trascrizione** divisa in frasi, a ogni punto, pausa di un secondo o 40 parole.
2. **Blocchi di circa 700 parole:** per ognuno il modello scrive titolo e riassunto del capitolo, e indica le frasi pubblicitarie (sponsor, codici sconto, promozioni). Le frasi pubblicitarie vicine si uniscono; una pubblicità deve durare almeno 10 s.
3. **Riassunto dell'episodio** con 3–6 punti chiave, scritto partendo dai riassunti dei capitoli.
4. **Durante l'ascolto** le pubblicità trovate si saltano da sole (interruttore "Skip ads" nella finestra), con un avviso nel titolo scorrevole.
5. **Ricerca** nella trascrizione dell'episodio, o in tutti gli episodi trascritti. Un clic su un risultato o su un capitolo riprende l'ascolto da quel punto.

I dati stanno in `Application Support/MusicAmp/Transcripts`. La trascrizione viene salvata anche se la parte del modello fallisce.

## Playlist descritte a parole

Smart Playlists → pulsante Apple Intelligence (`SmartPlaylistAI.swift`).
- Una frase come "calm acoustic songs" o "brani tristi ma ballabili" diventa una playlist intelligente.
- Il modello conosce i campi di MusicAmp, i generi presenti nella libreria, gli umori e gli strumenti. Le istruzioni contengono esempi di traduzione da descrizione a regole.
- **Controlli fissi** dopo la generazione:
  - le regole sono collegate da "e", salvo quando la descrizione dice "o";
  - numeri fuori scala vengono scartati (BPM 40–250, anni 1900–2100);
  - gli umori vengono ricondotti all'elenco;
  - decenni e anni vengono letti dalla descrizione ("80s", "anni '90", "del 2020") e aggiunti se il modello li ha dimenticati.
- Prima di aggiungere la playlist si vedono le regole e il numero di brani trovati. Dopo si modifica come le altre.

## Umore e stile (Sonic Mix)

Fanno parte dell'analisi sonora, versione 2 (`Sonic.swift`):
- **Strumenti e voci:** il classificatore audio di macOS (SoundAnalysis, 303 categorie, senza download) ascolta i 45 s analizzati. Restano fino a quattro etichette musicali presenti in almeno un quinto del tempo: Vocals, Rap, Choir, Electric Guitar, Acoustic Guitar, Piano, Synth, Drums, Strings, Brass, Sax… Nelle canzoni "Spoken" e "Humming" si tolgono quando ci sono già le voci.
- **Umore:**
  - *energia*: volume, forza degli attacchi, tempo, luminosità;
  - *positività*: modo maggiore/minore pesato per la sicurezza della stima, luminosità, tempo;
  - le scale sono tarate su una libreria pop/rock reale (−20…−10 dB, 70…170 BPM);
  - l'incrocio dei due valori dà l'umore: Energetic, Intense, Happy, Chill, Melancholic, Calm, Sad.
  - È una stima: un brano triste in tonalità maggiore può risultare "Happy".
- **In Sonic Mix:** colonne Mood e Instruments, e un filtro per umore per Sonic Radio e Similar Tracks.
- **Nelle playlist intelligenti:** campi Mood e Instruments.

## Riordino dei tag disordinati

Editor dei tag → **Fix with Apple Intelligence…** (`TagFix.swift`).
- Per ogni file, il modello riceve nome, cartelle e tag attuali, e propone artista, titolo e album. Le istruzioni contengono esempi di nomi tipici: download, rip, copie.
- Il numero di traccia viene letto con una regola fissa ("03_", "1-03", "03.").
- L'album resta vuoto quando non è chiaro dalla cartella o dai tag.
- Le proposte si possono modificare. Solo le righe spuntate entrano tra le modifiche in sospeso, e nulla si scrive fino a Save.

## Test

- `--test-ai`: podcast sintetico creato con `say` (introduzione, argomento, pubblicità, argomento), trascritto, diviso in capitoli e riassunto, con la pubblicità trovata nel punto giusto; un nome file disordinato; "80s rock". Senza Apple Intelligence esce con "SKIP".
- `--ai-playlist "testo" …`: genera playlist sulla libreria vera, senza salvarle.
- `--ai-tags file …`: propone i tag di file veri, senza scriverli.
- `--ai-lyrics-check file [lingua]`: misura la precisione dei testi sincronizzati. Stampa solo numeri, mai il testo.
