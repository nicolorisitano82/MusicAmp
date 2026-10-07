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
- Un tap sul `mainMixer` alimenta:
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

Se `ffmpeg` è installato (per esempio con Homebrew), i formati non nativi (Ogg, Opus, WavPack, TTA…) sono decodificati da un processo esterno che emette `f32le` su una pipe, con controllo del flusso. I metadati arrivano da `ffprobe`. Anche le radio Ogg/Opus passano da FFmpeg.

## Radio internet

- **Icecast/SHOUTcast:** `RadioStream` usa URLSession, rimuove i metadati ICY, poi AudioFileStream e AVAudioConverter producono buffer PCM. Ci sono pre-buffer configurabile, gestione dei buchi di dati e fino a 5 riconnessioni.
- **HLS:** riprodotto con AVPlayer; i titoli arrivano da `AVPlayerItemMetadataOutput`.
- I `.pls`/`.m3u` remoti vengono risolti. Il catalogo viene da radio-browser.info (`RadioBrowser.swift`).

## Podcast e audiolibri

- Gli episodi remoti sono riprodotti con AVPlayer (ricerca, velocità, intonazione con `.timeDomain`); quelli scaricati passano dal motore.
- La posizione viene salvata ogni 5 s e alla pausa in `positions.json`, per i file `m4b`/`aa`/`aax` o più lunghi di 20 minuti.
- Velocità e intonazione: generale, per podcast e per singolo show.

Nota: radio HLS ed episodi in streaming non attraversano il grafo AVAudioEngine, quindi né il visualizzatore né Milkdrop ricevono quell'audio.
