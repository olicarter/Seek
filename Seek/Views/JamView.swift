import CoreImage
import SwiftUI

/// Listening together: starting a Jam on this device, then its link and QR code for guests,
/// who's in, what guests may do, and the queue with who added each song.
struct JamView: View {
    @Environment(JamSpeaker.self) private var speaker
    @Environment(\.dismiss) private var dismiss
    @AppStorage("jamHostName") private var hostName = ""

    var body: some View {
        NavigationStack {
            Group {
                if let jam = speaker.jam { session(jam) } else { starting }
            }
            .navigationTitle("Jam")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }

    private var starting: some View {
        Form {
            Section {
                TextField("Your Name", text: $hostName)
                    .textContentType(.givenName)
            } footer: {
                Text("Friends join from a link or QR code and add songs to the queue from your library or Soulseek. The music plays on this device. What's playing now carries on as the first song.")
            }
            Section {
                Button {
                    Task { await speaker.start(hostName: hostName.isEmpty ? "Host" : hostName) }
                } label: {
                    if speaker.isBusy { ProgressView() } else { Text("Start Jam") }
                }
                .disabled(!speaker.canStart || speaker.isBusy)
            } footer: {
                if let problem = speaker.problem {
                    Text(problem).foregroundStyle(.red)
                } else if !speaker.canStart {
                    Text("A Jam needs Seek running on your Mac, which friends join through.")
                }
            }
        }
    }

    private func session(_ jam: Jam) -> some View {
        List {
            Section {
                VStack(spacing: 12) {
                    if let code = QRCode.image(jam.link.absoluteString) {
                        code.interpolation(.none).resizable().scaledToFit()
                            .frame(width: 200, height: 200)
                            .padding(10)
                            .background(.white, in: .rect(cornerRadius: 12))
                    }
                    ShareLink(item: jam.link, subject: Text("Join my Jam"), message: Text("Add songs to what's playing")) {
                        Label("Share Link", systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity)
                .listRowBackground(Color.clear)
            } footer: {
                Text("Anyone with the link can join until you end the Jam, or for 12 hours.")
                    .frame(maxWidth: .infinity)
            }

            Section {
                Toggle("Guests Can Play, Pause and Skip", isOn: Binding(get: { jam.guestsCanControl }, set: { speaker.setGuestsCanControl($0) }))
                LabeledContent("In the Jam", value: jam.people.map(\.name).formatted(.list(type: .and)))
            }

            if let playing = jam.nowPlaying {
                Section("Now Playing") { row(playing, jam: jam) }
            }
            if !jam.upNext.isEmpty {
                Section("Up Next") {
                    ForEach(jam.upNext) { item in row(item, jam: jam) }
                        .onDelete { offsets in
                            let items = Array(jam.upNext)
                            offsets.forEach { speaker.remove(items[$0]) }
                        }
                }
            }

            Section {
                Button("End Jam", role: .destructive) { Task { await speaker.end() } }
                    .disabled(speaker.isBusy)
            }
        }
    }

    private func row(_ item: Jam.Item, jam: Jam) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(item.song.title).lineLimit(1)
            Text("\(item.song.artist) · added by \(jam.person(item.addedBy)?.name ?? "someone")")
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
    }
}

enum QRCode {
    static func image(_ text: String) -> Image? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(text.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage,
              let image = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return Image(decorative: image, scale: 1)
    }
}
