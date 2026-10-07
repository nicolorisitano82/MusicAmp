# Motore audio

Codice: `AudioEngine.swift`, con `ReplayGain.swift`, `FFmpeg.swift`, `RadioStream.swift`, `AudioDevices.swift`.

## Grafo AVAudioEngine

```
deck A: AVAudioPlayerNode → converter (AVAudioMixerNode) → gain (AVAudioUnitEQ, 0 bande) ─┐
deck B: AVAudioPlayerNode → converter (AVAudioMixerNode) → gain (AVAudioUnitEQ, 0 bande) ─┤
                                                                                         ↓
                       deckMixer → AVAudioUnitTimePitch → EQ (10 bande) → EQ parametrico (16 bande) → mainMixer → uscita
```

- I deck sono due, per gapless e crossfade. Al cambio di formato si ricollega solo `player → converter`: ricollegare più a valle a motore avviato causa l'errore -10868.
- Il guadagno per brano (ReplayGain) sta nel nodo `gain` di ogni deck.
- `TimePitch` è in bypass a velocità 1× e intonazione 0.
- L'EQ a 10 bande usa le frequenze di Winamp; i preset `.eqf`/`.q1` hanno 0x1F = 0 dB.
- L'EQ parametrico (`peq`) segue l'EQ di Winamp: vedi [EQ parametrico e profili cuffie](#eq-parametrico-e-profili-per-cuffie).
- Un tap sull'uscita dell'EQ parametrico, prima del volume, alimenta:
  - il visualizzatore della skin: FFT vDSP 1024 punti, 75 colonne logaritmiche da 40 Hz a 16 kHz, più l'oscilloscopio;
  - Milkdrop, quando la sua finestra è aperta: 576 campioni stereo, spettro a 512 bin, energie di bassi (20–250 Hz), medi (250–2.000 Hz) e alti (2–16 kHz).

## Transizioni

- **Gapless:** il brano successivo viene programmato sull'altro deck all'host time esatto della fine del corrente (`armOther`, `swapToOther`).
- **Crossfade:** dissolvenza a potenza costante guidata da un timer (`tickTransition`). La durata si sceglie nelle preferenze.
- `nextProvider`/`onAdvance` chiedono al controller qual è il prossimo brano, rispettando coda, shuffle e ripetizione.

## Bit-perfect

**Impostazioni → Audio → Bit-perfect** porta l'uscita alla frequenza di ogni brano, per non ricampionare.

- `AudioDevices.swift` legge le frequenze supportate dal dispositivo (`kAudioDevicePropertyAvailableNominalSampleRates`) e la cambia con `kAudioDevicePropertyNominalSampleRate`.
- Scelta della frequenza (`bestRate`): quella esatta del file; altrimenti un multiplo intero (44,1 → 88,2/176,4 kHz); altrimenti la più bassa sopra; altrimenti la più alta disponibile.
- Il grafo interno viene ricostruito alla frequenza del brano (`rebuildChain(rate:)`), così nessun nodo ricampiona.
- La frequenza originale del dispositivo viene ripristinata quando si spegne l'opzione o si esce (`restoreDeviceRate`).
- Brani a frequenze diverse non possono essere gapless: tra i due c'è il cambio di frequenza.
- Bit-perfect vero richiede anche volume al 100%, i due EQ spenti, ReplayGain spento, velocità 1× e bilanciamento al centro. Le impostazioni mostrano cosa lo impedisce (`bitPerfectIssues`).

## EQ parametrico e profili per cuffie

**Impostazioni → Cuffie** (`ParametricEQ.swift`, `HeadphonesView.swift`):

- Fino a 16 filtri: picco, shelf basso e alto, passa-basso, passa-alto, con frequenza, guadagno e Q, più un preamp. Il grafico mostra la risposta calcolata con le formule dei biquad RBJ.
- L'EQ usa `AVAudioUnitEQ`, che vuole la larghezza in ottave: BW = 2·asinh(1/2Q)/ln 2.
- **AutoEq:** l'indice di [AutoEq](https://github.com/jaakkopasanen/AutoEq) (MIT, circa 8.850 cuffie e auricolari) viene scaricato da GitHub e tenuto in cache una settimana in `Application Support/MusicAmp/AutoEq`. Il profilo scelto (`… ParametricEQ.txt`) viene scaricato e salvato in cache.
- I profili si importano ed esportano nel formato testo di Equalizer APO (`Preamp:` e `Filter n: ON PK Fc … Gain … Q …`).
- **Auto** imposta il preamp più alto che non fa saturare il picco della curva.

## File CUE

Un album in un solo file (FLAC, APE, WavPack, WAV…) con un `.cue` (`CueSheet.swift`):

- Aggiungendo il `.cue` o la sua cartella, la playlist mostra un brano per traccia. Il file audio indicizzato non viene aggiunto anche da solo.
- Ogni traccia ha un URL stabile, `file:///…/album.cue#track=3`: si salva e si ripristina con la playlist.
- **Parsing:** UTF-8 (con o senza BOM) oppure Windows-1252. Si usa `INDEX 01` (o `INDEX 00` se manca); una traccia finisce dove inizia la successiva nello stesso file.
- Se il file citato non c'è (il `.cue` dice `.wav` ma c'è il `.flac`), si cerca lo stesso nome con un'altra estensione audio, poi l'unico file audio della cartella.
- Il deck suona solo il segmento (`segStart`/`segEnd` in frame), e il passaggio alla traccia dopo è gapless. Con FFmpeg si usano `-ss`/`-t`.
- Titoli e artisti vengono dal `.cue`; copertina e ReplayGain dal file audio.

## Timer di spegnimento e sveglia

`SleepAlarm.swift` (`Scheduler`), **Impostazioni → Timer** e **Controlli → Timer e sveglia**:

- **Timer:** da 5 minuti a 3 ore, oppure "fine del brano". Alla fine: pausa, stop, chiudi MusicAmp o metti in stop il Mac (`pmset sleepnow`). La dissolvenza in uscita (5–120 s) scala l'uscita tramite `Ctl.fadeScale`, senza toccare il volume impostato.
- **Fine del brano con gapless:** se il motore è già passato al brano dopo, quello si ferma e torna all'inizio.
- **Sveglia:** ora, giorni della settimana (nessun giorno = una volta sola), cosa suonare (la playlist dal brano corrente, oppure una radio o un brano della playlist), volume e dissolvenza in entrata fino a 5 minuti. Senza nulla da suonare suona il suono di sistema "Glass". C'è la ripetizione dopo 9 minuti.
- Il prossimo orario si calcola nel fuso locale, anche al cambio dell'ora legale (`nextOccurrence`). Una sveglia persa con il Mac in stop suona se MusicAmp se ne accorge entro 10 minuti.
- **Limiti:** MusicAmp deve essere aperto e il Mac sveglio. Mentre la sveglia è attiva un'attività di processo impedisce lo stop per inattività (opzione "Keep the Mac awake"); a coperchio chiuso il Mac dorme comunque.

## ReplayGain

1. Si leggono i tag ReplayGain nei primi e negli ultimi 512 KB del file (i caratteri NUL vengono rimossi). Per Opus si usano i tag R128: valore/256 + 5 dB.
2. Senza tag, e se l'opzione è attiva, si misura la loudness EBU R128 (filtro K, BS.1770) con riferimento −18 LUFS.
3. I risultati sono salvati in cache in `replaygain.json`. C'è un preamp e la protezione dal clipping.

## Formati extra con FFmpeg

I formati non nativi (Ogg Vorbis, Opus, FLAC in Ogg/Matroska, WavPack, APE, TTA, Musepack, WMA, DSD, TAK, AC-3/DTS…) sono decodificati da un processo `ffmpeg` che emette `f32le` su una pipe, con controllo del flusso. I metadati arrivano da `ffprobe`.

- **FFmpeg incluso.** `MusicAmp.app/Contents/Helpers` contiene `ffmpeg` e `ffprobe` 9.0.2, compilati da `Scripts/build-ffmpeg.sh` dai sorgenti di ffmpeg.org:
  - solo LGPL 2.1+, senza componenti GPL o non liberi;
  - solo decoder e demuxer audio, senza rete;
  - statici, universali arm64 + x86_64, circa 7 MB ciascuno.
  - Licenza e riga di configurazione stanno in `Contents/Resources/FFmpeg/` e nel DMG.
  - `build-app.sh` lo compila la prima volta, in circa un minuto, e poi lo riusa da `vendor/ffmpeg` (ignorata da git).
- **Ordine di ricerca:** prima l'FFmpeg incluso, poi `MUSICAMP_FFMPEG_DIR`, poi Homebrew/MacPorts/`PATH`.
- **Radio Ogg/Opus:** lo stream lo scarica `StreamFeeder` con URLSession, quindi col TLS di sistema, e lo scrive nello standard input di ffmpeg. Per questo il binario non ha bisogno di http/https. Se lo stream si interrompe, il motore si riconnette come per le altre radio.

## Radio internet

- **Icecast/SHOUTcast:** `RadioStream` usa URLSession, rimuove i metadati ICY, poi AudioFileStream e AVAudioConverter producono buffer PCM. Ci sono pre-buffer configurabile, gestione dei buchi di dati e fino a 5 riconnessioni.
- **HLS:** client nativo (`HLSStream.swift`, `HLSFetcher`).
  - Playlist master: sceglie la variante audio migliore fino a 320 kb/s.
  - Playlist media: segue la sequenza; in diretta parte tre segmenti prima della fine.
  - Segmenti MPEG-TS: demux PAT → PMT → PES, AAC ADTS o MP3.
  - Segmenti "packed audio": tag ID3 + ADTS/MP3.
  - Titoli: dai frame ID3 `TPE1`/`TIT2`, sia nel TS sia nel packed.
  - L'audio grezzo va allo stesso decoder di `RadioStream`, quindi HE-AAC v1/v2 è supportato.
  - Solo i casi non gestiti tornano ad AVPlayer, senza EQ né visualizzatore: segmenti cifrati, fMP4 (`EXT-X-MAP`), AAC LATM.
- I `.pls`/`.m3u` remoti vengono risolti. Il catalogo viene da radio-browser.info (`RadioBrowser.swift`).

## Podcast e audiolibri

- **Episodi remoti** (`RemoteTap.swift`):
  - AVPlayer si occupa di rete, decodifica, ricerca e velocità con l'algoritmo `.timeDomain`, adatto al parlato;
  - un `MTAudioProcessingTap` consegna ogni blocco già accelerato al deck del motore e silenzia l'uscita di AVPlayer;
  - così EQ, bilanciamento, uscita scelta, visualizzatore e Milkdrop valgono anche in streaming;
  - finché il motore non ha agganciato il flusso, AVPlayer resta udibile.
- **Episodi scaricati:** suonano dal motore come i file locali.
- La posizione viene salvata ogni 5 s e alla pausa in `positions.json`, per i file `m4b`/`aa`/`aax` o più lunghi di 20 minuti.
- Velocità e intonazione: generale, per podcast e per singolo show.

Il tap di analisi (visualizzatore e Milkdrop) sta all'uscita dell'EQ, prima del volume: come in Winamp, la visualizzazione si muove anche a volume zero.
