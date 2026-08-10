import SwiftUI

struct OptionsPanel: View {
    @Binding var options: TransferOptions
    let isLocked: Bool

    @State private var showAdvanced = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(L("options.title"), systemImage: "slider.horizontal.3")
                .font(.headline)

            verification

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Toggle(L("options.skipIdentical"), isOn: $options.skipIdenticalFiles)
                Toggle(L("options.excludeSystem"), isOn: $options.excludeSystemFiles)
                Toggle(L("options.excludeDSStore"), isOn: $options.excludeDSStore)
                Toggle(L("options.preserveMetadata"), isOn: $options.preserveMetadata)
                Toggle(L("options.subfolder"), isOn: $options.copyIntoNamedSubfolder)
                Toggle(L("options.continueOnError"), isOn: $options.continueOnError)
            }
            .toggleStyle(.checkbox)

            DisclosureGroup(L("options.performance"), isExpanded: $showAdvanced) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text(L("options.workers"))
                        Spacer()
                        Stepper(value: $options.parallelWorkers, in: TransferOptions.workerRange) {
                            Text("\(options.parallelWorkers)")
                                .monospacedDigit()
                                .frame(minWidth: 20, alignment: .trailing)
                        }
                    }
                    Text(L("options.workers.hint"))
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Picker(L("options.buffer"), selection: $options.bufferSizeMB) {
                        ForEach(TransferOptions.bufferRange, id: \.self) { size in
                            Text(L("options.buffer.unit", String(size))).tag(size)
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
            Picker(L("options.verification"), selection: $options.verification) {
                ForEach(VerificationMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            Text(options.verification.subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)

            if options.verification == .checksum {
                Label(L("options.checksum.note"), systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if options.verification == .none {
                Label(L("options.none.warning"), systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }
}
