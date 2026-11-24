import Foundation

/// A GIF89a encoder built for screen recordings, where most pixels don't change between frames.
///
/// `Differ` (sequential) decides what changed against what the viewer currently sees, with a
/// small tolerance that absorbs video compression noise. `encode` (parallel) stores only the
/// bounding box of the change; inside it, unchanged pixels are transparent so the previous frame
/// shows through (disposal "leave in place"). Each frame gets its own palette: exact when the
/// changed pixels have ≤ 255 colours (typical UI), otherwise exact entries for flat fills plus a
/// median cut with gentle Floyd–Steinberg dithering, so gradients don't band.
nonisolated enum GIF {
    /// Opaque RGBA8 pixels, row-major, top-left origin.
    struct Frame: Sendable {
        let pixels: [UInt32]
        let width: Int
        let height: Int
    }

    /// What one frame must draw: a rectangle, and which of its pixels changed.
    struct Delta: Sendable {
        let frame: Frame
        let x: Int, y: Int, width: Int, height: Int
        /// Row-major over the rectangle; nil means every pixel is drawn (first frame).
        let changed: [Bool]?
    }

    /// Tracks what the viewer sees and turns each new frame into the smallest `Delta`.
    ///
    /// Compares against the *displayed* reference, not the previous source frame, so small
    /// differences can't accumulate into drift. A pixel is redrawn when it moved more than
    /// `tolerance` (a real change), or when it moved at all and sits within `reach` pixels of a
    /// real change — that catches the soft anti-aliased edges of text and shapes, which would
    /// otherwise linger as faint ghosts, while isolated compression noise stays skipped.
    ///
    /// This is the only sequential stage of GIF encoding, so it is built for speed: eight pixels
    /// per SIMD step, rows split across cores, buffers reused, the reference updated in place.
    struct Differ {
        /// Max per-channel difference treated as noise when nothing real changed nearby.
        var tolerance: UInt8 = 3
        var reach = 1
        /// Smallest movement redrawn next to a real change (1 would redraw pure noise).
        var nearMin: UInt8 = 2
        private var reference: [UInt32] = []
        /// Per pixel: max channel difference to the reference (at least 1 when they differ).
        private var distance: [UInt8] = []
        /// Per pixel: a real change within `reach` on the same row.
        private var rowNear: [UInt8] = []

        /// nil when nothing visibly changed (the caller extends the previous frame instead).
        mutating func delta(_ frame: Frame) -> Delta? {
            let w = frame.width, h = frame.height
            guard reference.count == w * h else {
                reference = frame.pixels
                distance = [UInt8](repeating: 0, count: w * h)
                rowNear = [UInt8](repeating: 0, count: w * h)
                return Delta(frame: frame, x: 0, y: 0, width: w, height: h, changed: nil)
            }
            let tol = tolerance, reach = self.reach, nearMin = self.nearMin
            let bands = min(h, 4 * ProcessInfo.processInfo.activeProcessorCount)

            return frame.pixels.withUnsafeBufferPointer { cur in
                reference.withUnsafeMutableBufferPointer { ref in
                    distance.withUnsafeMutableBufferPointer { dist in
                        rowNear.withUnsafeMutableBufferPointer { near in
                            let p = Pointers(cur: cur.baseAddress!, ref: ref.baseAddress!, dist: dist.baseAddress!, near: near.baseAddress!)

                            // 1. Distances and, per band, the box around real changes.
                            let boxes = Boxes(UnsafeMutableBufferPointer<Box>.allocate(capacity: bands))
                            defer { boxes.buffer.deallocate() }
                            DispatchQueue.concurrentPerform(iterations: bands) { band in
                                var box = Box(minX: w, minY: h, maxX: -1, maxY: -1)
                                for y in (band * h / bands)..<((band + 1) * h / bands) {
                                    if let (lo, hi) = Self.distances(row: y, width: w, tolerance: tol, p) {
                                        box.minX = min(box.minX, lo); box.maxX = max(box.maxX, hi)
                                        box.minY = min(box.minY, y); box.maxY = y
                                    }
                                }
                                (boxes.buffer.baseAddress! + band).initialize(to: box)
                            }
                            var all = Box(minX: w, minY: h, maxX: -1, maxY: -1)
                            for box in boxes.buffer {
                                all.minX = min(all.minX, box.minX); all.maxX = max(all.maxX, box.maxX)
                                all.minY = min(all.minY, box.minY); all.maxY = max(all.maxY, box.maxY)
                            }
                            guard all.maxX >= 0 else { return nil }
                            let minX = max(0, all.minX - reach), maxX = min(w - 1, all.maxX + reach)
                            let minY = max(0, all.minY - reach), maxY = min(h - 1, all.maxY + reach)
                            let bw = maxX - minX + 1, bh = maxY - minY + 1

                            // 2. Real changes dilated along each row.
                            DispatchQueue.concurrentPerform(iterations: min(bh, bands)) { band in
                                for y in (minY + band * bh / min(bh, bands))..<(minY + (band + 1) * bh / min(bh, bands)) {
                                    let d = p.dist + y * w, n = p.near + y * w
                                    for x in minX...maxX { n[x] = 0 }
                                    for x in minX...maxX where d[x] > tol {
                                        for k in max(minX, x - reach)...min(maxX, x + reach) { n[k] = 1 }
                                    }
                                }
                            }

                            // 3. Draw what changed for real, plus any movement next to it (the row
                            //    dilation, dilated along columns); update the reference.
                            var changed = [Bool](repeating: false, count: bw * bh)
                            changed.withUnsafeMutableBufferPointer { out in
                                let o = Out(changed: out.baseAddress!)
                                DispatchQueue.concurrentPerform(iterations: min(bh, bands)) { band in
                                    for y in (minY + band * bh / min(bh, bands))..<(minY + (band + 1) * bh / min(bh, bands)) {
                                        let d = p.dist + y * w
                                        let y0 = max(minY, y - reach), y1 = min(maxY, y + reach)
                                        for x in minX...maxX {
                                            let dx = d[x]
                                            guard dx >= nearMin else { continue }
                                            var hit = dx > tol
                                            if !hit {
                                                var k = y0
                                                while k <= y1 { if p.near[k * w + x] != 0 { hit = true; break }; k += 1 }
                                            }
                                            if hit {
                                                o.changed[(y - minY) * bw + (x - minX)] = true
                                                p.ref[y * w + x] = p.cur[y * w + x]
                                            }
                                        }
                                    }
                                }
                            }
                            return Delta(frame: frame, x: minX, y: minY, width: bw, height: bh, changed: changed)
                        }
                    }
                }
            }
        }

        private struct Box { var minX: Int, minY: Int, maxX: Int, maxY: Int }
        private struct Boxes: @unchecked Sendable {
            let buffer: UnsafeMutableBufferPointer<Box>
            init(_ buffer: UnsafeMutableBufferPointer<Box>) { self.buffer = buffer }
        }

        /// Raw pointers handed to the parallel passes; each pass writes disjoint rows.
        private struct Pointers: @unchecked Sendable {
            let cur: UnsafePointer<UInt32>
            let ref: UnsafeMutablePointer<UInt32>
            let dist: UnsafeMutablePointer<UInt8>
            let near: UnsafeMutablePointer<UInt8>
        }

        private struct Out: @unchecked Sendable { let changed: UnsafeMutablePointer<Bool> }

        /// Fills one row of `dist`; returns the first and last x of a real change, if any.
        private static func distances(row y: Int, width w: Int, tolerance tol: UInt8, _ p: Pointers) -> (Int, Int)? {
            let a = p.cur + y * w, b = UnsafePointer(p.ref + y * w), d = p.dist + y * w
            var lo = -1, hi = -1
            var x = 0
            let byte = SIMD8<UInt32>(repeating: 0xFF), one = SIMD8<UInt32>(repeating: 1)
            let limit = SIMD8<UInt32>(repeating: UInt32(tol))
            while x + 8 <= w {
                let va = UnsafeRawPointer(a + x).loadUnaligned(as: SIMD8<UInt32>.self)
                let vb = UnsafeRawPointer(b + x).loadUnaligned(as: SIMD8<UInt32>.self)
                let differs = va .!= vb
                if !any(differs) {
                    UnsafeMutableRawPointer(d + x).storeBytes(of: SIMD8<UInt8>(repeating: 0), as: SIMD8<UInt8>.self)
                    x += 8
                    continue
                }
                func channel(_ shift: UInt32) -> SIMD8<UInt32> {
                    let ca = (va &>> shift) & byte, cb = (vb &>> shift) & byte
                    return pointwiseMax(ca, cb) &- pointwiseMin(ca, cb)
                }
                var m = pointwiseMax(pointwiseMax(channel(0), channel(8)), channel(16))
                m.replace(with: pointwiseMax(m, one), where: differs)
                UnsafeMutableRawPointer(d + x).storeBytes(of: SIMD8<UInt8>(truncatingIfNeeded: m), as: SIMD8<UInt8>.self)
                let real = m .> limit
                if any(real) {
                    for i in 0..<8 where real[i] {
                        if lo < 0 { lo = x + i }
                        hi = x + i
                    }
                }
                x += 8
            }
            while x < w {
                let ca = a[x], cb = b[x]
                var dx: UInt8 = 0
                if ca != cb {
                    let dr = UInt8(abs(Int16(ca & 0xFF) - Int16(cb & 0xFF)))
                    let dg = UInt8(abs(Int16((ca >> 8) & 0xFF) - Int16((cb >> 8) & 0xFF)))
                    let db = UInt8(abs(Int16((ca >> 16) & 0xFF) - Int16((cb >> 16) & 0xFF)))
                    dx = max(dr, dg, db, 1)
                    if dx > tol { if lo < 0 { lo = x }; hi = x }
                }
                d[x] = dx
                x += 1
            }
            return lo >= 0 ? (lo, hi) : nil
        }
    }

    /// Streams a looping GIF to disk. Frames must be appended in order.
    final class Writer {
        private let handle: FileHandle

        init(url: URL, width: Int, height: Int) throws {
            FileManager.default.createFile(atPath: url.path, contents: nil)
            handle = try FileHandle(forWritingTo: url)
            var header = Data("GIF89a".utf8)
            header.appendLE16(width); header.appendLE16(height)
            header.append(contentsOf: [0x00, 0x00, 0x00])            // no global table
            header.append(contentsOf: [0x21, 0xFF, 0x0B])            // NETSCAPE2.0: loop forever
            header.append(contentsOf: Array("NETSCAPE2.0".utf8))
            header.append(contentsOf: [0x03, 0x01, 0x00, 0x00, 0x00])
            try handle.write(contentsOf: header)
        }

        func append(_ encoded: Data) throws { try handle.write(contentsOf: encoded) }

        func finish() throws {
            try handle.write(contentsOf: Data([0x3B]))
            try handle.close()
        }
    }

    /// One frame as GIF bytes (control extension + image), shown for `centiseconds`.
    static func encode(_ delta: Delta, centiseconds: Int) -> Data {
        let w = delta.frame.width
        let (bx, by, bw, bh) = (delta.x, delta.y, delta.width, delta.height)

        // Gather the rectangle; unchanged pixels become the transparent marker.
        let transparentMarker: UInt32 = 1 << 24
        var region = [UInt32](repeating: 0, count: bw * bh)
        var usesTransparency = false
        delta.frame.pixels.withUnsafeBufferPointer { cur in
            for y in 0..<bh {
                let row = (by + y) * w + bx
                for x in 0..<bw {
                    if let changed = delta.changed, !changed[y * bw + x] {
                        region[y * bw + x] = transparentMarker
                        usesTransparency = true
                    } else {
                        region[y * bw + x] = cur[row + x] & 0x00FF_FFFF
                    }
                }
            }
        }

        let maxColors = usesTransparency ? 255 : 256
        let (palette, indices) = exactPalette(region, limit: maxColors, marker: transparentMarker)
            ?? quantize(region, width: bw, height: bh, colors: maxColors, marker: transparentMarker)
        let transparentIndex = palette.count            // slot after the colours

        let entries = palette.count + (usesTransparency ? 1 : 0)
        var bits = 1
        while (1 << bits) < entries { bits += 1 }

        var out = Data()
        out.reserveCapacity(bw * bh / 2)
        // Graphic control extension: disposal 1 (leave in place), optional transparency.
        out.append(contentsOf: [0x21, 0xF9, 0x04, UInt8(1 << 2) | (usesTransparency ? 1 : 0)])
        out.appendLE16(centiseconds)
        out.append(UInt8(usesTransparency ? transparentIndex : 0))
        out.append(0x00)
        // Image descriptor with a local colour table.
        out.append(0x2C)
        out.appendLE16(bx); out.appendLE16(by); out.appendLE16(bw); out.appendLE16(bh)
        out.append(0x80 | UInt8(bits - 1))
        for i in 0..<(1 << bits) {
            let c = i < palette.count ? palette[i] : 0
            out.append(contentsOf: [UInt8(c & 0xFF), UInt8((c >> 8) & 0xFF), UInt8((c >> 16) & 0xFF)])
        }
        let mapped = usesTransparency
            ? zip(region, indices).map { $0 == transparentMarker ? UInt8(transparentIndex) : $1 }
            : indices
        lzw(mapped, minCodeSize: max(2, bits), into: &out)
        return out
    }

    // MARK: palette

    /// When the region has few colours (UI, text on flat backgrounds), use them exactly: lossless.
    private static func exactPalette(_ region: [UInt32], limit: Int, marker: UInt32) -> ([UInt32], [UInt8])? {
        var lookup: [UInt32: UInt8] = [:]
        var palette: [UInt32] = []
        var indices = [UInt8](repeating: 0, count: region.count)
        var last: UInt32 = .max, lastIndex: UInt8 = 0
        for (i, c) in region.enumerated() where c != marker {
            if c == last { indices[i] = lastIndex; continue }
            let index: UInt8
            if let known = lookup[c] {
                index = known
            } else {
                guard palette.count < limit else { return nil }
                index = UInt8(palette.count)
                lookup[c] = index
                palette.append(c)
            }
            indices[i] = index
            last = c; lastIndex = index
        }
        return (palette.isEmpty ? [0] : palette, indices)
    }

    /// Palette for many-colour regions. Flat colours that cover real area (backgrounds, UI fills)
    /// get exact entries, so they map losslessly and never pick up dither noise; the remaining
    /// slots come from a median cut over a 5-bit-per-channel histogram of everything else.
    /// Mapping is Floyd–Steinberg (serpentine, 3/4 strength) through a 6-bit nearest-colour cache.
    private static func quantize(_ region: [UInt32], width: Int, height: Int, colors: Int, marker: UInt32) -> ([UInt32], [UInt8]) {
        // Histogram, remembering whether each bin holds one exact colour.
        var count = [Int32](repeating: 0, count: 1 << 15)
        var sum = [SIMD3<Int64>](repeating: .zero, count: 1 << 15)
        var first = [UInt32](repeating: 0, count: 1 << 15)
        var pure = [Bool](repeating: true, count: 1 << 15)
        var total = 0
        for c in region where c != marker {
            let r = Int(c & 0xFF), g = Int((c >> 8) & 0xFF), b = Int((c >> 16) & 0xFF)
            let k = (r >> 3) << 10 | (g >> 3) << 5 | (b >> 3)
            if count[k] == 0 { first[k] = c } else if pure[k], first[k] != c { pure[k] = false }
            count[k] += 1
            sum[k] &+= SIMD3(Int64(r), Int64(g), Int64(b))
            total += 1
        }
        var bins: [Int] = (0..<(1 << 15)).filter { count[$0] > 0 }

        // Dominant bins (≥ 0.2 % of the region; at most a quarter of the palette) get their own
        // entry — exact if the bin holds one colour, else its average — and every pixel in them
        // maps there directly, without dithering. Backgrounds and fills stay calm and clean
        // (video noise within a bin is ≤ 4 levels), and never leave dither texture behind.
        let floor = max(16, total / 500)
        let dominant = bins.filter { Int(count[$0]) >= floor }
            .sorted { count[$0] > count[$1] }
            .prefix(colors / 4)
        var reserved = [Int16](repeating: -1, count: 1 << 15)
        var palette: [UInt32] = []
        for k in dominant {
            reserved[k] = Int16(palette.count)
            if pure[k] {
                palette.append(first[k])
            } else {
                let avg = sum[k] / Int64(count[k])
                palette.append(UInt32(avg.x) | UInt32(avg.y) << 8 | UInt32(avg.z) << 16)
            }
        }
        bins.removeAll { reserved[$0] >= 0 }

        // Boxes are ranges of `bins`; split the one with the most pixels × widest channel.
        struct Box { var lo: Int; var hi: Int; var pixels: Int64; var spread: Int; var axis: Int }
        func measure(_ lo: Int, _ hi: Int) -> Box {
            var mn = SIMD3<Int>(repeating: 31), mx = SIMD3<Int>(repeating: 0), px: Int64 = 0
            for i in lo..<hi {
                let k = bins[i]
                let v = SIMD3(k >> 10, (k >> 5) & 31, k & 31)
                mn = pointwiseMin(mn, v); mx = pointwiseMax(mx, v)
                px += Int64(count[k])
            }
            let d = mx &- mn
            let axis = d.x >= d.y && d.x >= d.z ? 0 : (d.y >= d.z ? 1 : 2)
            return Box(lo: lo, hi: hi, pixels: px, spread: d[axis], axis: axis)
        }
        var boxes = bins.isEmpty ? [] : [measure(0, bins.count)]
        while !boxes.isEmpty, boxes.count < colors - palette.count {
            guard let pick = boxes.indices.filter({ boxes[$0].hi - boxes[$0].lo > 1 })
                .max(by: { boxes[$0].pixels * Int64(boxes[$0].spread + 1) < boxes[$1].pixels * Int64(boxes[$1].spread + 1) })
            else { break }
            let box = boxes[pick]
            let shift = [10, 5, 0][box.axis]
            bins[box.lo..<box.hi].sort { ($0 >> shift) & 31 < ($1 >> shift) & 31 }
            var acc: Int64 = 0, cut = box.lo + 1
            for i in box.lo..<box.hi {
                acc += Int64(count[bins[i]])
                if acc * 2 >= box.pixels { cut = min(max(i + 1, box.lo + 1), box.hi - 1); break }
            }
            boxes[pick] = measure(box.lo, cut)
            boxes.append(measure(cut, box.hi))
        }
        palette += boxes.map { box in
            var s = SIMD3<Int64>.zero, n: Int64 = 0
            for i in box.lo..<box.hi { s &+= sum[bins[i]]; n += Int64(count[bins[i]]) }
            let avg = s / max(n, 1)
            return UInt32(avg.x) | UInt32(avg.y) << 8 | UInt32(avg.z) << 16
        }
        if palette.isEmpty { palette = [0] }
        let pr = palette.map { Int($0 & 0xFF) }, pg = palette.map { Int(($0 >> 8) & 0xFF) }, pb = palette.map { Int(($0 >> 16) & 0xFF) }

        var cache = [Int16](repeating: -1, count: 1 << 18)
        func nearest(_ r: Int, _ g: Int, _ b: Int) -> Int {
            let key = (r >> 2) << 12 | (g >> 2) << 6 | (b >> 2)
            if cache[key] >= 0 { return Int(cache[key]) }
            var best = 0, bestD = Int.max
            for i in 0..<palette.count {
                let dr = pr[i] - r, dg = pg[i] - g, db = pb[i] - b
                let d = 3 * dr * dr + 4 * dg * dg + 2 * db * db
                if d < bestD { bestD = d; best = i }
            }
            cache[key] = Int16(best)
            return best
        }

        // Error rows in 1/16 units, with a 1-px border on each side.
        var indices = [UInt8](repeating: 0, count: region.count)
        var errCur = [SIMD3<Int32>](repeating: .zero, count: width + 2)
        var errNext = errCur
        for y in 0..<height {
            let leftToRight = y % 2 == 0
            for step in 0..<width {
                let x = leftToRight ? step : width - 1 - step
                let i = y * width + x
                let c = region[i]
                guard c != marker else { continue }
                let bin = Int((c & 0xFF) >> 3) << 10 | Int((c >> 11) & 0x1F) << 5 | Int((c >> 19) & 0x1F)
                if reserved[bin] >= 0 {                             // dominant colour: direct, no dither
                    indices[i] = UInt8(reserved[bin])
                    errCur[x + 1] = .zero
                    continue
                }
                let e = errCur[x + 1] / 16
                let r = clamp(Int(c & 0xFF) + Int(e.x)), g = clamp(Int((c >> 8) & 0xFF) + Int(e.y)), b = clamp(Int((c >> 16) & 0xFF) + Int(e.z))
                let k = nearest(r, g, b)
                indices[i] = UInt8(k)
                // 3/4 strength: keeps flat areas calm while gradients stay smooth.
                let q = SIMD3<Int32>(Int32(r - pr[k]), Int32(g - pg[k]), Int32(b - pb[k])) &* 3 / 4
                let fwd = leftToRight ? 1 : -1
                errCur[x + 1 + fwd] &+= q &* 7
                errNext[x + 1 - fwd] &+= q &* 3
                errNext[x + 1] &+= q &* 5
                errNext[x + 1 + fwd] &+= q
            }
            swap(&errCur, &errNext)
            for j in errNext.indices { errNext[j] = .zero }
        }
        return (palette, indices)
    }

    private static func clamp(_ v: Int) -> Int { min(255, max(0, v)) }

    // MARK: LZW

    /// GIF-flavoured LZW (variable code width up to 12 bits), written as 255-byte sub-blocks.
    private static func lzw(_ indices: [UInt8], minCodeSize: Int, into out: inout Data) {
        out.append(UInt8(minCodeSize))
        let clear = 1 << minCodeSize, end = clear + 1
        var codeSize = minCodeSize + 1
        var next = end + 1

        // Open-addressing table: key = prefix << 8 | byte, value = code.
        let tableSize = 5003
        var keys = [Int32](repeating: -1, count: tableSize)
        var values = [Int16](repeating: 0, count: tableSize)

        var block = [UInt8](), bitBuffer: UInt32 = 0, bitCount = 0
        block.reserveCapacity(255)
        func emit(_ code: Int) {
            bitBuffer |= UInt32(code) << UInt32(bitCount)
            bitCount += codeSize
            while bitCount >= 8 {
                block.append(UInt8(bitBuffer & 0xFF))
                bitBuffer >>= 8; bitCount -= 8
                if block.count == 255 { out.append(255); out.append(contentsOf: block); block.removeAll(keepingCapacity: true) }
            }
        }

        emit(clear)
        guard var prefix = indices.first.map(Int.init) else { emit(end); return }
        for byte in indices.dropFirst() {
            let key = Int32(prefix << 8 | Int(byte))
            var slot = Int(key) % tableSize
            var found = -1
            while keys[slot] != -1 {
                if keys[slot] == key { found = Int(values[slot]); break }
                slot = slot == 0 ? tableSize - 1 : slot - 1
            }
            if found >= 0 { prefix = found; continue }
            emit(prefix)
            if next < 4096 {
                keys[slot] = key; values[slot] = Int16(next)
                if next == (1 << codeSize) { codeSize += 1 }
                next += 1
            } else {
                emit(clear)
                for j in keys.indices { keys[j] = -1 }
                codeSize = minCodeSize + 1
                next = end + 1
            }
            prefix = Int(byte)
        }
        emit(prefix)
        emit(end)
        if bitCount > 0 { block.append(UInt8(bitBuffer & 0xFF)) }
        if !block.isEmpty { out.append(UInt8(block.count)); out.append(contentsOf: block) }
        out.append(0x00)
    }
}

nonisolated private extension Data {
    mutating func appendLE16(_ v: Int) {
        append(UInt8(v & 0xFF)); append(UInt8((v >> 8) & 0xFF))
    }
}
