// SPDX-License-Identifier: GPL-3.0-only
// Ported from the FM-1 Firmware Hub installer (Copyright (C) 2026 Leo Kuroshita (@kurogedelic), Hügelton Instruments).

import Foundation
import CoreMIDI

/// A found device: its link and what it said it is.
struct FM1Device {
    let link: MIDILink
    let identity: FM1Identity
    let portName: String
}

/// The steps of an install, for the progress view.
enum InstallStep: Equatable {
    case start(String)      // the device's identity
    case verify(Int)        // step 1: reads served
    case loader             // waiting for the update loader
    case write(Int)         // step 2: reads served
    case reboot
    case done(String)

    var title: String {
        switch self {
        case .start: return "Starting"
        case .verify: return "Checking the package"
        case .loader: return "Starting the update loader"
        case .write: return "Writing"
        case .reboot: return "Restarting"
        case .done: return "Done"
        }
    }

    /// 0...1 over the reads of a package (step 1, then step 2), as the installers count them.
    var fraction: Double {
        let total = Double(FM1Protocol.step1Reads + FM1Protocol.step2Reads)
        switch self {
        case .start: return 0
        case .verify(let n): return min(Double(n), Double(FM1Protocol.step1Reads)) / total
        case .loader: return Double(FM1Protocol.step1Reads) / total
        case .write(let n): return (Double(FM1Protocol.step1Reads) + min(Double(n), Double(FM1Protocol.step2Reads))) / total
        case .reboot: return 0.98
        case .done: return 1
        }
    }
}

struct ServeResult {
    let served: Int
    let finished: Bool
    let lost: Bool
}

/// Finds FM-1s on the USB MIDI ports and runs the two-step update.
final class FM1Updater {
    let engine: MIDIEngine
    /// Port names the user said are their FM-1 (a firmware that names its port after itself).
    var chosenPorts: Set<String> = []
    /// Probe every MIDI port, not only the names the hub knows.
    var probeAll = false
    var log: (String) -> Void = { _ in }
    private var cancelled = false

    init(engine: MIDIEngine = .shared) {
        self.engine = engine
    }

    func cancel() { cancelled = true }

    private func sleep(ms: Int) async {
        try? await Task.sleep(nanoseconds: UInt64(ms) * 1_000_000)
    }

    private func mayProbe(_ name: String) -> Bool {
        probeAll || FM1Protocol.mayProbe(name) || chosenPorts.contains(name)
    }

    func handshake(_ link: MIDILink, tries: Int = 3) async -> FM1Identity? {
        link.drain()
        for _ in 0..<tries {
            guard link.send(FM1Protocol.handshakeQuery) else { return nil }
            let end = Date().addingTimeInterval(1.0)
            while Date() < end {
                guard let p = await link.read(timeout: end.timeIntervalSinceNow) else { break }
                if let id = FM1Protocol.parseIdentity(p) { return id }
            }
        }
        return nil
    }

    /// Every in/out pair whose name may be an FM-1 that answers the handshake. The caller closes the link.
    func find(_ filter: (FM1Identity) -> Bool) async -> FM1Device? {
        for src in engine.sources() {
            if !mayProbe(src.name) { continue }
            guard let dest = engine.destination(for: src.endpoint, named: src.name) else { continue }
            guard let link = engine.open(source: src.endpoint, destination: dest, name: src.name) else { continue }
            if let id = await handshake(link, tries: 2), filter(id) {
                log("found \(id.text) on \(src.name)")
                return FM1Device(link: link, identity: id, portName: src.name)
            }
            link.close()
            await sleep(ms: 100)
        }
        return nil
    }

    /// The MIDI inputs the installer skipped (another name): the UI offers them as "this is my FM-1".
    func others() -> [String] {
        var seen = Set<String>()
        return engine.sources().map(\.name).filter { !$0.isEmpty && !mayProbe($0) && seen.insert($0).inserted }
    }

    /// The MIDI inputs there are, for the "not found" message.
    func seen() -> String {
        let names = engine.sources().map { $0.name.isEmpty ? "?" : $0.name }
        return names.isEmpty ? " (MIDI: none)" : " (MIDI: \(names.joined(separator: ", ")))"
    }

    func waitFor(_ filter: @escaping (FM1Identity) -> Bool, ms: Int) async -> FM1Device? {
        let end = Date().addingTimeInterval(Double(ms) / 1000)
        while Date() < end {
            if cancelled { return nil }
            if let dev = await find(filter) { return dev }
            await sleep(ms: 1000)
        }
        return nil
    }

    /// Serves read requests until the device asks for one of the finish addresses; stops early when the port
    /// disappears (lost) instead of waiting out idleMs.
    func serve(_ link: MIDILink, image: [UInt8], finish: UInt32, idleMs: Int, onProgress: (Int) -> Void) async throws -> ServeResult {
        var served = 0
        var last = Date()
        while true {
            if cancelled { throw FM1Error.cancelled }
            guard let pkt = await link.read(timeout: 1.0) else {
                if link.lost { return ServeResult(served: served, finished: false, lost: true) }
                if Date().timeIntervalSince(last) * 1000 > Double(idleMs) { return ServeResult(served: served, finished: false, lost: false) }
                continue
            }
            guard let r = FM1Protocol.parseRequest(pkt) else { continue }
            last = Date()
            if r.address == FM1Protocol.finishStep1 || r.address == FM1Protocol.finishStep2 {
                link.send(FM1Protocol.successResponse(address: r.address))
                if r.address == finish { return ServeResult(served: served, finished: true, lost: false) }
                continue
            }
            let addr = Int(r.address)
            if r.length > FM1Protocol.maxData || addr + r.length > image.count {
                throw FM1Error.badRequest(String(format: "Bad request %X+%d", r.address, r.length))
            }
            await sleep(ms: 10)
            let chunk = Array(image[addr..<(addr + r.length)])
            if !link.send(FM1Protocol.response(address: r.address, data: chunk, flags: r.flags)) {
                return ServeResult(served: served, finished: false, lost: true)
            }
            served += 1
            onProgress(served)
        }
    }

    /// Called at the point of no return: the device this attempt found has been checked, and the next thing that
    /// happens is a write. The identity handed over is that device's own, so a caller recording what it is about to
    /// do records something it has just seen rather than something it remembers. Throwing aborts the attempt with
    /// nothing written.
    typealias BeforeWriting = @MainActor (FM1Identity) throws -> Void

    /// Full install: running firmware -> loader -> new firmware. Returns the identity the device reports after.
    func install(image: [UInt8], product: String, beforeWriting: BeforeWriting = { _ in },
                 onStep: @escaping (InstallStep) -> Void) async throws -> String {
        cancelled = false
        guard let dev = await find({ !$0.isLoader }) else {
            throw FM1Error.notFound("FM-1 not found (USB cable, and no other app using it?)" + seen())
        }
        let model = product.split(separator: "_").first.map(String.init) ?? product
        if dev.identity.model != model {
            dev.link.close()
            throw FM1Error.model("The device is \(dev.identity.text), the package is for \(product).")
        }
        do {
            try await beforeWriting(dev.identity)
        } catch {
            dev.link.close()
            throw error
        }
        onStep(.start(dev.identity.text))
        dev.link.send(FM1Protocol.upgrade)
        await sleep(ms: 2000)
        let s1: ServeResult
        do {
            s1 = try await serve(dev.link, image: image, finish: FM1Protocol.finishStep1, idleMs: 8000) { onStep(.verify($0)) }
        } catch {
            dev.link.close()
            throw error
        }
        dev.link.close()   // before the FM-1 restarts as the loader
        if !s1.finished {
            let what = s1.lost ? "was disconnected" : "stopped"
            let msg = "The device \(what) after \(s1.served) requests: nothing was written."
            throw s1.lost ? FM1Error.lost(msg) : FM1Error.stopped(msg)
        }
        onStep(.loader)
        await sleep(ms: 3000)
        guard let ota = await waitFor({ $0.isLoader }, ms: 30000) else {
            if cancelled { throw FM1Error.cancelled }
            let now = await find({ _ in true })
            now?.link.close()
            let why = "step 1: \(s1.served) reads; " + (now != nil ? "the FM-1 restarted as \(now!.identity.text), not in update mode" : "no FM-1 answers")
            if now != nil {
                throw FM1Error.noLoader("The update loader did not appear (\(why))\(seen()). Hold OCT− while switching on to start it in update mode, then press Install again.")
            }
            throw FM1Error.noLoader("The update loader did not appear (\(why))\(seen()). Replug the USB cable and press Install again: the device stays in update mode until it is finished.")
        }
        let s2 = try await write(ota, image: image, onStep: onStep)
        if !s2.finished {
            let what = s2.lost ? "was disconnected" : "stopped"
            let msg = "The loader \(what) after \(s2.served) requests. Replug and press Install again to resume."
            throw s2.lost ? FM1Error.lost(msg) : FM1Error.stopped(msg)
        }
        onStep(.reboot)
        await sleep(ms: 3000)
        guard let back = await waitFor({ !$0.isLoader }, ms: 40000) else {
            throw FM1Error.noReturn("The device did not come back: power-cycle it.")
        }
        back.link.close()
        if back.identity.text != product {
            throw FM1Error.mismatch("Installed, but the device reports \(back.identity.text).")
        }
        onStep(.done(back.identity.text))
        return back.identity.text
    }

    /// Step 2 with the loader found by find()/waitFor().
    func write(_ ota: FM1Device, image: [UInt8], onStep: @escaping (InstallStep) -> Void) async throws -> ServeResult {
        ota.link.send(FM1Protocol.upgrade)
        await sleep(ms: 2000)
        defer { ota.link.close() }
        return try await serve(ota.link, image: image, finish: FM1Protocol.finishStep2, idleMs: 180000) { onStep(.write($0)) }
    }

    /// How far a resume got. The caller needs to tell `noLoader` from `interrupted`: the first means not a byte was
    /// sent and the device was never touched, the second means the write had begun.
    enum ResumeOutcome: Equatable {
        case noLoader
        case interrupted
        case written(String)
    }

    /// Resume: the device is already in update mode (loader). `expectedProduct` is the identity the package carries
    /// and is always verified against the restarted device. `stockLoader` says whose loader may be resumed: by
    /// default only the hub's own, because another firmware's loader may lay the image out differently; a package of
    /// the official family is written from the official loader, as M-UPGRADE would.
    func resume(image: [UInt8], expectedProduct: String, stockLoader: Bool, beforeWriting: BeforeWriting = { _ in },
                onStep: @escaping (InstallStep) -> Void) async throws -> ResumeOutcome {
        cancelled = false
        guard let ota = await find({ $0.isLoader }) else { return .noLoader }
        if !ota.identity.isHubLoader && !stockLoader {
            ota.link.close()
            throw FM1Error.foreign("The FM-1 is in the update mode of another firmware (\(ota.identity.text)): finish that update with its own updater.")
        }
        let model = expectedProduct.split(separator: "_").first.map(String.init) ?? expectedProduct
        if ota.identity.modelWithoutLoader != model {
            ota.link.close()
            throw FM1Error.model("The device in update mode is \(ota.identity.text), the package is for \(expectedProduct): nothing was written.")
        }
        do {
            try await beforeWriting(ota.identity)
        } catch {
            ota.link.close()
            throw error
        }
        let s2 = try await write(ota, image: image, onStep: onStep)
        if !s2.finished { return .interrupted }
        // Every package, not only the official ones: a write counts as finished when the device comes back and says
        // what it is. Reporting success without asking would let a device still stuck in the loader look recovered.
        onStep(.reboot)
        await sleep(ms: 3000)
        guard let back = await waitFor({ !$0.isLoader }, ms: 40000) else {
            throw FM1Error.noReturn("The FM-1 did not come back after the write: power-cycle it.")
        }
        back.link.close()
        if back.identity.text != expectedProduct {
            throw FM1Error.mismatch("Written, but the FM-1 reports \(back.identity.text).")
        }
        onStep(.done(back.identity.text))
        return .written(back.identity.text)
    }

    /// Is a loader waiting (an interrupted update)?
    func loaderPresent() async -> FM1Identity? {
        guard let ota = await find({ $0.isLoader }) else { return nil }
        ota.link.close()
        return ota.identity
    }
}
