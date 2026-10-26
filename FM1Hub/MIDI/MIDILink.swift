import Foundation
import CoreMIDI

/// One MIDI in/out pair with a SysEx queue.
final class MIDILink: @unchecked Sendable {
    let source: MIDIEndpointRef
    let destination: MIDIEndpointRef
    let name: String
    let token: UnsafeMutableRawPointer
    private unowned let engine: MIDIEngine
    private let queue = SysexQueue()
    private let parseLock = NSLock()
    private var buffer: [UInt8] = []
    private var inSysex = false
    private var closed = false

    init(engine: MIDIEngine, source: MIDIEndpointRef, destination: MIDIEndpointRef, name: String, token: UnsafeMutableRawPointer) {
        self.engine = engine
        self.source = source
        self.destination = destination
        self.name = name
        self.token = token
    }

    /// The port is gone (unplugged).
    var lost: Bool {
        !engine.isPresent(source, source: true) || !engine.isPresent(destination, source: false)
    }

    @discardableResult
    func send(_ bytes: [UInt8]) -> Bool {
        if closed { return false }
        return engine.send(sysex: bytes, to: destination)
    }

    func drain() { queue.drain() }

    func read(timeout seconds: TimeInterval) async -> [UInt8]? {
        if closed { return nil }
        return await queue.next(timeout: seconds)
    }

    func close() {
        if closed { return }
        closed = true
        queue.cancel()
        engine.close(self)
    }

    /// UMP words from the input port: SysEx7 messages are reassembled into F0 ... F7 and queued.
    func feed(words: [UInt32]) {
        parseLock.lock()
        defer { parseLock.unlock() }
        var i = 0
        while i < words.count {
            let w0 = words[i]
            let mt = Int(w0 >> 28)
            let size = UMP.sizes[mt]
            if mt == 0x3, i + 1 < words.count {
                let w1 = words[i + 1]
                let status = (w0 >> 20) & 0xF
                let n = Int((w0 >> 16) & 0xF)
                let all: [UInt8] = [UInt8((w0 >> 8) & 0xFF), UInt8(w0 & 0xFF), UInt8((w1 >> 24) & 0xFF), UInt8((w1 >> 16) & 0xFF), UInt8((w1 >> 8) & 0xFF), UInt8(w1 & 0xFF)]
                let data = Array(all.prefix(min(n, 6)))
                switch status {
                case 0:
                    queue.push([0xF0] + data + [0xF7])
                    inSysex = false
                    buffer.removeAll()
                case 1:
                    buffer = data
                    inSysex = true
                case 2:
                    if inSysex { buffer.append(contentsOf: data) }
                case 3:
                    if inSysex {
                        buffer.append(contentsOf: data)
                        queue.push([0xF0] + buffer + [0xF7])
                    }
                    inSysex = false
                    buffer.removeAll()
                default:
                    break
                }
            }
            i += size
        }
    }
}
