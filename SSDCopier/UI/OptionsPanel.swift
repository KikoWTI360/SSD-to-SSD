import SwiftUI

struct OptionsPanel: View {
    @Binding var options: TransferOptions
    let isLocked: Bool

    @State private var showAdvanced = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Opzioni", systemImage: "slider.horizontal.3")
                .font(.headline)

            verification

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Toggle("Salta i file già presenti e identici (dimensione e data)", isOn: $options.skipIdenticalFiles)
                Toggle("Escludi i file di sistema (.Spotlight-V100, .Trashes, …)", isOn: $options.excludeSystemFiles)
                Toggle("Escludi i file .DS_Store", isOn: $options.excludeDSStore)
                Toggle("Conserva permessi, date e attributi estesi", isOn: $options.preserveMetadata)
                Toggle("Copia dentro una sottocartella con il nome dell'origine", isOn: $options.copyIntoNamedSubfolder)
                Toggle("Continua anche se un file dà errore", isOn: $options.continueOnError)
            }
            .toggleStyle(.checkbox)

            DisclosureGroup("Prestazioni", isExpanded: $showAdvanced) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("File copiati in parallelo")
                        Spacer()
                        Stepper(value: $options.parallelWorkers, in: TransferOptions.workerRange) {
                            Text("\(options.parallelWorkers)")
                                .monospacedDigit()
                                .frame(minWidth: 20, alignment: .trailing)
                        }
                    }
                    Text("2–4 è il valore giusto per due SSD. Valori alti aiutano solo con moltissimi file piccoli.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Picker("Blocco di lettura/scrittura", selection: $options.bufferSizeMB) {
                        ForEach(TransferOptions.bufferRange, id: \.self) { size in
                            Text("\(size) MB").tag(size)
                        }
                    }
                    .pickerStyle(.segmented)
                }
                .padding(.top, 10)
            }
            .font(.callout)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.secondary.opacity(0.18))
        )
        .disabled(isLocked)
        .opacity(isLocked ? 0.6 : 1)
    }

    private var verification: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Verifica dopo la copia", selection: $options.verification) {
                ForEach(VerificationMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            Text(options.verification.subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)

            if options.verification == .checksum {
                Label("Origine e destinazione vengono rilette bypassando la cache del sistema: è la verifica più affidabile, ma richiede circa lo stesso tempo della copia.",
                      systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if options.verification == .none {
                Label("Senza verifica un errore del disco o del cavo può passare inosservato.",
                      systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }
}
