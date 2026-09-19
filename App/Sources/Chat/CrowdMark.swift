import SwiftUI

/// The mark on its own, without the icon's ground.
///
/// Drawn rather than loaded, so it takes the colour it is given, has real holes for the
/// eyes instead of holes painted the colour of whatever is behind it, and stays sharp
/// at any size. The geometry is the icon's, in the icon's 512 space.
struct CrowdMark: View {
    var body: some View {
        Canvas { context, size in
            // The drawing's own bounds in the icon's 512 space, fitted to whatever
            // frame it is given and centred in it. Scaling by the canvas instead
            // leaves the mark in a corner of its own box.
            let design = CGRect(x: 56, y: 104, width: 398, height: 284.32)
            let scale = min(size.width / design.width, size.height / design.height)
            let originX = (size.width - design.width * scale) / 2 - design.minX * scale
            let originY = (size.height - design.height * scale) / 2 - design.minY * scale

            func place(_ rect: CGRect) -> CGRect {
                CGRect(x: originX + rect.minX * scale, y: originY + rect.minY * scale,
                       width: rect.width * scale, height: rect.height * scale)
            }

            /// A head, with its eyes taken out of it rather than painted over it.
            func head(x: CGFloat, y: CGFloat, side: CGFloat, opacity: CGFloat) {
                let body = Path(roundedRect: place(CGRect(x: x, y: y, width: side, height: side * 0.86)),
                                cornerRadius: side * 0.30 * scale)
                context.fill(body, with: .color(.primary.opacity(opacity)))
                for dx in [0.33, 0.67] as [CGFloat] {
                    let r = side * 0.085
                    let eye = Path(ellipseIn: place(CGRect(x: x + side * dx - r, y: y + side * 0.45 - r,
                                                           width: r * 2, height: r * 2)))
                    context.blendMode = .destinationOut
                    context.fill(eye, with: .color(.black))
                    context.blendMode = .normal
                }
            }

            // The two behind, then a gap cut around the one in front so their edges
            // survive, then the one in front. A sliver beside a head is an ear.
            head(x: 56, y: 104, side: 148, opacity: 0.45)
            head(x: 306, y: 104, side: 148, opacity: 0.7)

            let gap: CGFloat = 212 * 0.04
            let surround = Path(roundedRect: place(CGRect(x: 150 - gap, y: 206 - gap,
                                                          width: 212 + gap * 2, height: 212 * 0.86 + gap * 2)),
                                cornerRadius: (212 * 0.30 + gap) * scale)
            context.blendMode = .destinationOut
            context.fill(surround, with: .color(.black))
            context.blendMode = .normal

            head(x: 150, y: 206, side: 212, opacity: 1)
        }
        .aspectRatio(398.0 / 284.32, contentMode: .fit)
        .accessibilityHidden(true)
    }
}
