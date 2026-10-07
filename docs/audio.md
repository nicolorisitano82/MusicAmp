# Motore audio

Codice: `AudioEngine.swift`, con `ReplayGain.swift`, `FFmpeg.swift`, `RadioStream.swift`, `AudioDevices.swift`.

## Grafo AVAudioEngine

```
deck A: AVAudioPlayerNode → converter (AVAudioMixerNode) → gain (AVAudioUnitEQ, 0 bande) ─┐
deck B: AVAudioPlayerNode → converter (AVAudioMixerNode) → gain (AVAudioUnitEQ, 0 bande) ─┤
                                                                                         ↓
                                         deckMixer → AVAudioUnitTimePitch → EQ (10 bande) → mainMixer → uscita
```

- I deck sono due, per gapless e crossfade. Al cambio di formato si ricollega solo `player → converter`: ricollegare più a valle a motore avviato causa l'errore -10868.
- Il guadagno per brano (ReplayGain) sta nel nodo `gain` di ogni deck.
- `TimePitch` è in bypass a velocità 1× e intonazione 0.
- L'EQ a 10 bande usa le frequenze di Winamp; i preset `.eqf`/`.q1` hanno 0x1F = 0 dB.
- Un tap sull'uscita dell'EQ, prima del volume, alimenta:
  - il visualizzatore della skin: FFT vDSP 1024 punti, 75 colonne logaritmiche da 40 Hz a 16 kHz, più l'oscilloscopio;
  - Milkdrop, quando la sua finestra è aperta: 576 campioni stereo, spettro a 512 bin, energie di bassi (20–250 Hz), medi (250–2.000 Hz) e alti (2–16 kHz).

## Transizioni

- **Gapless:** il brano successivo viene programmato sull'altro deck all'host time esatto della fine del corrente (`armOther`, `swapToOther`).
- **Crossfade:** dissolvenza a potenza costante guidata da un timer (`tickTransition`). La durata si sceglie nelle preferenze.
- `nextProvider`/`onAdvance` chiedono al controller qual è il prossimo brano, rispettando coda, shuffle e ripetizione.

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
