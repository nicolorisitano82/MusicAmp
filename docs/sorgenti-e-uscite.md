# Sorgenti, uscite e lingue

Come MusicAmp suona Apple Music e Spotify, come manda la musica a casse AirPlay, Chromecast, Sonos e UPnP, come traduce i testi e come cambia lingua.

## Apple Music e Spotify (bridge)

> **Non rilasciato: dietro la feature flag `feature.bridge`** (`FeatureFlags.swift`), spenta di default. Senza la flag il menu Sorgente non compare e `useSource` ignora le app esterne. Per provarlo su un Mac:
>
> ```bash
> defaults write com.genomeup.musicamp feature.bridge -bool YES
> ```
>
> poi si riavvia MusicAmp. Con `-bool NO`, o con `defaults delete`, si spegne.

**Controlli → Sorgente** sceglie da dove arriva la musica: la playlist di MusicAmp, l'app Musica o l'app Spotify (`ExternalPlayer.swift`, `ProcessTap.swift`).

Con l'app Musica o Spotify come sorgente:

- MusicAmp apre l'app se serve (senza portarla davanti) e la comanda con AppleScript:
  - play/pausa, brano successivo e precedente, posizione;
  - titolo, artista, album, durata e copertina, letti una volta al secondo.
- L'audio dell'app viene catturato con un **process tap di Core Audio** (macOS 14.4+):
  - `CATapDescription(stereoMixdownOfProcesses:)` sui processi dell'app e sui suoi helper;
  - il tap è privato e silenzia l'app alla fonte (`.mutedWhenTapped`);
  - un aggregate device privato, agganciato all'uscita predefinita, consegna i blocchi a un ring buffer;
  - un `AVAudioSourceNode` li legge nel bus 2 del `deckMixer`.
- Così skin, EQ, visualizzatori, Milkdrop, crossfeed e le uscite di rete valgono anche per Apple Music e Spotify. L'audio resta protetto dall'app: MusicAmp riceve solo il suono che l'app avrebbe riprodotto.
- Il transport della skin passa per il protocollo `Transport`, implementato sia da `AudioEngine` sia da `ExternalPlayer`. Scegliere un brano della playlist riporta MusicAmp come sorgente.

macOS chiede due permessi la prima volta:

1. **Automazione**: MusicAmp comanda Musica o Spotify.
2. **Registrazione audio di sistema**: MusicAmp riceve l'audio dell'app.

Se un permesso manca, la sorgente mostra un messaggio con il punto delle Impostazioni di Sistema da aprire.

## Uscite: più casse AirPlay, Chromecast, Sonos, UPnP

**Controlli → Altoparlanti…**, oppure Impostazioni → Audio → Altoparlanti… (`Outputs.swift`, `LiveStream.swift`, `CastDevices.swift`).

### Lo stream

Tutto parte da uno stream live sulla rete locale (`LiveStream.swift`, `StreamEncoder.swift`), in due formati:

- un tap sul crossfeed, l'ultimo nodo prima del volume, prende l'audio già passato per EQ e crossfeed;
- `/live.flac`: senza perdita, FLAC a 24 bit dall'encoder di macOS. Chi si collega riceve prima `fLaC` e un blocco STREAMINFO senza lunghezza, poi i frame man mano;
- `/live.aac`: AAC-LC a 320 kb/s in frame ADTS, come una radio internet. Lo usano i Sonos e i dispositivi che rifiutano il FLAC;
- ogni ascoltatore si aggancia in diretta;
- se il motore è fermo o in pausa, lo stream manda silenzio, così le casse non si scollegano;
- la copertina del brano è servita a `/cover.jpg` per lo schermo del Chromecast.

**Qualità** (finestra Altoparlanti): "Senza perdita (FLAC)", di default, oppure "Alta (AAC 320 kb/s)".
- Il Chromecast riceve `audio/flac`; se lo rifiuta (`LOAD_FAILED` o `IDLE`/`ERROR`), la sessione ricarica da sola lo stream AAC.
- I renderer UPnP ricevono il FLAC con `protocolInfo audio/flac`; se `SetAVTransportURI` fallisce, ricevono l'AAC.
- I Sonos e il karaoke sulla TV usano sempre AAC 320 kb/s. Anche gli stream HLS sono a 320 kb/s.

**Volume.** Lo stream va sempre a livello pieno: abbassarlo prima della codifica toglieva risoluzione. Con Chromecast o UPnP/Sonos collegati, **il cursore di MusicAmp è il volume del dispositivo**, come in Spotify o Google Home:
- alla connessione il cursore si porta al volume attuale del dispositivo, letto da `RECEIVER_STATUS` o da `GetVolume`, quindi niente salti;
- muovendo il cursore, il dispositivo va allo stesso valore (0–100%). I comandi sono raggruppati ogni 100 ms;
- le notifiche del dispositivo nei 0,8 s successivi vengono ignorate: il Chromecast sale o scende a gradini dell'1% e notifica ogni gradino, e prima questo innescava un ciclo;
- un cambio dal telecomando sposta il cursore;
- quando la trasmissione finisce, anche all'uscita da MusicAmp, il cursore torna al volume del Mac.

AirPlay segue il volume del suo player.

Con "Silenzia questo Mac durante la trasmissione", attivo di default, le casse del Mac tacciono mentre si trasmette.

**Pausa.** Pausa e play di MusicAmp (anche con Musica o Spotify come sorgente) arrivano a tutti i dispositivi:
- Chromecast: `PAUSE` e `PLAY` sulla sessione media;
- AirPlay: il player si mette in pausa;
- UPnP/Sonos: `Pause` e `Play`; un renderer che non sa mettere in pausa una diretta riceve `Stop`, e alla ripresa lo stream viene ricaricato.

Durante la pausa gli stream HLS non ricevono dati, così alla ripresa continuano dallo stesso punto. Gli stream FLAC e AAC continuano invece con silenzio, per non far cadere la connessione.

### AirPlay su più casse

Un `AVPlayer` riproduce la versione HLS dello stream (`/audio/index.m3u8`, segmenti fMP4 AAC) all'indirizzo di rete del Mac, e un `AVRoutePickerView` legato a quel player mostra le casse AirPlay 2 con le caselle: se ne possono scegliere diverse insieme, sincronizzate tra loro. Prima usava lo stream AAC grezzo su `127.0.0.1`: AirPlay si collegava ma non partiva, perché un ricevitore che scarica lo stream da sé non raggiunge il `127.0.0.1` del Mac e il buffer di AirPlay non lavora bene con un flusso senza segmenti. Per una sola cassa basta l'uscita di sistema (Impostazioni → Audio), che ha meno ritardo.

### Chromecast

- Trovati via Bonjour (`_googlecast._tcp`), con nome e modello dal record TXT.
- `CastSession` è un sender Cast v2 minimale:
  - TLS sulla porta 8009, che accetta il certificato autofirmato del dispositivo;
  - messaggi protobuf `CastMessage` con payload JSON, preceduti dalla lunghezza su 4 byte;
  - CONNECT, poi LAUNCH del Default Media Receiver (`CC1AD845`), poi CONNECT al `transportId`;
  - LOAD con `streamType: LIVE`, `audio/aac`, titolo, artista e copertina;
  - PING/PONG ogni 5 s.
- Spegnendo l'interruttore, o uscendo da MusicAmp, il receiver viene fermato (STOP).

### Karaoke sulla TV (Chromecast)

Il pulsante col microfono, nella riga di un Chromecast, manda alla TV un **video** al posto del solo audio (`TVKaraoke.swift`, `LiveHLS.swift`):

- 15 volte al secondo MusicAmp disegna fuori schermo un fotogramma 1280×720 con `ImageRenderer`: copertina sfocata, titolo e artista, riga precedente, riga cantata con le parole che si accendono (la stessa `KaraokeLine` del karaoke a schermo intero), traduzione se attiva, e le due righe successive;
- senza testo sincronizzato mostra copertina grande, titolo, artista e lo stato del testo;
- fotogrammi e audio sono scritti insieme da un `AVAssetWriter` in un HLS live fMP4 (H.264 2,5 Mb/s, AAC 320 kb/s, segmenti di ~2 s, gli ultimi 6 tenuti in memoria), servito a `/tv/index.m3u8`;
- il tempo dei fotogrammi è quello dei campioni audio scritti: testo e suono restano sincronizzati sulla TV anche col buffer del ricevitore;
- il Chromecast lo apre con il Default Media Receiver (`application/x-mpegURL`, `hlsSegmentFormat: fmp4`).

Costo: circa 25 ms di disegno per fotogramma sul main thread e qualche secondo di ritardo in più rispetto all'audio. I testi vengono cercati anche con la finestra dei testi chiusa, e anche per Musica e Spotify come sorgente.

### Sonos e UPnP/DLNA

- Trovati con SSDP: un M-SEARCH per `urn:schemas-upnp-org:device:MediaRenderer:1`, poi lettura della descrizione XML (nome, modello, `controlURL` di AVTransport).
- Per i Sonos il nome è quello della stanza.
- Si riproduce con SOAP `SetAVTransportURI` (con metadati DIDL-Lite) e poi `Play`, e si ferma con `Stop`.
- I Sonos ricevono lo stream con lo schema `x-rincon-mp3radio://`, come una radio.

### Limiti

- Tra ciò che suona il Mac e le casse ci sono alcuni secondi di ritardo, dovuti al buffer dei ricevitori.
- Casse di tipo diverso (AirPlay, Chromecast, Sonos) non sono sincronizzate tra loro.
- Sul Chromecast il titolo è quello del brano all'avvio della trasmissione.
- macOS chiede il permesso **Rete locale** la prima volta.

## Traduzione dei testi

Nei testi e nel karaoke c'è il pulsante 文A (`LyricsTranslation.swift`):

- La traduzione avviene **sul Mac** con il framework Translation.
- La lingua del brano è riconosciuta da sola. La lingua di arrivo si sceglie tra italiano, inglese, spagnolo, francese, tedesco, portoghese, giapponese, coreano e cinese; di default è quella dell'app.
- La riga tradotta compare sotto ogni riga nei testi sincronizzati e nei testi semplici, e sotto la riga corrente nel karaoke.
- Le traduzioni sono salvate in `Lyrics/Translations`.
- Se manca il pacchetto della lingua, macOS chiede di scaricarlo.

## Lingua dell'interfaccia

L'interfaccia è in inglese. **Impostazioni → Generali → Lingua** offre tre scelte:

- Sistema;
- English;
- Italiano.

La scelta vale dal riavvio successivo; il pulsante "Riavvia ora" lo fa subito. Come funziona:

- `AppLanguage.apply()` imposta `AppleLanguages` solo per MusicAmp, all'avvio;
- i testi SwiftUI sono cercati da soli nel `Localizable.strings` della lingua;
- menu e titoli delle finestre AppKit passano per `L()`;
- le traduzioni stanno in `Resources/it.lproj/Localizable.strings`, e la chiave è il testo inglese;
- il titolo scorrevole della skin resta in inglese (font bitmap senza accenti).

## Test

- `MusicAmp --test-outputs`:
  - stream HTTP e frame ADTS;
  - il tono a 1 kHz decodificato dallo stream torna uguale;
  - silenzio a motore fermo e copertina;
  - un AVPlayer muto che suona lo stream (la strada di AirPlay);
  - codifica e decodifica dei messaggi Cast;
  - parsing delle descrizioni Sonos e DLNA.
  
  Con `MUSICAMP_TEST_NET=1` elenca anche le casse trovate in rete, senza riprodurre nulla.
- `MusicAmp --test-tv [frame.png]`:
  - fotogramma 1280×720 dritto, con la riga cantata al centro, e tempo di disegno;
  - stream HLS `tv` (audio + video) e `audio`: playlist live, segmenti con le tracce giuste;
  - un AVPlayer muto apre entrambi dall'indirizzo di rete del Mac.
- `MusicAmp --test-i18n`:
  - stringhe italiane e specificatori di formato;
  - menu e impostazioni coperti;
  - scelta della lingua;
  - lookup nel bundle in italiano, se lanciato con `-AppleLanguages '(it)'`.
- `MusicAmp --test-schedule`: anche il ring buffer del bridge.
