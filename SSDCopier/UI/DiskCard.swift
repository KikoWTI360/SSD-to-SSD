import SwiftUI

/// One of the two big drive slots at the top of the window.
struct DiskCard: View {
    enum Role {
        case source
        case destination

        var title: String {
            switch self {
            case .source: "Origine"
            case .destination: "Destinazione"
            }
        }

        var symbol: String {
            switch self {
            case .source: "externaldrive.fill.badge.minus"
            case .destination: "externaldrive.fill.badge.plus"
            }
        }

        var tint: Color {
            switch self {
            case .source: .blue
            case .destination: .green
            }
        }

        var emptyHint: String {
            switch self {
            case .source: "Scegli il disco da copiare"
            case .destination: "Scegli dove scrivere la copia"
            }
        }
    }

    let role: Role
    let selection: TransferController.Selection?
    let volumes: [VolumeInfo]
    let isEnabled: Bool
    var onChoose: (VolumeInfo?) -> Void
    var onReveal: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(role.title, systemImage: role.symbol)
                .font(.headline)
                .foregroundStyle(role.tint)

            if let selection {
                filled(selection)
            } else {
                empty
            }

            Spacer(minLength: 0)
            picker
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 208, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(selection == nil ? Color.secondary.opacity(0.25) : role.tint.opacity(0.35),
                              style: StrokeStyle(lineWidth: 1, dash: selection == nil ? [5, 4] : []))
        )
    }

    private func filled(_ selection: TransferController.Selection) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                if let volume = selection.volume {
                    Image(nsImage: volume.icon)
                        .resizable()
                        .frame(width: 42, height: 42)
                } else {
                    Image(systemName: "folder.fill")
                        .font(.system(size: 30))
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(selection.displayName)
                        .font(.title3.weight(.semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(selection.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 0)
            }

            if let volume = selection.volume, volume.totalCapacity > 0 {
                CapacityBar(volume: volume, tint: role.tint)
            }

            HStack(spacing: 8) {
                if selection.volume?.isExternal == true {
                    BadgeTag(text: "Esterno", symbol: "bolt.horizontal.circle")
                }
                if selection.volume?.isReadOnly == true {
                    BadgeTag(text: "Sola lettura", symbol: "lock.fill", tint: .orange)
                }
                Button("Mostra nel Finder", action: onReveal)
                    .buttonStyle(.link)
                    .font(.caption)
            }
        }
    }

    private var empty: some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: "externaldrive.badge.questionmark")
                .font(.system(size: 30))
                .foregroundStyle(.secondary)
            Text(role.emptyHint)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 6)
    }

    private var picker: some View {
        Menu {
            let external = volumes.filter(\.isExternal)
            let internalVolumes = volumes.filter { !$0.isExternal }

            if external.isEmpty {
                Text("Nessun disco esterno collegato")
            } else {
                Section("Dischi esterni") {
                    ForEach(external) { volume in
                        Button {
                            onChoose(volume)
                        } label: {
                            Text("\(volume.name) — \(Fmt.bytes(volume.availableCapacity)) liberi")
                        }
                    }
                }
            }

            if !internalVolumes.isEmpty {
                Section("Altri volumi") {
                    ForEach(internalVolumes) { volume in
                        Button(volume.name) { onChoose(volume) }
                    }
                }
            }

            Divider()
            Button("Scegli una cartella…") { onChoose(nil) }
        } label: {
            Label(selection == nil ? "Seleziona…" : "Cambia…", systemImage: "chevron.up.chevron.down")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(!isEnabled)
    }
}

struct CapacityBar: View {
    let volume: VolumeInfo
    var tint: Color = .accentColor

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.secondary.opacity(0.18))
                    Capsule()
                        .fill(tint.gradient)
                        .frame(width: max(3, geometry.size.width * volume.usedFraction))
                }
            }
            .frame(height: 7)

            Text("\(Fmt.bytes(volume.usedCapacity)) usati · \(Fmt.bytes(volume.availableCapacity)) liberi")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}

struct BadgeTag: View {
    let text: String
    let symbol: String
    var tint: Color = .secondary

    var body: some View {
        Label(text, systemImage: symbol)
            .font(.caption2)
            .foregroundStyle(tint)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Capsule().fill(tint.opacity(0.12)))
    }
}
