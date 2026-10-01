import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI

/// A QR code, drawn sharp at any size: one pixel per module from Core Image, scaled up
/// without smoothing.
struct QRCode: View {
    let text: String

    var body: some View {
        if let image {
            Image(decorative: image, scale: 1)
                .interpolation(.none)
                .resizable()
                .aspectRatio(1, contentMode: .fit)
                .padding(10)
                // A code is read dark on light, whatever the theme.
                .background(Color.white)
                .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }

    private var image: CGImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        return CIContext().createCGImage(output, from: output.extent)
    }
}
