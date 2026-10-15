# AGENTS.md

Guida per agenti AI e contributori che lavorano su questo repo.

## Scopo

`macosdragfix` e un singolo binario Swift che ridate lo spostamento finestre su
macOS 27 beta, dove il drag della title bar e rotto per le app a chrome custom
(Electron/Chromium). Non corregge il bug di sistema: lo aggira spostando le
finestre via Accessibility API invece che via la gesture di WindowServer.

## Struttura

- `macosdragfix.swift` - unico sorgente (nessuna dipendenza esterna).
- `macosdragfix` - binario compilato.
- `it.m6i.macosdragfix.plist` - template LaunchAgent (avvio al login).
- `README.md` - documentazione utente.

Il comando e esposto su PATH da `~/bin/macosdragfix` (symlink al binario qui).

## Build e run

    swiftc -O -o macosdragfix macosdragfix.swift \
      -framework ApplicationServices -framework CoreGraphics
    ./macosdragfix --xoffset 8 --yoffset 6

Non c'e suite di test automatica: la verifica e manuale (vedi sotto).

## Come funziona (invarianti da NON rompere)

- Event tap `cgSessionEventTap` su leftMouseDown/Dragged/Up. Richiede il permesso
  Accessibilita per esistere.
- Coordinate: `CGEvent.location` e le `AXPosition`/`AXSize` condividono l'origine
  in alto a sinistra del display principale. Nessun flip dell'asse Y.
- Il mouseDown NON viene mai consumato: un click deve sempre arrivare all'app.
  Si consuma solo il leftMouseDragged mentre si sta effettivamente spostando.
- Soglia `threshold` (4 px): si entra in "moving" solo dopo un movimento reale,
  cosi un click secco non sposta nulla.
- Si ignora il down se l'elemento AX sotto il cursore ha un ruolo interattivo
  (`interactiveRoles`: AXButton, AXTextField, AXTab-like, ...): niente hijack di
  pulsanti/tab/campi.
- Zona attiva relativa alla finestra: x in [xoffset, width-xoffset],
  y in [yoffset, band]. Esclude bordo superiore e angoli (zone di resize).
- Lo spostamento usa `AXUIElementSetAttributeValue(win, kAXPositionAttribute)`.
  Questo e il punto chiave: bypassa la gesture rotta, quindi funziona sulle app
  Electron.

## Parametri

CLI `--xoffset/-x`, `--yoffset/-y`, `--band/-b`, `--mod/-m`; fallback env
`MACOSDRAGFIX_{XOFFSET,YOFFSET,BAND,MOD}`. CLI vince sull'env. `--mod` vuoto =
nessun modificatore richiesto.

## Verifica manuale di una modifica

1. Ricompila. Il recompile cambia il cdhash: potrebbe servire riconcedere
   Accessibilita (TCC lega il permesso all'identita del binario non firmato).
2. Avvia da terminale, controlla la riga di stato su stderr con i parametri.
3. Test drag su una app Electron (Claude, Cursor) e una nativa (Safari):
   entrambe devono spostarsi trascinando la fascia alta.
4. Test non-regressione: un click su un pulsante/tab nella fascia alta deve
   ancora funzionare (il tool si fa da parte).
5. Se serve ispezionare il comportamento di WindowServer:
   `log show --last 60s --predicate 'process == "WindowServer"' --style compact | grep "drag trait"`

## Gotcha

- Binario non firmato: ogni rebuild puo richiedere di riabilitare la voce in
  Impostazioni > Privacy e sicurezza > Accessibilita.
- L'albero AX delle app Electron e minimale: il filtro `interactiveRoles` puo
  non vedere alcuni controlli. In caso, preferire aggiustare `band`/`xoffset`
  piuttosto che allargare gli hijack.
- Non introdurre il consumo del mouseDown: romperebbe i click ovunque.
- Mantenere le dipendenze a zero (solo framework di sistema) e il tutto in un
  singolo file: e un workaround, deve restare semplice e ricompilabile ovunque.

## Contesto

Target reale: un MacBook Pro M5 Max (Mac17,7) su macOS 27.x beta. Il bug a monte
e tracciato in Apple Developer Forums 834488 e Chromium 564169077. Quando Apple
rilascera una build fixata, questo tool diventa superfluo.
