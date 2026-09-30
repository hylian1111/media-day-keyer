// mdkeyer — the engine behind the Media Day Keyer Lightroom plugin.
//
// Lightroom exports each photo to key into <work>/inbox and then writes <photo>.json next to
// it ({"out": "<folder>", "psd": true|false}); the .json is the signal the export finished.
// For each photo:
//   1. Photoshop Select Subject          -> the cut-out edge          (jsx/select_subject.jsx)
//   2. Apple Vision person-instance masks -> who each pixel belongs to (max 4 people)
//   3. split the cut-out per person, left to right
//   4. strip backdrop colour from semi-transparent edge pixels (no white halo)
//   5. full-frame PNG per person -> <out>/PNG, optional layered PSD -> <out>/PSD (jsx/build_psd.jsx)
//
// usage:
//   mdkeyer next    --work DIR                         key the oldest finished export (exit 3 if none)
//   mdkeyer process PHOTO --out DIR [--psd] [--work DIR]  key any photo directly (testing, re-runs)

import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers
import Vision

// MARK: - setup

struct KeyerError: Error, CustomStringConvertible {
    let description: String
    init(_ d: String) { description = d }
}

let minPersonArea = 0.004   // a person must cover 0.4% of the frame to get a PNG

let binDir = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().deletingLastPathComponent()
let jsxDir = binDir.deletingLastPathComponent().appendingPathComponent("jsx")

var workDir = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/Media Day Keyer")

func log(_ msg: String) {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd HH:mm:ss"
    let line = "\(f.string(from: Date()))  \(msg)\n"
    print(line, terminator: "")
    let url = workDir.appendingPathComponent("keyer.log")
    if let h = try? FileHandle(forWritingTo: url) {
        h.seekToEndOfFile()
        h.write(line.data(using: .utf8)!)
        try? h.close()
    } else {
        try? line.write(to: url, atomically: true, encoding: .utf8)
    }
}

// MARK: - Photoshop

func photoshop(_ jsx: String, _ job: [String: Any], scratch: URL) throws -> String {
    let jobJSON = String(data: try JSONSerialization.data(withJSONObject: job), encoding: .utf8)!
    let script = jsxDir.appendingPathComponent(jsx).path
    let wrapper = scratch.appendingPathComponent((jsx as NSString).deletingPathExtension + ".run.jsx")
    let scriptLiteral = String(data: try JSONSerialization.data(withJSONObject: [script]), encoding: .utf8)!.dropFirst().dropLast()
    try "var JOB = \(jobJSON);\n$.evalFile(new File(\(scriptLiteral)));\n".write(to: wrapper, atomically: true, encoding: .utf8)

    let wrapperLiteral = wrapper.path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    let apple = """
    with timeout of 1800 seconds
     tell application id "com.adobe.Photoshop" to do javascript file (POSIX file "\(wrapperLiteral)")
    end timeout
    """
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    p.arguments = ["-e", apple]
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = pipe
    try p.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    let out = (String(data: data, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    if out.contains("-1743") {
        throw KeyerError("macOS blocked Lightroom from controlling Photoshop. Allow it in System Settings > "
                         + "Privacy & Security > Automation (Adobe Lightroom Classic > Adobe Photoshop).")
    }
    if out.contains("-600") || out.contains("-1728") {
        throw KeyerError("couldn't reach Photoshop — is it installed? (\(out))")
    }
    return out
}

// MARK: - pixels

struct Photo {
    let width: Int, height: Int
    var rgb: [UInt8]           // RGBX, 4 bytes per pixel
    let colorSpace: CGColorSpace
    let properties: [String: Any]
}

func loadPhoto(_ url: URL) throws -> Photo {
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
          let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else { throw KeyerError("can't read \(url.lastPathComponent)") }
    let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [String: Any] ?? [:]
    if let o = props[kCGImagePropertyOrientation as String] as? Int, o != 1 {
        throw KeyerError("\(url.lastPathComponent) has EXIF rotation \(o); export it from Lightroom so the rotation is baked in")
    }
    var cs = cg.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
    if cs.model != .rgb { cs = CGColorSpace(name: CGColorSpace.sRGB)! }
    let w = cg.width, h = cg.height
    var buf = [UInt8](repeating: 0, count: w * h * 4)
    try buf.withUnsafeMutableBytes { raw in
        guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: cs, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw KeyerError("can't decode \(url.lastPathComponent)")
        }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
    }
    return Photo(width: w, height: h, rgb: buf, colorSpace: cs, properties: props)
}

func loadGray(_ url: URL) throws -> (Int, Int, [UInt8]) {
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
          let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else { throw KeyerError("can't read \(url.lastPathComponent)") }
    let w = cg.width, h = cg.height
    var buf = [UInt8](repeating: 0, count: w * h)
    try buf.withUnsafeMutableBytes { raw in
        guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else {
            throw KeyerError("can't decode \(url.lastPathComponent)")
        }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
    }
    return (w, h, buf)
}

func writeGrayPNG(_ px: [UInt8], _ w: Int, _ h: Int, to url: URL) throws {
    let provider = CGDataProvider(data: Data(px) as CFData)!
    guard let img = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: w,
                            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: 0),
                            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent),
          let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
    else { throw KeyerError("can't write \(url.lastPathComponent)") }
    CGImageDestinationAddImage(dest, img, nil)
    guard CGImageDestinationFinalize(dest) else { throw KeyerError("can't write \(url.lastPathComponent)") }
}

func writeCutoutPNG(_ photo: Photo, _ clean: [UInt8], _ alpha: [UInt8], to url: URL) throws {
    let n = photo.width * photo.height
    var px = [UInt8](repeating: 0, count: n * 4)
    px.withUnsafeMutableBufferPointer { o in
        clean.withUnsafeBufferPointer { c in
            alpha.withUnsafeBufferPointer { a in
                for i in 0..<n where a[i] > 0 {   // colour under fully transparent pixels stays 0: ~5x smaller files
                    o[i * 4] = c[i * 4]; o[i * 4 + 1] = c[i * 4 + 1]; o[i * 4 + 2] = c[i * 4 + 2]; o[i * 4 + 3] = a[i]
                }
            }
        }
    }
    let provider = CGDataProvider(data: Data(px) as CFData)!
    guard let img = CGImage(width: photo.width, height: photo.height, bitsPerComponent: 8, bitsPerPixel: 32,
                            bytesPerRow: photo.width * 4, space: photo.colorSpace,
                            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent),
          let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
    else { throw KeyerError("can't write \(url.lastPathComponent)") }
    var meta: [String: Any] = [:]
    for key in [kCGImagePropertyExifDictionary, kCGImagePropertyTIFFDictionary, kCGImagePropertyIPTCDictionary] {
        if let d = photo.properties[key as String] { meta[key as String] = d }
    }
    if var tiff = meta[kCGImagePropertyTIFFDictionary as String] as? [String: Any] {
        tiff[kCGImagePropertyTIFFOrientation as String] = 1
        meta[kCGImagePropertyTIFFDictionary as String] = tiff
    }
    CGImageDestinationAddImage(dest, img, meta as CFDictionary)
    guard CGImageDestinationFinalize(dest) else { throw KeyerError("can't write \(url.lastPathComponent)") }
}

// MARK: - Vision

func personMasks(_ url: URL) throws -> [[UInt8]] {
    let handler = VNImageRequestHandler(url: url, options: [:])
    let request = VNGeneratePersonInstanceMaskRequest()
    try handler.perform([request])
    guard let obs = request.results?.first else { return [] }
    let ctx = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])
    var masks: [[UInt8]] = []
    for idx in obs.allInstances.sorted() {
        let pb = try obs.generateScaledMaskForImage(forInstances: IndexSet(integer: idx), from: handler)
        let ci = CIImage(cvPixelBuffer: pb)
        let w = Int(ci.extent.width), h = Int(ci.extent.height)
        var buf = [UInt8](repeating: 0, count: w * h)
        buf.withUnsafeMutableBytes { raw in
            ctx.render(ci, toBitmap: raw.baseAddress!, rowBytes: w, bounds: ci.extent, format: .L8, colorSpace: nil)
        }
        masks.append(buf)
    }
    return masks
}

// MARK: - splitting the cut-out into people

/// Multi-source breadth-first flood on a small grid. Seeds keep their label; unlabelled cells
/// that `canEnter` get the label of whichever seed reaches them first.
func flood(_ labels: inout [UInt8], _ w: Int, _ h: Int, eightWay: Bool, canEnter: (Int) -> Bool) {
    var queue = [Int]()
    queue.reserveCapacity(w * h)
    for i in 0..<(w * h) where labels[i] > 0 { queue.append(i) }
    var head = 0
    let steps4 = [(-1, 0), (1, 0), (0, -1), (0, 1)]
    let steps8 = steps4 + [(-1, -1), (1, -1), (-1, 1), (1, 1)]
    let steps = eightWay ? steps8 : steps4
    while head < queue.count {
        let i = queue[head]; head += 1
        let x = i % w, y = i / w
        for (dx, dy) in steps {
            let nx = x + dx, ny = y + dy
            if nx < 0 || ny < 0 || nx >= w || ny >= h { continue }
            let j = ny * w + nx
            if labels[j] == 0 && canEnter(j) { labels[j] = labels[i]; queue.append(j) }
        }
    }
}

func splitPeople(subject: [UInt8], masks: [[UInt8]], w: Int, h: Int) -> ([[UInt8]], String) {
    if masks.isEmpty { return ([subject], "no person detected by Vision; kept Photoshop's selection as one PNG") }
    let n = w * h

    // who each pixel belongs to, where Vision is confident
    var owner = [UInt8](repeating: 0, count: n)
    for i in 0..<n {
        var best = 0, bestV: UInt8 = 0
        for (k, m) in masks.enumerated() where m[i] > bestV { bestV = m[i]; best = k }
        if bestV >= 128 { owner[i] = UInt8(best + 1) }
    }

    // The rest on a small copy: which blobs of the cut-out touch a person at all (loose objects
    // that don't are dropped), and which person owns the edge pixels Vision didn't cover (hair,
    // fingertips, a held ball). Ownership floods outward from each person *through the cut-out*,
    // so a prop goes to the person holding it, not whoever happens to be nearest.
    let f = max(1, Int((Double(max(w, h)) / 1500).rounded()))
    let sw = (w + f - 1) / f, sh = (h + f - 1) / f, sn = sw * sh
    var sub = [Bool](repeating: false, count: sn)
    var own = [UInt8](repeating: 0, count: sn)
    for y in 0..<sh { for x in 0..<sw {
        let i = y * f * w + x * f
        sub[y * sw + x] = subject[i] > 32
        own[y * sw + x] = owner[i]
    } }

    // connected blobs of the cut-out (4-way), and whether each touches a person
    var blob = [Int32](repeating: 0, count: sn)
    var touches: [Bool] = [false]
    var stack = [Int]()
    for s in 0..<sn where sub[s] && blob[s] == 0 {
        let id = Int32(touches.count); touches.append(false)
        blob[s] = id; stack.append(s)
        while let i = stack.popLast() {
            if own[i] > 0 { touches[Int(id)] = true }
            let x = i % sw, y = i / sw
            for (nx, ny) in [(x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)] where nx >= 0 && ny >= 0 && nx < sw && ny < sh {
                let j = ny * sw + nx
                if sub[j] && blob[j] == 0 { blob[j] = id; stack.append(j) }
            }
        }
    }
    let dropped = touches.dropFirst().filter { !$0 }.count
    var keep = (0..<sn).map { blob[$0] > 0 && touches[Int(blob[$0])] }
    for _ in 0..<3 {   // grow by a few cells so the soft outer edge isn't clipped
        let prev = keep
        for i in 0..<sn where !prev[i] {
            let x = i % sw, y = i / sw
            if (x > 0 && prev[i - 1]) || (x < sw - 1 && prev[i + 1]) || (y > 0 && prev[i - sw]) || (y < sh - 1 && prev[i + sw]) {
                keep[i] = true
            }
        }
    }

    var owned = own
    flood(&owned, sw, sh, eightWay: false) { sub[$0] }
    // edge cells just outside the small copy's cut-out still need an owner: nearest person
    if owned.contains(where: { $0 > 0 }) { flood(&owned, sw, sh, eightWay: true) { _ in true } }

    var people: [(Double, [UInt8])] = []
    for k in 1...masks.count {
        let kk = UInt8(k)
        var a = [UInt8](repeating: 0, count: n)
        var solid = 0, minX = w, maxX = -1
        for y in 0..<h {
            let sy = (y / f) * sw
            for x in 0..<w {
                let i = y * w + x
                let s = sy + x / f
                let who = owner[i] > 0 ? owner[i] : owned[s]
                if who == kk && keep[s] && subject[i] > 0 {
                    a[i] = subject[i]
                    if subject[i] > 127 { solid += 1; if x < minX { minX = x }; if x > maxX { maxX = x } }
                }
            }
        }
        if Double(solid) / Double(n) < minPersonArea { continue }
        people.append((Double(minX + maxX) / 2, a))
    }
    if people.isEmpty { return ([subject], "Vision's people didn't match Photoshop's selection; kept it as one PNG") }
    people.sort { $0.0 < $1.0 }
    var note = "\(people.count) person(s)"
    if dropped > 0 { note += ", dropped \(dropped) loose object(s) not touching anyone" }
    return (people.map { $0.1 }, note)
}

// MARK: - edge colour clean-up

/// Separable Gaussian blur, sigma in cells, edges reflected (matches scipy's default).
func gaussian(_ src: [Float], _ w: Int, _ h: Int, sigma: Float) -> [Float] {
    let r = Int(4 * sigma + 0.5)
    var k = (-r...r).map { exp(-Float($0 * $0) / (2 * sigma * sigma)) }
    let sum = k.reduce(0, +); k = k.map { $0 / sum }
    func reflect(_ i: Int, _ n: Int) -> Int {
        var i = i
        while i < 0 || i >= n { i = i < 0 ? -i - 1 : 2 * n - i - 1 }
        return i
    }
    var tmp = [Float](repeating: 0, count: w * h), out = tmp
    for y in 0..<h { for x in 0..<w {
        var s: Float = 0
        for t in -r...r { s += k[t + r] * src[y * w + reflect(x + t, w)] }
        tmp[y * w + x] = s
    } }
    for y in 0..<h { for x in 0..<w {
        var s: Float = 0
        for t in -r...r { s += k[t + r] * tmp[reflect(y + t, h) * w + x] }
        out[y * w + x] = s
    } }
    return out
}

/// Remove backdrop colour from semi-transparent edge pixels (hair, soft edges), like Photoshop's
/// Decontaminate Colors. Without it a cut-out shot on white keeps a faint white halo on a dark
/// graphic. The backdrop colour is estimated locally from the surrounding transparent area, so
/// uneven light and falloff on the backdrop are handled.
func decontaminate(_ photo: Photo, subject: [UInt8]) -> [UInt8] {
    let w = photo.width, h = photo.height
    let f = max(1, Int((Double(max(w, h)) / 750).rounded()))
    let sw = (w + f - 1) / f, sh = (h + f - 1) / f, sn = sw * sh
    var bg = [Float](repeating: 0, count: sn)
    var chans = [[Float]](repeating: [Float](repeating: 0, count: sn), count: 3)
    var hist = [[Int]](repeating: [Int](repeating: 0, count: 256), count: 3)
    var bgCount = 0
    for y in 0..<sh { for x in 0..<sw {
        let i = y * f * w + x * f, s = y * sw + x
        if subject[i] < 8 {
            bg[s] = 1; bgCount += 1
            for c in 0..<3 {
                let v = photo.rgb[i * 4 + c]
                chans[c][s] = Float(v); hist[c][Int(v)] += 1
            }
        }
    } }
    var fallback: [Float] = [255, 255, 255]
    if bgCount > 0 {
        for c in 0..<3 {
            var acc = 0
            for v in 0..<256 { acc += hist[c][v]; if acc * 2 >= bgCount { fallback[c] = Float(v); break } }
        }
    }
    let den = gaussian(bg, sw, sh, sigma: 12)
    let backdrop = (0..<3).map { c -> [Float] in
        let num = gaussian(chans[c], sw, sh, sigma: 12)
        return (0..<sn).map { den[$0] > 1e-3 ? num[$0] / max(den[$0], 1e-6) : fallback[c] }
    }

    var out = photo.rgb
    for y in 0..<h {
        let sy = min(y / f, sh - 1) * sw
        for x in 0..<w {
            let i = y * w + x
            let s = subject[i]
            if s == 0 || s >= 250 { continue }
            let a = Float(s) / 255, bs = sy + min(x / f, sw - 1)
            for c in 0..<3 {
                let C = Float(photo.rgb[i * 4 + c])
                let F = (C - (1 - a) * backdrop[c][bs]) / max(a, 0.3)
                out[i * 4 + c] = UInt8(max(0, min(255, F.rounded())))
            }
        }
    }
    return out
}

// MARK: - one photo

@discardableResult
func process(_ photoURL: URL, out: URL, psd wantPSD: Bool) throws -> [URL] {
    let fm = FileManager.default
    let stem = photoURL.deletingPathExtension().lastPathComponent
    let scratch = workDir.appendingPathComponent("working").appendingPathComponent(stem)
    try? fm.removeItem(at: scratch)
    try fm.createDirectory(at: scratch, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: scratch) }
    let pngDir = out.appendingPathComponent("PNG"), psdDir = out.appendingPathComponent("PSD")
    try fm.createDirectory(at: pngDir, withIntermediateDirectories: true)
    let t0 = Date()

    // Vision runs while Photoshop selects
    var masks: [[UInt8]] = []
    var visionError: Error?
    let group = DispatchGroup()
    DispatchQueue.global().async(group: group) {
        do { masks = try personMasks(photoURL) } catch { visionError = error }
    }

    let subjectURL = scratch.appendingPathComponent("subject.png")
    let res = try photoshop("select_subject.jsx", ["input": photoURL.path, "maskOut": subjectURL.path], scratch: scratch)
    if res == "NOSUBJECT" { group.wait(); throw KeyerError("Photoshop's Select Subject found nobody in the frame") }
    if !res.hasPrefix("OK") { group.wait(); throw KeyerError("Select Subject failed: \(res)") }
    if !wantPSD {   // the PNGs are built from files on disk, so Photoshop is done with this photo
        _ = try? photoshop("close_doc.jsx", ["input": photoURL.path], scratch: scratch)
    }
    let tSelect = Date()

    group.wait()
    if let e = visionError { throw KeyerError("Vision failed: \(e)") }
    let photo = try loadPhoto(photoURL)
    let (mw, mh, subject) = try loadGray(subjectURL)
    guard mw == photo.width, mh == photo.height else {
        throw KeyerError("Photoshop's mask is \(mw)x\(mh) but the photo is \(photo.width)x\(photo.height)")
    }
    let n = photo.width * photo.height
    let goodMasks = masks.filter { $0.count == n }
    if goodMasks.count != masks.count { log("warning: ignored \(masks.count - goodMasks.count) Vision mask(s) of the wrong size") }

    let (alphas, note) = splitPeople(subject: subject, masks: goodMasks, w: photo.width, h: photo.height)
    let clean = decontaminate(photo, subject: subject)

    var pngs: [URL] = []
    var persons: [[String: String]] = []
    for (i, a) in alphas.enumerated() {
        let name = alphas.count == 1 ? stem : "\(stem)_p\(i + 1)"
        let png = pngDir.appendingPathComponent(name + ".png")
        try writeCutoutPNG(photo, clean, a, to: png)
        pngs.append(png)
        if wantPSD {
            let m = scratch.appendingPathComponent("person_\(i + 1).png")
            try writeGrayPNG(a, photo.width, photo.height, to: m)
            persons.append(["mask": m.path, "name": alphas.count == 1 ? "Subject" : "Person \(i + 1)"])
        }
    }
    let tPNG = Date()

    if wantPSD {
        try fm.createDirectory(at: psdDir, withIntermediateDirectories: true)
        let psd = psdDir.appendingPathComponent(stem + ".psd")
        let r = try photoshop("build_psd.jsx", ["input": photoURL.path, "subjectMask": subjectURL.path,
                                                "persons": persons, "psd": psd.path], scratch: scratch)
        if !r.hasPrefix("OK") { throw KeyerError("PSD build failed: \(r)") }
    }

    func s(_ a: Date, _ b: Date) -> String { String(format: "%.0fs", b.timeIntervalSince(a)) }
    log("DONE \(photoURL.lastPathComponent) -> \(pngs.count) PNG\(wantPSD ? " + PSD" : "") (\(note)) | select \(s(t0, tSelect)), split+png \(s(tSelect, tPNG)), psd \(s(tPNG, Date())), total \(s(t0, Date()))")
    return pngs
}

// MARK: - commands

func closeInPhotoshop(_ photo: URL) {
    let scratch = workDir.appendingPathComponent("working")
    try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    _ = try? photoshop("close_doc.jsx", ["input": photo.path], scratch: scratch)
}

func cmdNext() -> Int32 {
    let fm = FileManager.default
    let inbox = workDir.appendingPathComponent("inbox"), failed = workDir.appendingPathComponent("failed")
    let files = (try? fm.contentsOfDirectory(at: inbox, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
    let jobs = files.filter { $0.pathExtension == "json" && fm.fileExists(atPath: $0.deletingPathExtension().path) }
        .sorted {
            let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return a < b
        }
    guard let job = jobs.first else { return 3 }
    let photo = job.deletingPathExtension()
    let spec = (try? JSONSerialization.jsonObject(with: Data(contentsOf: job))) as? [String: Any] ?? [:]
    let out = (spec["out"] as? String).map { URL(fileURLWithPath: $0) }
        ?? fm.homeDirectoryForCurrentUser.appendingPathComponent("Pictures/Media Day Cutouts")
    do {
        try process(photo, out: out, psd: spec["psd"] as? Bool ?? false)
        try? fm.removeItem(at: photo)
        try? fm.removeItem(at: job)
        return 0
    } catch {
        log("FAILED \(photo.lastPathComponent): \(error)")
        closeInPhotoshop(photo)
        try? fm.createDirectory(at: failed, withIntermediateDirectories: true)
        for f in [photo, job] {
            let dest = failed.appendingPathComponent(f.lastPathComponent)
            try? fm.removeItem(at: dest)
            try? fm.moveItem(at: f, to: dest)
        }
        try? "\(error)\n".write(to: failed.appendingPathComponent(photo.deletingPathExtension().lastPathComponent + ".error.txt"),
                                atomically: true, encoding: .utf8)
        return 1
    }
}

func usage() -> Never {
    print("""
    usage:
      mdkeyer next --work DIR
      mdkeyer process PHOTO --out DIR [--psd] [--work DIR]
    """)
    exit(2)
}

var args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first else { usage() }
args.removeFirst()
var outArg: String?, psdFlag = false, positional: [String] = []
while !args.isEmpty {
    let a = args.removeFirst()
    switch a {
    case "--work": guard !args.isEmpty else { usage() }; workDir = URL(fileURLWithPath: args.removeFirst())
    case "--out": guard !args.isEmpty else { usage() }; outArg = args.removeFirst()
    case "--psd": psdFlag = true
    default: positional.append(a)
    }
}
for d in ["inbox", "working", "failed"] {
    try? FileManager.default.createDirectory(at: workDir.appendingPathComponent(d), withIntermediateDirectories: true)
}

switch command {
case "next":
    exit(cmdNext())
case "process":
    guard let p = positional.first, let o = outArg else { usage() }
    let photo = URL(fileURLWithPath: (p as NSString).expandingTildeInPath).standardizedFileURL
    do {
        for png in try process(photo, out: URL(fileURLWithPath: (o as NSString).expandingTildeInPath), psd: psdFlag) {
            print(png.path)
        }
        exit(0)
    } catch {
        log("FAILED \(photo.lastPathComponent): \(error)")
        closeInPhotoshop(photo)
        exit(1)
    }
default:
    usage()
}
