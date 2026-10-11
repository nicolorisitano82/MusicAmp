# Live Video (Beta, branch experimental)

Mentre una canzone suona, Live Video mostra una sequenza di immagini **create su questo Mac da ciò che racconta il testo**, con il testo sotto in stile karaoke. Si apre da Vista → Live Video, a tutto schermo o in finestra, e può andare anche sulla TV tramite Chromecast. Le impostazioni sono in Visualizzazione → Live Video.

## Requisiti di sistema

- Mac con **Apple Silicon** e **macOS 26**.
- **Apple Intelligence attivo** (Impostazioni di Sistema → Apple Intelligence e Siri): scrive lo storyboard.
- Un **modello di immagini**, scaricato una volta dalle Impostazioni di MusicAmp o aggiunto a mano:

| Modello | Memoria consigliata | Disco | Immagine | Tempo per immagine (M3 Max) | Video di una canzone (7–8 immagini) |
| --- | --- | --- | --- | --- | --- |
| **SDXL completo** (predefinito con 32 GB) | 32 GB | 6,6 GB | 1024 px | ~45 s (GPU) | ~6–8 min |
| SDXL compresso | 16 GB | 2,9 GB | 768 px | ~17 s (Neural Engine) | ~2,5 min |
| SD 2.1 | 8 GB | 1,1 GB | 512 px | ~4 s (GPU) | ~40 s |

- **Prima immagine dopo l'installazione o un aggiornamento:** Core ML prepara il modello per il chip. Servono circa 2 minuti per SDXL compresso; per SDXL completo il tempo non è stato misurato a parte.
- **Mentre dipinge:** la GPU o il Neural Engine lavorano a pieno, quindi ventole e consumo salgono.
- **Spazio per le immagini:** circa 2 MB per canzone, nella cache `Application Support/MusicAmp/LiveVideo` (si svuota dalle Impostazioni).
- **Rete:** serve solo per scaricare il modello e il testo della canzone; storyboard e immagini sono fatti sul Mac.

Su Mac più lenti (M1, M2 base) i tempi possono essere da 2 a 4 volte più lunghi: lì conviene SDXL compresso o SD 2.1.

## Come funziona

Il modello di Apple Intelligence sul Mac è piccolo: rende bene a scegliere e a riempire campi brevi, male a scrivere prosa lunga e coerente. Per questo **l'AI sceglie e il codice costruisce** (`LiveVideoPlan.swift`).

1. **Struttura della canzone, in codice.**
   - Le righe che tornano in sequenze di almeno due formano il ritornello (la sequenza ripetuta più spesso) o un refrain.
   - Le parti tra un ritornello e l'altro sono strofe, divise su righe vuote, pause di almeno 5 s, al massimo 8 righe.
   - Una strofa dopo il secondo ritornello è il bridge, l'ultima è il finale.
   - Ogni sezione è una scena; le sezioni che si ripetono condividono un'immagine. Bastano così 6–10 immagini invece di 10–14.
2. **Lettore** (2 chiamate, con i filtri `permissiveContentTransformations`, temperatura 0,3):
   - dall'intero testo, con parole sue e senza citarlo: chi parla a chi, personaggi, mondo concreto (i riferimenti a persone reali diventano look ed epoca), mood e tema;
   - per ogni parte distinta, cosa dice in modo letterale.
3. **Regista** (1 chiamata). Vede solo gli appunti, mai il testo. Sceglie:
   - il cast: A ed eventualmente B, donne o uomini con età, capelli e abiti;
   - da 3 a 5 luoghi e lo stile del video;
   - per ogni parte i **campi** dell'inquadratura: chi (A, B, A+B, folla, nessuno), azione (6 parole), luogo (numero), inquadratura (campo lungo, piano medio, primo piano, dettaglio, folla) e luce.

   Il parser accetta anche le piccole deviazioni dal formato: campi senza etichetta, "A & B", "Close up", numerazioni ripetute.
4. **Prompt, in codice.**
   - Ordine: soggetto (inquadratura e persone con il loro aspetto fisso), azione, luogo, luce, stile, mood; entro circa 60 parole, perché Stable Diffusion ne legge circa 75 token e pesa di più le prime.
   - Prompt negativo adatto all'inquadratura (niente primi piani nei campi lunghi).
   - Un aspetto senza "donna" o "uomo" viene completato, altrimenti verrebbe disegnato come una pettinatura.
5. **Controllo con Vision** (`LiveVideoCheck.swift`). Ogni immagine viene verificata:
   - persone presenti, o la folla se richiesta;
   - inquadratura coerente (un campo lungo non è un viso che riempie il quadro, un primo piano ha un viso);
   - luogo, se è nel vocabolario di Vision (palco, treno, strada…, 1.303 etichette).

   Se non passa, viene ridipinta una volta con un altro seed e si tiene la migliore.
6. **Montaggio, in codice:**
   - lo zoom segue l'inquadratura: si allontana sui campi lunghi, si avvicina sui primi piani;
   - quando il ritornello torna, la stessa immagine riappare più stretta e decentrata, come una nuova inquadratura della stessa scena;
   - la dissolvenza si fa solo al cambio di scena.

La ricetta precedente (lettore e regista che scrivono i prompt in prosa, `LiveVideoStory`) resta disponibile con `MUSICAMP_LV_RECIPE=director`, per i confronti: `MusicAmp --livevideo-bench <n> <cartella>` la mette a confronto con quella attuale su canzoni ascoltate sul Mac.

3. **Immagini.** Stable Diffusion gira in Core ML con il modello scelto in sideload:
   - stile: **Automatico** (predefinito) lascia scegliere al regista il look adatto. Cinematografico per vita notturna, fama, città e dramma; acquerello per toni delicati, nostalgici e di campagna; olio per atmosfere classiche e romantiche; illustrazione per toni giocosi e fantastici. In alternativa lo stile si fissa a mano;
   - nel prompt la scena viene prima e lo stile dopo, seguito dal mood: Stable Diffusion dà più peso alle prime parole, e con lo stile in testa la scena si perdeva (personaggi e luoghi spariti);
   - il seed deriva dalla canzone, quindi le immagini sono riproducibili e coerenti tra loro;
   - 20 passi DPM-Solver++, guidance 7,5 e un prompt negativo fisso;
   - ogni scena nasce dal testo. Partire dall'immagine precedente (img2img) è stato provato e scartato: tutte le scene finivano per somigliare alla prima.
4. **Prima immagine, poi la canzone** ("Aspetta la prima immagine prima di far partire la canzone", attivo di default).
   - Con Live Video aperto, un brano che parte senza immagini si ferma a 0:00. Il pannello "Preparo il video" mostra lo storyboard e poi l'immagine.
   - Appena è pronta la prima, la canzone riparte dall'inizio. Con SDXL completo serve circa 1 minuto (storyboard e prima immagine).
   - Le altre immagini arrivano mentre la canzone suona, nell'ordine in cui servono. Se una non è ancora pronta resta quella precedente.
   - "Riproduci subito", oppure Play, salta l'attesa.
   - Il brano successivo si prepara per intero mentre suona quello attuale, quindi di solito parte completo.
5. **Ordine.** Le immagini vengono create nell'ordine in cui si vedranno:
   - finché non c'è la prima immagine si vede la copertina sfocata;
   - una scena ancora in lavorazione mostra l'ultima immagine pronta;
   - finita la canzone, prepara il brano successivo della playlist.
6. **Cache.** `Application Support/MusicAmp/LiveVideo/<chiave>/` contiene `board.json` e `sceneN.jpg`. La chiave dipende da modello, stile, canzone e testo. Al secondo ascolto le immagini sono subito pronte.
7. **Visualizzazione** (`LiveVideoFrame`):
   - ogni immagine si muove con uno zoom lento;
   - al cambio di scena, sulla prima riga della scena, c'è una dissolvenza di 1,2 s;
   - sotto c'è la riga cantata (la `KaraokeLine` del karaoke) con la traduzione, se attiva;
   - in un angolo il titolo e, mentre lavora, lo stato ("Dipingo 3 di 10…").

   Sulla TV, se è attivo "Mostra sulla TV", `TVKaraoke` disegna questo fotogramma al posto del karaoke semplice.

## Modelli (sideload, nulla incluso nell'app)

La pipeline è la parte Swift di [apple/ml-stable-diffusion](https://github.com/apple/ml-stable-diffusion) (MIT), copiata in `Sources/StableDiffusion`: niente Python, niente programmi esterni, niente dipendenze di pacchetto.

I modelli sono le conversioni Core ML di Apple su Hugging Face e stanno in `Application Support/MusicAmp/Models`. Si scaricano dalle Impostazioni oppure si aggiungono con "Scegli modello…", da una cartella o da uno .zip che `ditto` scompatta.

| Modello | Download | Immagine | Su M3 Max |
| --- | --- | --- | --- |
| SDXL base, original (predefinito sui Mac con 32 GB) | 6,6 GB | 1024 px | ~45 s per immagine sulla GPU |
| SDXL base iOS, split_einsum, 4 bit | 2,9 GB | 768 px | 16,6 s per immagine sul Neural Engine |
| SD 2.1 base, original, 6 bit | 1,1 GB | 512 px | 4,3 s per immagine sulla GPU |

**Caricamento del modello:**
- dopo l'installazione o un aggiornamento di MusicAmp, Core ML impiega circa 2 minuti a preparare SDXL per il Neural Engine ("Preparo il modello di immagini…");
- poi il modello si carica in circa 1 s;
- mentre Live Video è in uso SDXL tiene circa 3 GB di memoria, liberati dopo 3 minuti di inattività.

**Licenze:**
- Stable Diffusion 2.1 e SDXL: CreativeML Open RAIL++-M;
- SDXL-Turbo e SD-Turbo sono esclusi: la loro licenza è non commerciale e non esistono in Core ML.

## Perché non Image Playground

`ImageCreator` (Image Playground) su macOS 27 risponde `notSupported` ed è deprecato a favore della finestra interattiva. In più offre solo tre stili cartoon e non permette di fissare il seed.

## Test

`MusicAmp --test-livevideo [frame.png]` controlla:
- raggruppamento delle righe, chiavi della cache e tempi delle scene;
- la dissolvenza;
- il fotogramma disegnato sopra un'immagine.

Con `MUSICAMP_TEST_SD=1` scrive anche uno storyboard con Apple Intelligence e dipinge un'immagine con il modello installato; con `MUSICAMP_TEST_SD_ALL=1` le dipinge tutte.

`MusicAmp --livevideo-diagnose` prova lo storyboard su tutti i testi in cache sul Mac. Stampa per ogni canzone righe, gruppi, esito o errore esatto, scene di riserva e tempi, ma mai i testi.
