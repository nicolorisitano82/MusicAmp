# Architettura

MusicAmp è un unico eseguibile Swift (AppKit + SwiftUI + AVFoundation + Metal), senza dipendenze esterne. FFmpeg è opzionale e usato solo come processo esterno.

## Moduli principali

| Area | File | Ruolo |
| --- | --- | --- |
| Controller | `Ctl.swift` | Stato dell'app (impostazioni, playlist, EQ), azioni, menu, persistenza, timer di aggiornamento, aggancio finestre |
| Avvio | `main.swift` | Menu dell'app, AppDelegate, opzioni di debug da riga di comando |
| Skin | `Skin.swift`, `DefaultSkin.swift`, `RetinaSkin.swift`, `SkinCursor.swift`, `FontResolver.swift` | Caricamento `.wsz`, skin di riserva disegnata via codice, `@2x`, cursori `.cur`/`.ani`, font |
| Disegno | `Renderer.swift`, `SkinView.swift` | Framebuffer in coordinate Winamp, vista base delle finestre skinnate |
| Finestre skinnate | `MainView.swift`, `EqView.swift`, `PlaylistView.swift`, `PlaylistTree.swift`, `GenWindow.swift` | Finestra principale, equalizzatore, playlist (piatta o ad albero), finestre secondarie `gen.bmp` |
| Audio | `AudioEngine.swift`, `ReplayGain.swift`, `FFmpeg.swift`, `RadioStream.swift`, `AudioDevices.swift` | Riproduzione, transizioni, loudness, formati extra, radio, uscite |
| Contenuti | `Playlist.swift`, `Library.swift`, `RadioBrowser.swift`, `Podcasts.swift`, `PodcastView.swift`, `Lyrics.swift`, `LyricsView.swift` | Playlist, libreria Musica, catalogo radio, podcast, testi e karaoke |
| Sistema | `NowPlaying.swift`, `MenuBarController.swift`, `TrackNotifier.swift`, `HotKeys.swift`, `Accessibility.swift`, `Artwork.swift` | Tasti multimediali, barra dei menu, notifiche, scorciatoie globali, VoiceOver, copertine |
| Visualizzazione | `MilkdropEEL.swift`, `MilkdropPreset.swift`, `MilkdropRenderer.swift`, `MilkdropHLSL.swift`, `MilkdropView.swift`, `MilkdropBuiltins.swift` | Vedi [milkdrop.md](milkdrop.md) |

`Ctl.shared` è il punto di accesso unico: le viste lo leggono e chiamano le sue azioni. È un `ObservableObject`, quindi le finestre SwiftUI (preferenze, testi, podcast) si aggiornano da sole.

## Finestre skinnate

Ogni finestra Winamp è una `SkinWindow` senza bordi con una sottoclasse di `SkinView`:

1. `render(_:)` disegna in un `Renderer`, cioè un framebuffer RGBA indirizzato in pixel della skin (origine in alto a sinistra, come Winamp).
2. `draw(_:)` ritaglia con i poligoni di `region.txt` e scala il framebuffer alla finestra con interpolazione *nearest neighbour*.
3. Il framebuffer è creato direttamente alla risoluzione dello schermo (fattore Retina × dimensione doppia, massimo 4): i bitmap restano a pixel pieni, il testo vettoriale della playlist è nitido. Vedi [skin-retina.md](skin-retina.md).
4. Mouse e tasti arrivano in coordinate della skin (`point(_:)`): `hitDown`, `hitDrag`, `hitUp`.

### Ridisegno solo quando serve

Ogni vista calcola una `renderSignature` (hash di tutto ciò che mostra). Il timer del controller (30 fps durante la riproduzione, più lento da fermo) chiama `refreshIfChanged()`, che ridisegna solo se la firma è cambiata. Le interazioni dirette (rotella, trascinamenti) chiedono il ridisegno subito.

### Aggancio e Mission Control

- `beginDrag`, `continueDrag` ed `endDrag` spostano le finestre con l'aggancio ai bordi (10 px di default). La finestra principale trascina con sé tutto il gruppo agganciato.
- Le finestre che si toccano diventano finestre figlie (`addChildWindow`) di una radice: la principale, altrimenti l'EQ, altrimenti la prima. Così Mission Control le mostra come una finestra sola. Quelle staccate restano separate (`updateWindowGroups`).
- Anche il pannello Testi partecipa all'aggancio (`dockWindows`). Si trascina dall'intestazione tramite `LyricsWindow.sendEvent`.

## Persistenza

| Cosa | Dove |
| --- | --- |
| Impostazioni | `UserDefaults` (`loadSettings`/`saveSettings` in `Ctl`, chiavi testuali) |
| Dati | `~/Library/Application Support/MusicAmp/`: `Skins/`, `Fonts/`, `Lyrics/`, `Podcasts/`, `Milkdrop/`, `podcasts.json`, `positions.json`, `replaygain.json` |
| Posizioni delle finestre | `pos.*` nelle impostazioni; finestre SwiftUI con `setFrameAutosaveName` |
