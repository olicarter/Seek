import CoreImage
import SwiftUI

/// Signing the TV in: it shows a code, approved on a phone (or any signed-in browser) at
/// 4n.studio/seek/web/tv, where your passkey is. The QR code opens that with the code filled in.
struct SignInView: View {
    @Environment(Connection.self) private var connection
    @State private var code: String?
    @State private var approveAt: URL?
    @State private var failed = false

    private struct Begun: Decodable { var code: String; var secret: String; var approveAt: String }
    private struct Poll: Decodable { var state: String; var session: String? }

    var body: some View {
        HStack(spacing: 80) {
            VStack(alignment: .leading, spacing: 28) {
                Text("Sign In to Seek").font(.largeTitle.bold())
                if let code {
                    Text("On your phone, open **4n.studio/seek/web/tv** and enter this code, or scan the QR code.")
                        .font(.title3).foregroundStyle(.secondary)
                    Text(code).font(.system(size: 96, weight: .bold, design: .monospaced))
                    Text("Seek on your Mac needs to be open.").foregroundStyle(.secondary)
                } else if failed {
                    Text("Can't reach Seek on the Mac. Check it's open, with Web turned on in its Settings.")
                        .font(.title3).foregroundStyle(.secondary)
                    Button("Try Again") { failed = false }
                } else {
                    ProgressView()
                }
            }
            .frame(maxWidth: 900, alignment: .leading)
            if let approveAt, let image = Self.qrCode(approveAt.absoluteString) {
                Image(uiImage: image).interpolation(.none).resizable().frame(width: 360, height: 360)
                    .padding(24).background(.white, in: .rect(cornerRadius: 24))
            }
        }
        .padding(80)
        .task(id: failed) {
            guard !failed else { return }
            await signIn()
        }
    }

    /// A code, then polling every two seconds until it's approved; a new code when it expires.
    private func signIn() async {
        while !Task.isCancelled {
            guard let begun: Begun = try? await connection.post("/api/auth/device/begin", ["name": "Apple TV"]) else {
                failed = true
                return
            }
            code = begun.code
            approveAt = URL(string: begun.approveAt)
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard let poll: Poll = try? await connection.post("/api/auth/device/poll", ["secret": begun.secret]) else { continue }
                if poll.state == "approved", let session = poll.session {
                    connection.signIn(session)
                    return
                }
                if poll.state == "expired" { break }
            }
        }
    }

    static func qrCode(_ text: String) -> UIImage? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(text.utf8), forKey: "inputMessage")
        guard let image = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 10, y: 10)),
              let cg = CIContext().createCGImage(image, from: image.extent) else { return nil }
        return UIImage(cgImage: cg)
    }
}
