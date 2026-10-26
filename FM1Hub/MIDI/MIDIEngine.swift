import Foundation
import CoreMIDI

/// One MIDI endpoint as the app shows it.
struct MIDIPortInfo: Identifiable, Hashable {
    let id: MIDIUniqueID
    let name: String
    let endpoint: MIDIEndpointRef
    let isSource: Bool
}

/// The CoreMIDI client of the app: enumerates the USB MIDI ports, receives UMP event lists and reassembles
/// SysEx for the links, sends SysEx as UMP SysEx7.
final class MIDIEngine: @unchecked Sendable {
    static let shared = MIDIEngine()

    private var client = MIDIClientRef()
    private var inPort = MIDIPortRef()
    private var outPort = MIDIPortRef()
    private let lock = NSLock()
    private var links: [UInt: MIDILink] = [:]
    private(set) var ready = false
    /// Called (on an arbitrary thread) when the MIDI setup changes: a device plugged in or out.
    var onSetupChanged: (@Sendable () -> Void)?

    private init() {
        start()
    }

    private func start() {
        var status = MIDIClientCreateWithBlock("FM1Hub" as CFString, &client) { [weak self] notification in
            let id = notification.pointee.messageID
            if id == .msgSetupChanged || id == .msgObjectAdded || id == .msgObjectRemoved || id == .msgPropertyChanged {
                self?.onSetupChanged?()
            }
        }
        guard status == noErr else { return }
        status = MIDIInputPortCreateWithProtocol(client, "FM1Hub In" as CFString, ._1_0, &inPort) { [weak self] eventList, srcConnRefCon in
            self?.receive(eventList, refCon: srcConnRefCon)
        }
        guard status == noErr else { return }
        status = MIDIOutputPortCreate(client, "FM1Hub Out" as CFString, &outPort)
        ready = status == noErr
    }

    // MARK: Ports

    func sources() -> [MIDIPortInfo] {
        (0..<MIDIGetNumberOfSources()).compactMap { i in
            let ep = MIDIGetSource(i)
            guard ep != 0, !isOffline(ep) else { return nil }
            return MIDIPortInfo(id: uniqueID(ep), name: displayName(ep), endpoint: ep, isSource: true)
        }
    }

    func destinations() -> [MIDIPortInfo] {
        (0..<MIDIGetNumberOfDestinations()).compactMap { i in
            let ep = MIDIGetDestination(i)
            guard ep != 0, !isOffline(ep) else { return nil }
            return MIDIPortInfo(id: uniqueID(ep), name: displayName(ep), endpoint: ep, isSource: false)
        }
    }

    /// The destination that belongs to a source: the same entity, else the same name, else the only one there is.
    func destination(for source: MIDIEndpointRef, named name: String) -> MIDIEndpointRef? {
        let dests = destinations()
        let srcEntity = entity(of: source)
        if srcEntity != 0, let d = dests.first(where: { entity(of: $0.endpoint) == srcEntity }) { return d.endpoint }
        if let d = dests.first(where: { $0.name == name }) { return d.endpoint }
        if dests.count == 1 { return dests[0].endpoint }
        return nil
    }

    func displayName(_ obj: MIDIObjectRef) -> String {
        var s: Unmanaged<CFString>?
        if MIDIObjectGetStringProperty(obj, kMIDIPropertyDisplayName, &s) == noErr, let s = s {
            return s.takeRetainedValue() as String
        }
        if MIDIObjectGetStringProperty(obj, kMIDIPropertyName, &s) == noErr, let s = s {
            return s.takeRetainedValue() as String
        }
        return ""
    }

    func uniqueID(_ obj: MIDIObjectRef) -> MIDIUniqueID {
        var v: Int32 = 0
        MIDIObjectGetIntegerProperty(obj, kMIDIPropertyUniqueID, &v)
        return v
    }

    func isOffline(_ obj: MIDIObjectRef) -> Bool {
        var v: Int32 = 0
        let st = MIDIObjectGetIntegerProperty(obj, kMIDIPropertyOffline, &v)
        return st == noErr && v != 0
    }

    func entity(of endpoint: MIDIEndpointRef) -> MIDIEntityRef {
        var e = MIDIEntityRef()
        MIDIEndpointGetEntity(endpoint, &e)
        return e
    }

    /// True while the endpoint is still in the system and online.
    func isPresent(_ endpoint: MIDIEndpointRef, source: Bool) -> Bool {
        let list = source ? sources() : destinations()
        return list.contains { $0.endpoint == endpoint }
    }

    // MARK: Links

    func open(source: MIDIEndpointRef, destination: MIDIEndpointRef, name: String) -> MIDILink? {
        guard ready else { return nil }
        let token = UnsafeMutableRawPointer.allocate(byteCount: 1, alignment: 1)
        let link = MIDILink(engine: self, source: source, destination: destination, name: name, token: token)
        lock.lock()
        links[UInt(bitPattern: token)] = link
        lock.unlock()
        let st = MIDIPortConnectSource(inPort, source, token)
        if st != noErr {
            lock.lock(); links.removeValue(forKey: UInt(bitPattern: token)); lock.unlock()
            token.deallocate()
            return nil
        }
        return link
    }

    func close(_ link: MIDILink) {
        MIDIPortDisconnectSource(inPort, link.source)
        lock.lock()
        let removed = links.removeValue(forKey: UInt(bitPattern: link.token)) != nil
        lock.unlock()
        if removed { link.token.deallocate() }
    }

    private func receive(_ list: UnsafePointer<MIDIEventList>, refCon: UnsafeMutableRawPointer?) {
        guard let refCon = refCon else { return }
        lock.lock()
        let link = links[UInt(bitPattern: refCon)]
        lock.unlock()
        guard let link = link else { return }
        let firstOffset = MemoryLayout<MIDIEventList>.offset(of: \MIDIEventList.packet)!
        var packet: UnsafePointer<MIDIEventPacket> = UnsafeRawPointer(list).advanced(by: firstOffset).assumingMemoryBound(to: MIDIEventPacket.self)
        let wordsOffset = MemoryLayout<MIDIEventPacket>.offset(of: \MIDIEventPacket.words)!
        let count = Int(list.pointee.numPackets)
        for _ in 0..<count {
            let wordCount = Int(packet.pointee.wordCount)
            let base = UnsafeRawPointer(packet).advanced(by: wordsOffset)
            var words = [UInt32](repeating: 0, count: wordCount)
            for i in 0..<wordCount { words[i] = base.load(fromByteOffset: i * 4, as: UInt32.self) }
            link.feed(words: words)
            packet = UnsafePointer(MIDIEventPacketNext(packet))
        }
    }

    // MARK: Sending

    /// Sends one complete SysEx message (F0 ... F7) as UMP SysEx7. False when the port refused it.
    func send(sysex bytes: [UInt8], to destination: MIDIEndpointRef) -> Bool {
        guard ready else { return false }
        let words = UMP.sysex7Words(bytes)
        guard !words.isEmpty else { return false }
        let packets = (words.count + 63) / 64 + 1
        let byteSize = MemoryLayout<MIDIEventList>.size + packets * MemoryLayout<MIDIEventPacket>.size
        let raw = UnsafeMutableRawPointer.allocate(byteCount: byteSize, alignment: 8)
        defer { raw.deallocate() }
        let list = raw.bindMemory(to: MIDIEventList.self, capacity: 1)
        var cur: UnsafeMutablePointer<MIDIEventPacket> = MIDIEventListInit(list, ._1_0)
        var ok = true
        words.withUnsafeBufferPointer { wp in
            var i = 0
            while i < words.count {
                let n = min(64, words.count - i)
                let next: UnsafeMutablePointer<MIDIEventPacket>? = MIDIEventListAdd(list, byteSize, cur, 0, n, wp.baseAddress! + i)
                guard let next = next else { ok = false; return }
                cur = next
                i += n
            }
        }
        guard ok else { return false }
        return MIDISendEventList(outPort, destination, list) == noErr
    }
}

/// Universal MIDI Packet helpers for the MIDI 1.0 protocol: SysEx7 in and out.
enum UMP {
    /// Words per message, by message type (the top nibble of the first word).
    static let sizes: [Int] = [1, 1, 1, 2, 2, 4, 1, 1, 2, 2, 2, 3, 3, 4, 4, 4]

    /// A complete SysEx (F0 ... F7) as SysEx7 messages: 6 data bytes a message, two words each.
    static func sysex7Words(_ sysex: [UInt8]) -> [UInt32] {
        var data = sysex
        if data.first == 0xF0 { data.removeFirst() }
        if data.last == 0xF7 { data.removeLast() }
        var words: [UInt32] = []
        words.reserveCapacity((data.count / 6 + 1) * 2)
        let chunks = max(1, (data.count + 5) / 6)
        for c in 0..<chunks {
            let start = c * 6
            let end = min(start + 6, data.count)
            let part = start < data.count ? Array(data[start..<end]) : []
            let status: UInt32 = chunks == 1 ? 0 : (c == 0 ? 1 : (c == chunks - 1 ? 3 : 2))
            var b = [UInt8](repeating: 0, count: 6)
            for (i, x) in part.enumerated() { b[i] = x & 0x7F }
            let w0 = (UInt32(0x3) << 28) | (status << 20) | (UInt32(part.count) << 16) | (UInt32(b[0]) << 8) | UInt32(b[1])
            let w1 = (UInt32(b[2]) << 24) | (UInt32(b[3]) << 16) | (UInt32(b[4]) << 8) | UInt32(b[5])
            words.append(w0)
            words.append(w1)
        }
        return words
    }
}
