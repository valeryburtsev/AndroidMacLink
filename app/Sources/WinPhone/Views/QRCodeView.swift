import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI

/// Renders text as a QR code with crisp module edges at any size.
struct QRCodeView: View {
    let text: String

    var body: some View {
        if let image = QRCodeView.makeImage(text) {
            Image(decorative: image, scale: 1)
                .interpolation(.none)
                .resizable()
                .aspectRatio(1, contentMode: .fit)
                .padding(12)
                .background(Color.white, in: RoundedRectangle(cornerRadius: 12))
                .accessibilityLabel("QR code for linking your phone")
        } else {
            ContentUnavailableView("Could not draw the code", systemImage: "qrcode")
        }
    }

    static func makeImage(_ text: String) -> CGImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        return CIContext().createCGImage(output, from: output.extent)
    }
}
