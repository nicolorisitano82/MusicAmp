# Live Video (Beta, branch experimental)

Mentre una canzone suona, Live Video mostra una sequenza di immagini **create su questo Mac da ciò che racconta il testo**, con il testo sotto in stile karaoke. Si apre da Vista → Live Video, a tutto schermo o in finestra, e può andare anche sulla TV tramite Chromecast. Le impostazioni sono in Visualizzazione → Live Video.

## Come funziona

1. **Scene.** Le righe del testo vengono divise in gruppi, un'immagine ciascuno (`LiveVideoStory.groups`):
   - testo sincronizzato: una nuova immagine ogni ~18 s di canto e dopo ogni pausa strumentale di almeno 8 s;
   - testo semplice: circa quattro righe per immagine (prima, se si può, il testo viene sincronizzato dall'audio);
   - al massimo 14 immagini per canzone;
   - senza testo: quattro scene ispirate al titolo.
2. **Storyboard: un lettore e un regista.** Apple Intelligence lavora sul Mac con i filtri `permissiveContentTransformations`, pensati per rielaborare testo fornito dall'utente; quelli predefiniti rifiutavano 13 canzoni pop su 23. La temperatura è bassa (0,3), per risultati fedeli e stabili.
   - **Lettore, intestazione.** Legge il testo e scrive con parole sue, senza mai citarlo né tradurlo:
     - chi parla a chi;
     - i personaggi come donne e uomini, con età, capelli e abiti;
     - il mondo concreto della canzone: luoghi, oggetti, epoche ed eventi. Un riferimento a persone, film o canzoni reali diventa il loro look e la loro epoca, mai il nome (es. "glamour del muto anni '20"), e lo stesso vale per il titolo;
     - mood e tema.
   - **Lettore, appunti per parte.** Con l'intestazione come contesto, per ogni gruppo di righe scrive cosa dicono, in modo semplice e letterale. Le righe saltate o ricopiate dal formato vengono rifatte una per una.
   - **Regista.** Il modello impersona un regista di videoclip e vede solo gli appunti, mai il testo. Decide:
     - il concept e l'arco (inizio, sviluppo, culmine, finale);
     - luoghi che seguono la storia e cambiano, nessuno più di due volte;
     - inquadrature varie: campo lungo, piano medio, primo piano, dettaglio, folla.

     Per ogni parte scrive direttamente l'inquadratura per l'illustratore, con gli stessi personaggi e lo stesso mood. Le metafore diventano azioni che ne conservano il senso ("guerra" tra rivali = scontro teso in un ufficio, non un campo di battaglia). Scrive solo ciò che vede la macchina da presa. Un esempio svolto su una canzone inventata gli mostra il livello di concretezza.
   - Una parte rifiutata riceve una scena di riserva legata al tema. Ogni prompt è accorciato a 32 parole, perché Stable Diffusion legge circa 75 token.
   - Prova su 30 canzoni in cache: nessun rifiuto, 15–40 s per storyboard.
   - Strumenti: `--livevideo-board <file testo in cache> <titolo> <artista>` stampa uno storyboard (con `MUSICAMP_BOARD_DEBUG=1` anche gli appunti del lettore); `--livevideo-paint <board.json> <cartella>` lo dipinge.
3. **Immagini.** Stable Diffusion gira in Core ML con il modello scelto in sideload:
   - stile: **Automatico** (predefinito) lascia scegliere al regista il look adatto. Cinematografico per vita notturna, fama, città e dramma; acquerello per toni delicati, nostalgici e di campagna; olio per atmosfere classiche e romantiche; illustrazione per toni giocosi e fantastici. In alternativa lo stile si fissa a mano;
   - nel prompt la scena viene prima e lo stile dopo, seguito dal mood: Stable Diffusion dà più peso alle prime parole, e con lo stile in testa la scena si perdeva (personaggi e luoghi spariti);
   - il seed deriva dalla canzone, quindi le immagini sono riproducibili e coerenti tra loro;
   - 20 passi DPM-Solver++, guidance 7,5 e un prompt negativo fisso;
   - ogni scena nasce dal testo. Partire dall'immagine precedente (img2img) è stato provato e scartato: tutte le scene finivano per somigliare alla prima.
4. **Prima il video, poi la canzone** ("Crea tutto il video prima che parta la canzone", attivo di default). Con Live Video aperto, un brano che parte senza video pronto si ferma a 0:00. Il pannello "Preparo il video" mostra lo storyboard e poi l'immagine N di M; a video pronto la canzone riparte dall'inizio. "Riproduci subito", oppure Play, fa partire la canzone senza aspettare. Con SDXL 10 immagini richiedono circa 3 minuti; il brano successivo si prepara mentre suona quello attuale, quindi di solito non aspetta.
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
| SDXL base iOS, split_einsum, 4 bit (predefinito) | 2,9 GB | 768 px | 16,6 s per immagine sul Neural Engine |
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
