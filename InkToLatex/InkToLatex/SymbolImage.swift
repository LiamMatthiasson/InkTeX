import CoreGraphics

/// One symbol as the CNN sees it: 32×32 numbers, row by row, top row first.
/// 0 = blank, 1 = ink. Used to make the training data AND in the app, so the
/// network always sees symbols drawn exactly the same way.
nonisolated func renderSymbol(_ strokes: [[Point]], size: Int = 32) -> [Float] {
    // --- YOUR PART: the geometry -------------------------------------------
    // 1. bounding box of all points (minX, maxX, minY, maxY)
    // 2. scale so the BIGGER side fills (size - 2 * margin) pixels
    // 3. offsets so the symbol sits in the middle of the box
    // 4. a function spot(p) -> CGPoint that applies scale and offset
    // ---------------------------------------------------------------------

    // Plumbing (given): a grayscale bitmap we can read the bytes of
    var pixels = [UInt8](repeating: 0, count: size * size)       // 0 = black…
    let context = pixels.withUnsafeMutableBytes { buffer in
        CGContext(data: buffer.baseAddress, width: size, height: size, bitsPerComponent: 8,
                  bytesPerRow: size, space: CGColorSpaceCreateDeviceGray(),
                  bitmapInfo: CGImageAlphaInfo.none.rawValue)
    }
    guard let context else { return [Float](repeating: 0, count: size * size) }
    // …so draw the BACKGROUND black and the INK white: pixel value 255 = ink
    context.setFillColor(gray: 0, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: size, height: size))
    context.setStrokeColor(gray: 1, alpha: 1)

    // --- YOUR PART: flip, line width, draw every stroke -------------------

    // ---------------------------------------------------------------------

    return pixels.map { Float($0) / 255 }    // 0…255 → 0…1
}
