import Foundation
import Observation

/// Language the user picked in the toolbar menu.
enum AppLanguage: String, CaseIterable, Identifiable, Codable, Sendable {
    case system
    case italian
    case english

    var id: String { rawValue }

    var code: LanguageCode? {
        switch self {
        case .system: nil
        case .italian: .it
        case .english: .en
        }
    }

    /// Language names stay in their own language — that is how every OS lists them.
    var displayName: String {
        switch self {
        case .system: L("language.system")
        case .italian: "Italiano"
        case .english: "English"
        }
    }
}

enum LanguageCode: String, Sendable {
    case it
    case en
}

/// Non-isolated string storage.
///
/// Deliberately *not* actor-isolated: the copy engine runs on GCD threads and produces
/// user-facing error text, so `L(_:_:)` has to be callable from anywhere. The UI observes
/// `LanguageSetting` instead, which is what triggers a redraw.
enum Loc {
    private static let lock = NSLock()
    private static var current: LanguageCode = Loc.systemLanguage()

    static var language: LanguageCode {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    static func setLanguage(_ code: LanguageCode) {
        lock.lock()
        current = code
        lock.unlock()
    }

    static func systemLanguage() -> LanguageCode {
        let preferred = Locale.preferredLanguages.first ?? "en"
        return preferred.hasPrefix("it") ? .it : .en
    }

    static func string(_ key: String) -> String {
        let table = language == .it ? italian : english
        // Falling back to the key itself makes a missing translation obvious rather than silent.
        return table[key] ?? english[key] ?? key
    }
}

/// Looks up `key` in the active language. Extra arguments fill `%@` placeholders.
///
/// Always pass pre-formatted strings, never raw numbers: it keeps every placeholder `%@`, so a
/// translation can reorder them (`%1$@`, `%2$@`) without any type mismatch.
func L(_ key: String, _ arguments: CVarArg...) -> String {
    let format = Loc.string(key)
    // Skip `String(format:)` entirely when unused, so a literal `%` in a string survives.
    guard !arguments.isEmpty else { return format }
    return String(format: format, arguments: arguments)
}

/// Observable wrapper the UI watches. Changing the selection rebuilds the view tree.
@MainActor
@Observable
final class LanguageSetting {
    static let shared = LanguageSetting()

    private static let defaultsKey = "AppLanguage.v1"

    private(set) var selection: AppLanguage

    private init() {
        let stored = UserDefaults.standard.string(forKey: Self.defaultsKey)
        selection = stored.flatMap(AppLanguage.init(rawValue:)) ?? .system
        applySelection()
    }

    func select(_ language: AppLanguage) {
        guard language != selection else { return }
        selection = language
        applySelection()
        UserDefaults.standard.set(language.rawValue, forKey: Self.defaultsKey)
    }

    private func applySelection() {
        Loc.setLanguage(selection.code ?? Loc.systemLanguage())
    }
}

// MARK: - Tables

extension Loc {

    fileprivate static let italian: [String: String] = [
        // App
        "app.title": "Copia da SSD a SSD",
        "app.subtitle": "Copia integrale con verifica e tempo rimanente calcolato",
        "language.system": "Sistema",
        "language.label": "Lingua",
        "language.help": "Scegli la lingua dell'interfaccia",

        // Azioni
        "action.ok": "OK",
        "action.cancel": "Annulla",
        "action.start": "Avvia copia",
        "action.pause": "Pausa",
        "action.resume": "Riprendi",
        "action.refreshDisks": "Aggiorna dischi",
        "action.refreshDisks.help": "Rileggi l'elenco dei volumi collegati",
        "action.swap.help": "Inverti origine e destinazione",
        "action.verifyOnly": "Verifica soltanto",
        "action.verifyOnly.help": "Confronta i file già presenti sulla destinazione, senza ricopiarli. Serve quando una copia è stata interrotta prima della verifica.",
        "mode.copyAndVerify.title": "Copia e verifica",
        "mode.verifyOnly.title": "Solo verifica",
        "report.mode": "Modalità",
        "report.verifyHeaderStats": "%@ verificati in %@ · media %@",
        "setup.nothingToVerify": "Sulla destinazione non c'è nessuna copia da verificare.",
        "status.readyVerify": "Pronto: verifica %@ della copia già presente.",

        // Dischi
        "disk.source": "Origine",
        "disk.destination": "Destinazione",
        "disk.source.hint": "Scegli il disco da copiare",
        "disk.destination.hint": "Scegli dove scrivere la copia",
        "disk.external": "Esterno",
        "disk.readOnly": "Sola lettura",
        "disk.revealInFinder": "Mostra nel Finder",
        "disk.noExternal": "Nessun disco esterno collegato",
        "disk.externalSection": "Dischi esterni",
        "disk.otherSection": "Altri volumi",
        "disk.chooseFolder": "Scegli una cartella…",
        "disk.select": "Seleziona…",
        "disk.change": "Cambia…",
        "disk.menuItem": "%@ — %@ liberi",
        "volume.unknownCapacity": "Capacità sconosciuta",
        "volume.capacity": "%@ liberi di %@",
        "capacity.detail": "%@ usati · %@ liberi",
        "selection.onVolume": "su %@",

        // Pannelli di selezione
        "panel.source.message": "Scegli il disco (o la cartella) da copiare",
        "panel.source.prompt": "Usa come origine",
        "panel.destination.message": "Scegli il disco (o la cartella) di destinazione",
        "panel.destination.prompt": "Usa come destinazione",

        // Stato
        "status.selectDisks": "Seleziona il disco di origine e quello di destinazione.",
        "status.ready": "Pronto: verifica %@.",
        "status.paused": "In pausa",

        // Fasi
        "phase.idle": "Pronto",
        "phase.preparing": "Preparazione",
        "phase.scanning": "Analisi origine",
        "phase.copying": "Copia in corso",
        "phase.verifying": "Verifica",
        "phase.finalizing": "Finalizzazione",
        "phase.completed": "Completato",
        "phase.cancelled": "Annullato",
        "phase.failed": "Interrotto",
        "phase.desc.scanning": "Analisi dell'origine: %@ elementi trovati",
        "phase.desc.copying": "Copia dei dati",
        "phase.desc.verifying": "Verifica di ogni file",
        "phase.desc.finalizing": "Ripristino di date e permessi delle cartelle",

        // Avanzamento
        "progress.remaining": "Tempo rimanente",
        "progress.speed": "Velocità",
        "progress.elapsed": "Trascorso",
        "progress.completed": "Completato",
        "progress.data": "Dati",
        "progress.files": "File",
        "progress.issues": "Problemi",
        "progress.noIssues": "nessuno",
        "progress.inProgress": "in corso",

        // Tempi
        "time.calculating": "Calcolo…",
        "time.fewSeconds": "pochi secondi",

        // Verifica
        "verify.none.title": "Nessuna",
        "verify.quick.title": "Rapida",
        "verify.checksum.title": "SHA-256",
        "verify.none.subtitle": "Copia e basta, nessun controllo.",
        "verify.quick.subtitle": "Confronta dimensione e data di ogni file.",
        "verify.checksum.subtitle": "Rilegge origine e destinazione e confronta l'hash.",

        // Opzioni
        "options.title": "Opzioni",
        "options.verification": "Verifica dopo la copia",
        "options.checksum.note": "Origine e destinazione vengono rilette bypassando la cache del sistema: è la verifica più affidabile, ma richiede circa lo stesso tempo della copia.",
        "options.none.warning": "Senza verifica un errore del disco o del cavo può passare inosservato.",
        "options.skipIdentical": "Salta i file già presenti e identici (dimensione e data)",
        "options.excludeSystem": "Escludi i file di sistema (.Spotlight-V100, .Trashes, …)",
        "options.excludeDSStore": "Escludi i file .DS_Store",
        "options.preserveMetadata": "Conserva permessi, date e attributi estesi",
        "options.subfolder": "Copia dentro una sottocartella con il nome dell'origine",
        "options.continueOnError": "Continua anche se un file dà errore",
        "options.performance": "Prestazioni",
        "options.workers": "File copiati in parallelo",
        "options.workers.hint": "2–4 è il valore giusto per due SSD. Valori alti aiutano solo con moltissimi file piccoli.",
        "options.buffer": "Blocco di lettura/scrittura",
        "options.buffer.unit": "%@ MB",

        // Conferme e avvisi
        "alert.cannotStart": "Impossibile iniziare",
        "alert.samePath": "Origine e destinazione coincidono. Scegli due percorsi diversi.",
        "alert.sameVolume": "Origine e destinazione si trovano sullo stesso volume («%@»). Collega due dischi distinti.",
        "alert.destinationReadOnly": "Il disco di destinazione è montato in sola lettura.",
        "confirm.notEmpty.title": "La destinazione non è vuota",
        "confirm.notEmpty.message": "«%@» contiene già dei file. I file con lo stesso nome verranno sovrascritti; gli altri resteranno al loro posto. Continuare?",
        "confirm.notEmpty.button": "Copia comunque",
        "quit.title": "Copia in corso",
        "quit.message": "Uscire adesso lascerà la destinazione incompleta. Vuoi interrompere il trasferimento e uscire?",
        "quit.stopAndQuit": "Interrompi ed esci",
        "quit.continue": "Continua la copia",

        // Esiti
        "outcome.completed": "Copia completata e verificata",
        "outcome.completedWithIssues": "Completata con avvisi",
        "outcome.cancelled": "Copia annullata",
        "outcome.failed": "Copia interrotta",
        "issue.warning": "Avviso",
        "issue.error": "Errore",

        // Rapporto
        "report.title": "SSD Copier — rapporto di trasferimento",
        "report.summary": "Riepilogo",
        "report.outcome": "Esito",
        "report.reason": "Motivo",
        "report.source": "Origine",
        "report.destination": "Destinazione",
        "report.start": "Inizio",
        "report.end": "Fine",
        "report.duration": "Durata",
        "report.verification": "Verifica",
        "report.folders": "Cartelle",
        "report.totalFiles": "File totali",
        "report.symlinks": "Link simbolici",
        "report.copied": "Copiati",
        "report.skipped": "Saltati",
        "report.failed": "Non riusciti",
        "report.verified": "Verificati",
        "report.mismatched": "Discordanti",
        "report.averageSpeed": "Velocità media",
        "report.filesCopied": "File copiati",
        "report.filesSkipped": "File saltati",
        "report.verificationLabel": "Verifica %@",
        "report.verify.notRun": "non eseguita",
        "report.verify.ok": "%@ file OK",
        "report.verify.mismatch": "%@ discordanti",
        "report.headerStats": "%@ in %@ · media %@",
        "report.issues": "Problemi (%@)",
        "report.moreIssues": "… e altri %@. Esporta il rapporto per l'elenco completo.",
        "report.copyToClipboard": "Copia negli appunti",
        "report.export": "Esporta rapporto…",
        "report.close": "Chiudi",
        "report.filename": "Rapporto copia SSD.txt",

        // Errori del motore
        "setup.sourceMissing": "La cartella di origine non esiste o non è più disponibile.",
        "setup.destinationMissing": "La cartella di destinazione non esiste o non è più disponibile.",
        "setup.samePath": "Origine e destinazione coincidono.",
        "setup.destinationInsideSource": "La destinazione si trova dentro l'origine: la copia si ripeterebbe all'infinito.",
        "setup.sourceInsideDestination": "L'origine si trova dentro la destinazione: la copia sovrascriverebbe i file originali.",
        "setup.destinationReadOnly": "La destinazione è in sola lettura o non è scrivibile.",
        "space.needed": "Servono %@ ma sulla destinazione sono liberi %@.",
        "space.willSkip": "%@ Il trasferimento prosegue perché i file già identici verranno saltati.",
        "space.insufficient": "Spazio insufficiente. %@",
        "engine.stoppedAtFirstError": "Interrotto al primo errore: %@",
        "issue.unsupportedType": "Tipo di file non supportato (socket, fifo o device): ignorato.",
        "issue.unreadableEntry": "Voce non leggibile: %@",
        "issue.unreadableAttributes": "Attributi non leggibili: voce ignorata.",
        "issue.unreadableSource": "Impossibile leggere il contenuto dell'origine.",

        // Errori di file
        "error.cancelled": "Operazione annullata.",
        "error.open": "Impossibile aprire «%@»: %@",
        "error.create": "Impossibile creare «%@»: %@",
        "error.read": "Errore di lettura su «%@»: %@",
        "error.write": "Errore di scrittura su «%@»: %@",
        "error.shortWrite": "Scrittura incompleta su «%@»: spazio esaurito o disco scollegato.",
        "error.metadata": "Metadati non applicati a «%@»: %@",
        "error.symlink": "Link simbolico non creato «%@»: %@",
        "error.link": "Hard link non creato «%@»: %@",
        "error.makeDirectory": "Cartella non creata «%@»: %@",
        "error.sizeMismatch": "Dimensione diversa su «%@»: attesi %@, trovati %@.",
        "error.digestMismatch": "Hash SHA-256 diverso su «%@»: la copia non corrisponde all'originale.",
        "error.missingAtDestination": "File assente nella destinazione: «%@».",
        "error.dateMismatch": "Data di modifica diversa su «%@».",
    ]

    fileprivate static let english: [String: String] = [
        // App
        "app.title": "SSD to SSD Copy",
        "app.subtitle": "Full copy with verification and a calculated time remaining",
        "language.system": "System",
        "language.label": "Language",
        "language.help": "Choose the interface language",

        // Actions
        "action.ok": "OK",
        "action.cancel": "Cancel",
        "action.start": "Start copy",
        "action.pause": "Pause",
        "action.resume": "Resume",
        "action.refreshDisks": "Refresh drives",
        "action.refreshDisks.help": "Re-read the list of connected volumes",
        "action.swap.help": "Swap source and destination",
        "action.verifyOnly": "Verify only",
        "action.verifyOnly.help": "Compares the files already on the destination without copying them again. Use it when a copy was interrupted before verification.",
        "mode.copyAndVerify.title": "Copy and verify",
        "mode.verifyOnly.title": "Verify only",
        "report.mode": "Mode",
        "report.verifyHeaderStats": "%@ verified in %@ · %@ average",
        "setup.nothingToVerify": "There is no copy on the destination to verify.",
        "status.readyVerify": "Ready: %@ verification of the copy already there.",

        // Drives
        "disk.source": "Source",
        "disk.destination": "Destination",
        "disk.source.hint": "Choose the drive to copy",
        "disk.destination.hint": "Choose where to write the copy",
        "disk.external": "External",
        "disk.readOnly": "Read only",
        "disk.revealInFinder": "Show in Finder",
        "disk.noExternal": "No external drive connected",
        "disk.externalSection": "External drives",
        "disk.otherSection": "Other volumes",
        "disk.chooseFolder": "Choose a folder…",
        "disk.select": "Select…",
        "disk.change": "Change…",
        "disk.menuItem": "%@ — %@ free",
        "volume.unknownCapacity": "Unknown capacity",
        "volume.capacity": "%@ free of %@",
        "capacity.detail": "%@ used · %@ free",
        "selection.onVolume": "on %@",

        // Open panels
        "panel.source.message": "Choose the drive (or folder) to copy",
        "panel.source.prompt": "Use as source",
        "panel.destination.message": "Choose the destination drive (or folder)",
        "panel.destination.prompt": "Use as destination",

        // Status
        "status.selectDisks": "Select the source and destination drives.",
        "status.ready": "Ready: %@ verification.",
        "status.paused": "Paused",

        // Phases
        "phase.idle": "Ready",
        "phase.preparing": "Preparing",
        "phase.scanning": "Scanning source",
        "phase.copying": "Copying",
        "phase.verifying": "Verifying",
        "phase.finalizing": "Finalizing",
        "phase.completed": "Completed",
        "phase.cancelled": "Cancelled",
        "phase.failed": "Stopped",
        "phase.desc.scanning": "Scanning the source: %@ items found",
        "phase.desc.copying": "Copying data",
        "phase.desc.verifying": "Verifying every file",
        "phase.desc.finalizing": "Restoring folder dates and permissions",

        // Progress
        "progress.remaining": "Time remaining",
        "progress.speed": "Speed",
        "progress.elapsed": "Elapsed",
        "progress.completed": "Completed",
        "progress.data": "Data",
        "progress.files": "Files",
        "progress.issues": "Issues",
        "progress.noIssues": "none",
        "progress.inProgress": "in progress",

        // Time
        "time.calculating": "Calculating…",
        "time.fewSeconds": "a few seconds",

        // Verification
        "verify.none.title": "None",
        "verify.quick.title": "Quick",
        "verify.checksum.title": "SHA-256",
        "verify.none.subtitle": "Copy only, nothing is checked.",
        "verify.quick.subtitle": "Compares the size and date of every file.",
        "verify.checksum.subtitle": "Re-reads source and destination and compares the hash.",

        // Options
        "options.title": "Options",
        "options.verification": "Verification after copying",
        "options.checksum.note": "Source and destination are re-read bypassing the system cache: this is the most trustworthy check, but it takes roughly as long as the copy itself.",
        "options.none.warning": "Without verification a drive or cable fault can go unnoticed.",
        "options.skipIdentical": "Skip files already present and identical (size and date)",
        "options.excludeSystem": "Exclude system files (.Spotlight-V100, .Trashes, …)",
        "options.excludeDSStore": "Exclude .DS_Store files",
        "options.preserveMetadata": "Preserve permissions, dates and extended attributes",
        "options.subfolder": "Copy into a subfolder named after the source",
        "options.continueOnError": "Keep going when a file fails",
        "options.performance": "Performance",
        "options.workers": "Files copied in parallel",
        "options.workers.hint": "2–4 is right for two SSDs. Higher values only help with very many small files.",
        "options.buffer": "Read/write block",
        "options.buffer.unit": "%@ MB",

        // Confirmations and alerts
        "alert.cannotStart": "Cannot start",
        "alert.samePath": "Source and destination are the same. Choose two different paths.",
        "alert.sameVolume": "Source and destination are on the same volume (“%@”). Connect two separate drives.",
        "alert.destinationReadOnly": "The destination drive is mounted read-only.",
        "confirm.notEmpty.title": "The destination is not empty",
        "confirm.notEmpty.message": "“%@” already contains files. Files with the same name will be overwritten; the others will stay where they are. Continue?",
        "confirm.notEmpty.button": "Copy anyway",
        "quit.title": "Copy in progress",
        "quit.message": "Quitting now will leave the destination incomplete. Do you want to stop the transfer and quit?",
        "quit.stopAndQuit": "Stop and quit",
        "quit.continue": "Keep copying",

        // Outcomes
        "outcome.completed": "Copy completed and verified",
        "outcome.completedWithIssues": "Completed with warnings",
        "outcome.cancelled": "Copy cancelled",
        "outcome.failed": "Copy failed",
        "issue.warning": "Warning",
        "issue.error": "Error",

        // Report
        "report.title": "SSD Copier — transfer report",
        "report.summary": "Summary",
        "report.outcome": "Outcome",
        "report.reason": "Reason",
        "report.source": "Source",
        "report.destination": "Destination",
        "report.start": "Started",
        "report.end": "Finished",
        "report.duration": "Duration",
        "report.verification": "Verification",
        "report.folders": "Folders",
        "report.totalFiles": "Total files",
        "report.symlinks": "Symbolic links",
        "report.copied": "Copied",
        "report.skipped": "Skipped",
        "report.failed": "Failed",
        "report.verified": "Verified",
        "report.mismatched": "Mismatched",
        "report.averageSpeed": "Average speed",
        "report.filesCopied": "Files copied",
        "report.filesSkipped": "Files skipped",
        "report.verificationLabel": "%@ verification",
        "report.verify.notRun": "not performed",
        "report.verify.ok": "%@ files OK",
        "report.verify.mismatch": "%@ mismatched",
        "report.headerStats": "%@ in %@ · %@ average",
        "report.issues": "Issues (%@)",
        "report.moreIssues": "… and %@ more. Export the report for the full list.",
        "report.copyToClipboard": "Copy to clipboard",
        "report.export": "Export report…",
        "report.close": "Close",
        "report.filename": "SSD copy report.txt",

        // Engine errors
        "setup.sourceMissing": "The source folder does not exist or is no longer available.",
        "setup.destinationMissing": "The destination folder does not exist or is no longer available.",
        "setup.samePath": "Source and destination are the same.",
        "setup.destinationInsideSource": "The destination sits inside the source: the copy would repeat forever.",
        "setup.sourceInsideDestination": "The source sits inside the destination: the copy would overwrite the originals.",
        "setup.destinationReadOnly": "The destination is read-only or not writable.",
        "space.needed": "%@ needed but only %@ free on the destination.",
        "space.willSkip": "%@ Continuing anyway because files that are already identical will be skipped.",
        "space.insufficient": "Not enough space. %@",
        "engine.stoppedAtFirstError": "Stopped at the first error: %@",
        "issue.unsupportedType": "Unsupported file type (socket, fifo or device): skipped.",
        "issue.unreadableEntry": "Unreadable entry: %@",
        "issue.unreadableAttributes": "Unreadable attributes: entry skipped.",
        "issue.unreadableSource": "Cannot read the contents of the source.",

        // File errors
        "error.cancelled": "Operation cancelled.",
        "error.open": "Cannot open “%@”: %@",
        "error.create": "Cannot create “%@”: %@",
        "error.read": "Read error on “%@”: %@",
        "error.write": "Write error on “%@”: %@",
        "error.shortWrite": "Incomplete write on “%@”: out of space or drive disconnected.",
        "error.metadata": "Metadata not applied to “%@”: %@",
        "error.symlink": "Symbolic link not created “%@”: %@",
        "error.link": "Hard link not created “%@”: %@",
        "error.makeDirectory": "Folder not created “%@”: %@",
        "error.sizeMismatch": "Different size on “%@”: expected %@, found %@.",
        "error.digestMismatch": "Different SHA-256 hash on “%@”: the copy does not match the original.",
        "error.missingAtDestination": "File missing at the destination: “%@”.",
        "error.dateMismatch": "Different modification date on “%@”.",
    ]
}
