# macosdragfix

Workaround nativo per il bug di spostamento finestre di macOS 27 (Golden Gate) beta:
su questa beta il trascinamento delle finestre dalla barra del titolo smette di
funzionare per le app con chrome "custom" (Electron, Chromium e simili), mentre
resta ok per le app AppKit native.

`macosdragfix` ti permette di spostare qualsiasi finestra trascinandone la fascia
alta, senza premere tasti, aggirando completamente la gesture rotta.

## Il bug

- Ambiente: macOS 27.x beta (es. build `26B5112a`), Apple Silicon.
- Sintomo: le finestre non si spostano trascinando la barra del titolo. Il drag
  delle tab interne funziona, quindi l'input arriva all'OS.
- Nel log di WindowServer, a ogni tentativo di drag:
  `[SkyLight:packages] no client initiated window drag trait gesture to activate for mouse`
- Si innesca con sessioni di input remoto/virtuale (controllo remoto, Universal
  Control, Chrome Remote Desktop) e resta finche non si riavvia WindowServer.
- Colpisce solo chi disegna la propria title bar: Electron/Chromium (Claude,
  Cursor, 1Password, Chrome, Spotify, ...). Le native (Safari, Finder,
  Impostazioni di Sistema, Terminal) non sono toccate.

Riferimenti: Apple Developer Forums thread 834488; Chromium issue 564169077.

## Come funziona

Un event tap (`CGEventTap`) intercetta il mouse. Quando premi e trascini nella
fascia-titolo di una finestra, `macosdragfix` ne aggiorna la posizione via
Accessibility API (`AXPosition`). L'AX NON passa per la gesture rotta, quindi il
movimento funziona anche dove il drag nativo e bloccato. Un click secco viene
lasciato all'app; sopra pulsanti/tab/campi di testo non interviene.

## Requisiti

- macOS su Apple Silicon.
- Toolchain Swift (Command Line Tools: `xcode-select --install`).

## Build

    swiftc -O -o macosdragfix macosdragfix.swift \
      -framework ApplicationServices -framework CoreGraphics

## Installazione

1. Il comando e gia su PATH via symlink: `~/bin/macosdragfix -> questo progetto`.
2. Primo avvio e permesso Accessibilita:

       macosdragfix

   Concedi l'accesso in Impostazioni di Sistema > Privacy e sicurezza >
   Accessibilita (abilita la voce che compare), poi rilancia. Deve stampare
   la riga `macosdragfix attivo ...`.
3. Avvio automatico al login (LaunchAgent):

       launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/it.m6i.macosdragfix.plist

   Stop: `launchctl bootout gui/$(id -u)/it.m6i.macosdragfix`
   Log: `/tmp/macosdragfix.log`

## Uso e opzioni

    macosdragfix [--xoffset N] [--yoffset N] [--band N] [--mod ctrl+cmd]

| opzione        | short | default | significato                                   |
|----------------|-------|---------|-----------------------------------------------|
| `--xoffset N`  | `-x`  | 8       | px da tenere da sinistra e da destra          |
| `--yoffset N`  | `-y`  | 6       | px da tenere dal bordo superiore              |
| `--band N`     | `-b`  | 34      | altezza della fascia-titolo dal bordo sup.    |
| `--mod M`      | `-m`  | nessuno | richiede un modificatore, es. `ctrl+cmd`      |

Fallback da env: `MACOSDRAGFIX_XOFFSET`, `MACOSDRAGFIX_YOFFSET`,
`MACOSDRAGFIX_BAND`, `MACOSDRAGFIX_MOD`.

### Zona di drag attiva

Relativa all'angolo in alto a sinistra della finestra:

- orizzontale: da `xoffset` a `larghezza - xoffset` (esclude angoli e lati -> resize)
- verticale: da `yoffset` a `band` (esclude la striscia superiore -> resize)

Per impostare le opzioni al login, aggiungile all'array `ProgramArguments` del
plist (vedi `it.m6i.macosdragfix.plist`).

## Taratura e compromessi

- Agisce sulla fascia alta di tutte le finestre; sulle native sposta comunque via
  AX, senza conflitti (gli eventi di drag vengono consumati durante il movimento).
- In Chrome la fascia alta e la barra delle tab: l'area vuota sposta la finestra,
  trascinare una tab (controllo AX) viene lasciato all'app. Se "mangia" troppo,
  abbassa `band` o alza `xoffset`.
- L'albero AX delle app Electron e povero: il riconoscimento dei controlli non e
  perfetto. Alza `band` se il contenuto trascinabile parte piu in basso.
- Soglia di 4 px: un click secco passa sempre all'app, solo un drag vero muove.

## Disinstallazione

    launchctl bootout gui/$(id -u)/it.m6i.macosdragfix 2>/dev/null
    rm -f ~/Library/LaunchAgents/it.m6i.macosdragfix.plist ~/bin/macosdragfix
    # e rimuovi la voce in Impostazioni > Privacy e sicurezza > Accessibilita

## Note

- E un workaround per un bug della beta, non una correzione del difetto. La cura
  vera e una build fixata da Apple o l'uscita dal programma beta.
- Strumenti collegati nel sistema: `wm-fix` (reset WindowManager/surface senza
  logout), `gfx-reset` (reset surface GPU). Il logout resta il reset completo di
  WindowServer.
