# Milkdrop

MusicAmp ha un motore Milkdrop nativo, in Swift + Metal, compatibile con i preset `.milk` di Milkdrop 1.x e 2.x. Si apre con ⌥⌘M o dal menu Vista.

| File | Contenuto |
| --- | --- |
| `MilkdropEEL.swift` | Linguaggio delle equazioni (NS-EEL): parser e compilatore in closure |
| `MilkdropPreset.swift` | Lettura dei `.milk`, valori di default, runtime per-frame, per-pixel, onde e forme |
| `MilkdropRenderer.swift` | Pipeline Metal, ambiente degli shader MD2, rumore, blur, dissolvenza |
| `MilkdropHLSL.swift` | Traduttore degli shader HLSL di Milkdrop 2 in Metal Shading Language |
| `MilkdropView.swift` | Finestra, tasti, menu, libreria dei preset, compilazione in background |
| `MilkdropBuiltins.swift` | 8 preset originali inclusi (pubblico dominio) |

## Preset

I preset sono file INI: valori base (`fDecay=0.98`, `zoom=1.01`…), righe di codice numerate (`per_frame_init_N`, `per_frame_N`, `per_pixel_N`), fino a 4 onde (`wavecode_N_*`, `wave_N_init/per_frame/per_point*`) e 4 forme (`shapecode_N_*`, `shape_N_init/per_frame*`), più gli shader MD2 `warp_N` e `comp_N`, righe che iniziano con un backtick.

- I nomi del file sono convertiti in quelli delle equazioni (`fDecay` → `decay`, `nWaveMode` → `wave_mode`, …; tabella `MilkPreset.keyMap`).
- Ogni fotogramma riparte dai valori base del preset. `q1`…`q32` partono dai valori lasciati dal codice di init, mentre le variabili dell'utente persistono.
- Cartella dei preset dell'utente: `~/Library/Application Support/MusicAmp/Milkdrop`, sottocartelle comprese. Le texture dei preset si cercano nella cartella del preset, in una sua sottocartella `textures/` o in `Milkdrop/textures`; se mancano si usa del rumore.

## Linguaggio delle equazioni (NS-EEL)

- Istruzioni separate da `;`, variabili `double` senza distinzione tra maiuscole e minuscole, `= += -= *= /= %= ^= |= &=`.
- Aritmetica, potenza `^`, confronti, `&&`/`||`/`!`, ternario `?:`, operatori bit a bit.
- Funzioni: `sin cos tan asin acos atan atan2 sqr sqrt invsqrt pow exp log log10 abs min max sign int floor ceil fmod rand above below equal if band bor bnot sigmoid exec2 exec3 loop while megabuf gmegabuf`.
- Come in Milkdrop, la divisione per zero dà 0, `sqrt` usa il valore assoluto e i confronti hanno una tolleranza di 0,00001.
- Il codice è compilato una volta in un albero di closure su un registro piatto di `double`. Un errore di sintassi non blocca le istruzioni successive.

## Pipeline per fotogramma (Metal)

1. **Warp.** L'immagine precedente viene disegnata attraverso una mesh di 48×36 celle. Le coordinate di texture di ogni vertice vengono dalla formula di Milkdrop (zoom con `zoomexp`, stiramento, warp animato, rotazione, traslazione, correzione d'aspetto); il codice per-pixel gira una volta per vertice. Poi:
   - i preset MD1 moltiplicano per `decay`;
   - i preset MD2 eseguono il proprio warp shader, che di solito applica da sé l'attenuazione.
2. **Disegni**, nella stessa texture di feedback, così vengono deformati nei fotogrammi successivi:
   - vettori di movimento;
   - forme personalizzate (anche texturizzate e a istanze multiple);
   - onde personalizzate;
   - onda principale (8 modalità);
   - darken center;
   - bordi esterno e interno.
3. **Blur**, solo se uno shader lo usa: tre livelli a ½, ¼ e ⅛ della risoluzione (`MPSImageBilinearScale` + `MPSImageGaussianBlur`, rgba16Float).
4. **Composizione**:
   - con il comp shader MD2 del preset;
   - oppure, per MD1, con video echo (zoom e orientamento), gamma e gli effetti brighten/darken/solarize/invert.

La texture di feedback è `bgra8Unorm` alla risoluzione della finestra.

### Cambio di preset

La compilazione avviene in background (`MilkdropRenderer.prepare` su una coda seriale); il preset corrente continua finché il nuovo è pronto. Poi c'è una dissolvenza di 2,7 s: ogni passo (warp, disegni, composizione) è disegnato da entrambi i preset, e il nuovo entra con un fattore di blend costante (`setBlendColor`).

### Audio

`bass`, `mid` e `treb` valgono circa 1 sulla media e superano 1 nei picchi: l'energia istantanea è divisa per una media lunga. Le versioni `_att` sono smussate. I 576 campioni stereo e lo spettro a 512 bin alimentano le onde.

## Shader di Milkdrop 2: HLSL → Metal

HLSL converte da solo vettori e scalari (`float3 x = tex2D(...)` scarta `.w`, `float3 v = 0` replica lo scalare); Metal no. Per questo il traduttore è un piccolo compilatore:

1. **Preprocessore:** le macro `#define` (anche con parametri) vengono espanse sui token, così i loro corpi passano dal traduttore.
2. **Parser:** funzioni, dichiarazioni globali (anche `sampler … = sampler_state {…}`), `shader_body`, istruzioni (`if/for/while/do/return`), espressioni con precedenze C, cast `(float3)x`, liste di inizializzazione.
3. **Tipi:** ogni espressione ha un tipo (scalare, vettore, matrice); assegnazioni, argomenti e operandi vengono convertiti secondo le regole HLSL. Tra vettori di dimensione diversa vince il più piccolo; uno scalare accanto a un vettore viene replicato.
4. **Traduzioni:**
   - `lerp`→`mix`, `frac`→`fract`, `ddx`/`ddy`→`dfdx`/`dfdy`;
   - `tex2D`/`tex3D`/`tex2Dlod`/`tex2Dbias` → `texture.sample(sampler, …)`;
   - `mul(a, b)` → `b * a` (le matrici HLSL sono per righe, quelle Metal per colonne: con gli stessi argomenti dei costruttori le due trasposizioni si compensano);
   - `mul(vettore, vettore)` → `dot`;
   - `sincos`; le funzioni intrinseche sono riconosciute senza distinguere maiuscole e minuscole.
5. **Ambiente di Milkdrop:**
   - **variabili:** `time`, `fps`, `frame`, `progress`, `bass`… `vol_att`, `aspect`, `texsize`, `rand_frame`, `rand_preset`, `roam_*`, `slow_roam_*`, `q1`–`q32`, `_qa`–`_qh`, `blur1_min`…, le 24 matrici `rot_*` e `hue_shader`. Stanno in un blocco di 160 `float4` (`MDUniforms`);
   - **funzioni:** `GetMain`, `GetPixel`, `GetBlur1-3`, `lum`;
   - **sampler** `sampler_[fw|fc|pw|pc]_name`: `main`, `blur1-3`, `noise_lq/mq/hq`, `noisevol_lq/hq` e fino a 8 texture del preset.
6. **Differenze da Metal:**
   - Metal non ha variabili globali per gli shader: texture, sampler e uniform passano come parametri nascosti a ogni funzione helper;
   - le variabili globali modificabili, o inizializzate con valori dinamici, vivono in una struct `G`;
   - quando un preset assegna una uniform ne crea una copia locale;
   - le variabili ridichiarate o con nomi riservati in Metal/C++ (`or`, `dot`, …) vengono rinominate.

Se uno shader non si traduce o non compila, quel preset usa la pipeline MD1 per quella fase e l'errore viene mostrato a schermo e scritto nel log.

### Compatibilità misurata (ottobre 2026)

`--milkdrop-verify` sulle raccolte pubbliche di projectM:

| Raccolta | Preset | Con shader MD2 | MD2 interamente compilati |
| --- | --- | --- | --- |
| presets-cream-of-the-crop | 9.795 | 8.251 | 8.244 (99,9%) |
| presets-milkdrop-original | 552 | 249 | 247 (99,2%) |

I pochi preset rimasti usano costrutti molto rari, come operazioni matrice per matrice componente per componente o errori di sintassi nel preset stesso. Nei render di prova con audio sintetico circa il 3–4% dei preset resta quasi nero: dipendono da volume o picchi reali (opacità legate al volume, punti che si muovono col beat), quindi la verifica va completata con musica vera.

### Approssimazioni note

- `hue_shader`, `roam_*` e le matrici `rot_*` imitano il comportamento di Milkdrop senza replicarne le formule esatte.
- Rispetto a Milkdrop i valori di blur sono senza riscalatura `min`/`max`.
- `progress` cresce in 20 s.
- Un sampler passato come parametro di funzione non è supportato.

## Tasti nella finestra

| Tasto | Azione |
| --- | --- |
| Spazio, → | Preset successivo (casuale; dopo essere tornati indietro ripercorre la cronologia) |
| ← | Preset precedente |
| L | Blocca o sblocca il preset |
| F, Invio, doppio clic | Schermo intero |
| Esc | Esce dallo schermo intero, oppure chiude |
| H | Aiuto a schermo |

Il menu contestuale contiene l'elenco dei preset, il cambio automatico (10–90 s o mai), la cartella dei preset e il comando per ricaricarli. Anche i tasti di Winamp (Z X C V B…) funzionano.
