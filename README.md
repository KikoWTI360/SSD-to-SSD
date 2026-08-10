# Copia da SSD a SSD

App macOS nativa (SwiftUI + AppKit) che copia il contenuto di un SSD esterno su un altro,
**verifica** che la copia sia identica all'originale e mostra un **loader con percentuale,
velocità e tempo rimanente calcolato**.

<p align="center">
  <em>Origine → Destinazione · Analisi → Copia → Verifica → Rapporto</em>
</p>

---

## Cosa fa

| | |
|---|---|
| **Rilevamento dischi** | Elenca i volumi montati, evidenzia quelli esterni/espellibili e mostra spazio usato e libero. Si aggiorna da solo quando colleghi o scolleghi un disco. |
| **Copia integrale** | Cartelle, file, link simbolici e hard link. Conserva permessi, ACL, date e attributi estesi (resource fork compresi) tramite `copyfile(3)`. |
| **Verifica** | Tre livelli: nessuna, rapida (dimensione + data) o **SHA-256** con rilettura di origine e destinazione bypassando la cache del sistema. |
| **Loader con ETA** | Anello di avanzamento, percentuale, velocità istantanea, tempo trascorso, file e byte processati, file corrente. Il tempo rimanente tiene conto sia della copia sia della verifica. |
| **Controllo** | Pausa, ripresa e annullamento in qualsiasi momento; il Mac non va in stop durante il trasferimento. |
| **Rapporto finale** | Riepilogo con file copiati/saltati/non riusciti, esiti della verifica ed elenco dei problemi. Esportabile in testo o copiabile negli appunti. |

## Come è calcolato il tempo rimanente

Una media semplice "byte totali ÷ tempo trascorso" è inutilizzabile: reagisce troppo lentamente
quando la velocità cambia (esaurimento della cache SLC, raffica di file piccoli, throttling termico).

L'app usa invece (`Core/RateEstimator.swift`):

1. **finestra scorrevole** di 6 secondi sul throughput reale;
2. **media esponenziale** sopra la finestra, per non far ballare il numero a ogni tick;
3. **due stime separate**, una per la copia e una per la verifica, perché leggere e scrivere non
   hanno la stessa velocità: `ETA = byte_copia_rimanenti / velocità_copia + byte_verifica_rimanenti / velocità_verifica`;
4. **smorzamento asimmetrico**: l'ETA scende subito e sale piano, perché un rallentamento
   momentaneo non deve raddoppiare il numero mostrato.

Per lo stesso motivo la barra generale non è proporzionale ai byte ma al **tempo stimato**: la
percentuale non si blocca quando inizia la fase di verifica.

## Come è fatta la copia

- I/O POSIX diretto (`open`/`read`/`write`) a blocchi configurabili (default 4 MB), non
  `FileManager.copyItem`, che non offre né avanzamento né annullamento.
- `F_PREALLOCATE` sul file di destinazione: meno frammentazione e fallimento immediato se lo
  spazio non basta, invece che a metà di un file da 40 GB.
- `F_NOCACHE` sui file grandi (soglia configurabile, default 32 MB) per non svuotare la cache
  unificata del sistema, e **sempre** durante la verifica, così l'hash rilegge davvero dal disco
  e non le pagine appena scritte.
- `fsync` prima di considerare chiuso un file.
- Copie in parallelo su più file (default 3 lavoratori) con coda a lotti: la memoria resta piatta
  anche con alberi da milioni di file.
- Le date delle cartelle vengono riapplicate alla fine, dalla più profonda alla più superficiale,
  perché scrivere un figlio modifica la data del genitore.

## Requisiti

- macOS 14 (Sonoma) o successivo
- Xcode 15 o successivo

## Come compilare

```bash
open SSDCopier.xcodeproj
```

Poi in Xcode: seleziona il target **SSDCopier** → **Signing & Capabilities** → imposta il tuo Team.
`⌘R` per eseguire.

Da riga di comando:

```bash
./scripts/build.sh                     # build Debug
./scripts/build.sh Release             # build Release
```

### Rigenerare il progetto Xcode

Il file `.xcodeproj` è generato da uno script, così l'elenco dei sorgenti non va mantenuto a mano.
Dopo aver aggiunto, rinominato o eliminato un file Swift:

```bash
python3 scripts/generate_project.py
```

## Permessi e sandbox

L'app è **in sandbox** e chiede accesso solo a ciò che scegli tu:

- `com.apple.security.files.user-selected.read-write` — scegliendo un disco nel pannello di
  selezione concedi l'accesso all'intero volume;
- `com.apple.security.files.bookmarks.app-scope` — i segnalibri con ambito di sicurezza fanno sì
  che origine e destinazione vengano ricordate tra un avvio e l'altro.

Per questo la scelta del disco passa **sempre** dal pannello di sistema, anche quando lo selezioni
dal menu a tendina: è quel pannello a concedere il permesso. Alla prima copia su un disco esterno
macOS mostrerà anche la richiesta TCC "Volumi rimovibili" (la motivazione mostrata è in
`INFOPLIST_KEY_NSRemovableVolumesUsageDescription`).

Se preferisci un'app senza sandbox — utile per copiare volumi di sistema o percorsi arbitrari
senza pannello — togli `com.apple.security.app-sandbox` da `SSDCopier.entitlements`. In quel caso
serve il permesso **Accesso completo al disco** in Impostazioni di Sistema › Privacy e sicurezza.

## Struttura

```
SSDCopier/
├── App/
│   └── SSDCopierApp.swift        scena, menu, conferma d'uscita durante la copia
├── Core/
│   ├── TransferEngine.swift      orchestrazione: analisi → copia → verifica → finalizzazione
│   ├── FileOps.swift             I/O POSIX, SHA-256, metadati via copyfile(3)
│   ├── Concurrency.swift         gate pausa/annulla, pool di buffer riutilizzabili
│   ├── RateEstimator.swift       throughput, ETA e frazioni di avanzamento
│   ├── VolumeScanner.swift       volumi montati e loro capacità
│   ├── BookmarkStore.swift       segnalibri con ambito di sicurezza
│   ├── TransferOptions.swift     opzioni utente (persistite)
│   ├── TransferProgress.swift    contatori e istantanea per la UI
│   ├── TransferReport.swift      rapporto finale ed export
│   └── Formatters.swift          byte, durate, percentuali
└── UI/
    ├── ContentView.swift         schermata principale
    ├── TransferController.swift  stato osservabile, ciclo di vita del trasferimento
    ├── DiskCard.swift            selettore disco con barra di capacità
    ├── ProgressPanel.swift       anello, ETA, statistiche
    ├── OptionsPanel.swift        opzioni
    └── ReportSheet.swift         rapporto finale
```

## Note e limiti noti

- La copia **unisce** l'origine nella destinazione: i file omonimi vengono sovrascritti, gli altri
  restano. Non è un mirror — non elimina dalla destinazione ciò che non esiste più nell'origine.
- Con "Salta i file già presenti e identici" attivo, un trasferimento interrotto si riprende
  semplicemente rilanciandolo: i file già copiati vengono saltati.
- Il confronto per il salto usa dimensione + data di modifica, con 1 secondo di tolleranza
  (FAT/ExFAT registrano le date con granularità di 2 secondi).
- I file sparsi vengono copiati espansi: la destinazione può occupare più spazio dell'origine.
- Socket, fifo e device non vengono copiati; finiscono nel rapporto come avvisi.
- La copia non attraversa i punti di mount annidati (immagini disco montate dentro l'origine).
