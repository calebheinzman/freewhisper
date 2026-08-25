import CoreAudio
import Foundation

public struct CoreAudioError: LocalizedError {
    public let status: OSStatus
    public let operation: String

    public init(_ status: OSStatus, _ operation: String) {
        self.status = status
        self.operation = operation
    }

    /// OSStatus values in CoreAudio are usually four-char codes, which are far
    /// easier to look up than the signed decimal Foundation would print.
    public var errorDescription: String? {
        "\(operation) failed: \(Self.fourCharCode(status)) (\(status))"
    }

    static func fourCharCode(_ status: OSStatus) -> String {
        let value = UInt32(bitPattern: status)
        let bytes = [
            UInt8((value >> 24) & 0xFF),
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 8) & 0xFF),
            UInt8(value & 0xFF),
        ]
        guard bytes.allSatisfy({ $0 >= 0x20 && $0 < 0x7F }) else {
            return "0x\(String(value, radix: 16))"
        }
        return "'" + String(bytes.map { Character(UnicodeScalar($0)) }) + "'"
    }
}

public extension AudioObjectPropertyAddress {
    init(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
    ) {
        self.init(mSelector: selector, mScope: scope, mElement: element)
    }
}

public extension AudioObjectID {
    static let system = AudioObjectID(kAudioObjectSystemObject)

    var isValid: Bool { self != AudioObjectID(kAudioObjectUnknown) }

    func has(_ address: AudioObjectPropertyAddress) -> Bool {
        var address = address
        return AudioObjectHasProperty(self, &address)
    }

    /// Read a single fixed-layout value (pid_t, UInt32, AudioObjectID, ...).
    func read<T>(_ address: AudioObjectPropertyAddress, as _: T.Type = T.self) throws -> T {
        var address = address
        var size = UInt32(MemoryLayout<T>.size)
        let buffer = UnsafeMutablePointer<T>.allocate(capacity: 1)
        defer { buffer.deallocate() }

        let status = AudioObjectGetPropertyData(self, &address, 0, nil, &size, buffer)
        guard status == noErr else {
            throw CoreAudioError(status, "read \(fourCC(address.mSelector))")
        }
        return buffer.pointee
    }

    /// Read a variable-length array property, sizing the buffer from the HAL.
    func readArray<T>(_ address: AudioObjectPropertyAddress, of _: T.Type = T.self) throws -> [T] {
        var address = address
        var size: UInt32 = 0

        var status = AudioObjectGetPropertyDataSize(self, &address, 0, nil, &size)
        guard status == noErr else {
            throw CoreAudioError(status, "size \(fourCC(address.mSelector))")
        }
        let count = Int(size) / MemoryLayout<T>.size
        guard count > 0 else { return [] }

        var values = [T](unsafeUninitializedCapacity: count) { _, initialized in
            initialized = count
        }
        status = values.withUnsafeMutableBufferPointer { pointer in
            AudioObjectGetPropertyData(self, &address, 0, nil, &size, pointer.baseAddress!)
        }
        guard status == noErr else {
            throw CoreAudioError(status, "read \(fourCC(address.mSelector))")
        }
        return Array(values.prefix(Int(size) / MemoryLayout<T>.size))
    }

    func readString(_ address: AudioObjectPropertyAddress) throws -> String {
        let cfString: CFString = try read(address)
        return cfString as String
    }

    /// Optional variant: absent properties are normal (a process with no bundle
    /// ID, a device that doesn't answer a selector), not errors worth throwing.
    func readOptionalString(_ address: AudioObjectPropertyAddress) -> String? {
        guard has(address) else { return nil }
        return try? readString(address)
    }

    func readBool(_ address: AudioObjectPropertyAddress) -> Bool {
        guard has(address) else { return false }
        guard let value: UInt32 = try? read(address) else { return false }
        return value != 0
    }

    private func fourCC(_ selector: AudioObjectPropertySelector) -> String {
        CoreAudioError.fourCharCode(OSStatus(bitPattern: selector))
    }
}
