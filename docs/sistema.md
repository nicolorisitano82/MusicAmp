# Integrazione con macOS: Comandi rapidi, widget, URL

## Comandi rapidi (App Intents)

`Intents.swift` definisce le azioni che compaiono nell'app Comandi rapidi, in Spotlight e con Siri:

| Azione | Cosa fa |
| --- | --- |
| Play, Pause, Play/Pause, Stop, Next Track, Previous Track | Comandi di riproduzione |
| Set Volume | Volume 0–100 |
| Set Shuffle | Shuffle acceso o spento |
| Get Current Track | Restituisce "Artista — Titolo" |
| Play Files | Sostituisce la playlist con file, cartelle, playlist o `.cue` (oppure li aggiunge) |
| Play Stream URL | Suona una radio http/https o HLS |
| Search and Play | Suona il primo brano della playlist che contiene tutte le parole |
| Set Sleep Timer, Stop at End of Track | Timer di spegnimento (0 minuti lo spegne) |
| Set Alarm, Turn Off Alarm | Sveglia a un orario, una volta o nei giorni impostati |
| Rate Current Track | Da 0 a 5 stelle |
| Play Smart Playlist | Sceglie una playlist intelligente da un elenco |

Sei scorciatoie sono pronte senza configurare nulla (`MusicAmpShortcuts`): Play/Pause, Next Track, Current Track, Sleep Timer, Alarm, Smart Playlist ("Play Top Rated in MusicAmp").

Le azioni girano dentro MusicAmp: se non è aperto, macOS lo avvia e l'azione aspetta la fine dell'avvio (`readyCtl`).

### Metadati senza Xcode

Comandi rapidi trova le azioni in `Contents/Resources/Metadata.appintents`. Xcode lo genera da solo; qui lo fa `build-app.sh`:

1. In release, `Package.swift` aggiunge `-emit-const-values-path` e `-const-gather-protocols-file Scripts/appintents-protocols.json` a MusicAmp e al widget: il compilatore scrive i valori costanti delle intent in `.build/<modulo>.swiftconstvalues`.
2. `xcrun appintentsmetadataprocessor` li trasforma in `Metadata.appintents`, uno per l'app e uno per il widget.

Serve quindi Xcode installato (non solo i Command Line Tools). Il minimo è macOS 14, per i titoli brevi delle scorciatoie e per i pulsanti dei widget.

## Widget "Now Playing"

Estensione WidgetKit `Contents/PlugIns/MusicAmpWidget.appex` (target `MusicAmpWidget`), in tre misure:

- **piccolo:** copertina, titolo, artista, play/pausa, avanzamento;
- **medio:** in più album, tempo, precedente/successivo;
- **grande:** copertina grande.

L'intestazione "MUSICAMP" in verde Winamp mostra lo stato, il conto alla rovescia del timer e l'ora della sveglia. Per le radio compare "● LIVE". Un clic sul widget apre MusicAmp.

**Come comunicano app e widget** (`WidgetBridge.swift`, `Sources/MusicAmpShared`):

- Il widget è in sandbox, come richiesto da macOS. Può leggere solo `~/Library/Application Support/MusicAmp/Widget/`, grazie all'eccezione `temporary-exception.files.home-relative-path.read-only` in `Resources/Widget/Widget.entitlements`.
- MusicAmp scrive lì `state.json` (brano, stato, posizione, durata, timer, sveglia) e la copertina a 300 px (`art-<hash>.png`), poi chiama `WidgetCenter.reloadTimelines`. Lo fa solo se qualcosa di visibile è cambiato: il tempo che scorre da solo non conta, perché il widget lo calcola con `ProgressView(timerInterval:)`.
- I pulsanti sono `AppIntent` dell'estensione, che inviano una notifica distribuita (`com.genomeup.musicamp.command.next`…). È l'unico canale che un processo in sandbox può usare senza gruppi di app. MusicAmp le riceve ed esegue il comando.
- Quando MusicAmp si chiude, lo scrive nello stato, e il widget mostra "MusicAmp isn't running".

Il widget compare nella galleria (clic destro sulla scrivania → Modifica widget) dopo il primo avvio dell'app. `pluginkit -m -p com.apple.widgetkit-extension` deve elencare `com.genomeup.musicamp.widget`.

## Icona del Dock dinamica

`DockIcon.swift`: mentre un brano è caricato l'icona del Dock diventa la sua copertina, nella forma delle icone di macOS, con una barra di avanzamento verde in basso. Senza copertina resta l'icona dell'app con la barra. In pausa l'icona si scurisce e compare il simbolo di pausa; per le radio c'è "● LIVE" al posto della barra. Allo stop torna l'icona normale.

- Si disegna con una vista come `NSDockTile.contentView`, aggiornata una volta al secondo solo durante la riproduzione, e ridisegnata solo quando cambia qualcosa di visibile.
- Si spegne in Impostazioni → General → "Cover and progress in the Dock icon".
- `--dock-snapshot out.png [copertina]` disegna i quattro stati per controllarli.

## URL `musicamp://`

Utili da script, link o dall'azione "Apri URL":

| URL | Effetto |
| --- | --- |
| `musicamp://play`, `pause`, `playpause`, `next`, `previous`, `stop` | Comandi di riproduzione |
| `musicamp://open` | Porta MusicAmp in primo piano |
| `musicamp://volume?level=40` | Volume |
| `musicamp://sleep?minutes=30` | Timer (con `minutes=0` lo spegne) |
| `musicamp://sleep?end=track` | Stop a fine brano |

```bash
open -g "musicamp://next"
```

Con `-g`, MusicAmp riceve il comando senza venire in primo piano, anche quando è stato appena avviato da lì.
