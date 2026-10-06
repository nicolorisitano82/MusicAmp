import AVFoundation
import CoreAudio

/// An output route: a CoreAudio device, or one AirPlay receiver exposed as a data source of the AirPlay device.
struct AudioDevice: Hashable, Identifiable {
    let id: AudioDeviceID
    let uid: String          // device UID, or "<device UID>#<data source id>" for an AirPlay receiver
    let name: String
    let isAirPlay: Bool
    let dataSource: UInt32?

    private static func address(_ sel: AudioObjectPropertySelector,
                                _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: sel, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private static func string(_ id: AudioObjectID, _ sel: AudioObjectPropertySelector) -> String? {
        var addr = address(sel)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr, let v = value else { return nil }
        return v.takeRetainedValue() as String
    }

    private static func uint32(_ id: AudioObjectID, _ sel: AudioObjectPropertySelector,
                               _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> UInt32? {
        var addr = address(sel, scope)
        var v: UInt32 = 0
        var size = UInt32(4)
        return AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &v) == noErr ? v : nil
    }

    private static func outputChannels(_ id: AudioDeviceID) -> Int {
        var addr = address(kAudioDevicePropertyStreamConfiguration, kAudioDevicePropertyScopeOutput)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    /// AirPlay receivers are the output data sources of the AirPlay device.
    private static func airPlaySources(_ id: AudioDeviceID) -> [(UInt32, String)] {
        var addr = address(kAudioDevicePropertyDataSources, kAudioDevicePropertyScopeOutput)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var sources = [UInt32](repeating: 0, count: Int(size) / 4)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &sources) == noErr else { return [] }
        return sources.map { src in
            var source = src
            var name: Unmanaged<CFString>?
            var nameAddr = address(kAudioDevicePropertyDataSourceNameForIDCFString, kAudioDevicePropertyScopeOutput)
            let label: String = withUnsafeMutablePointer(to: &source) { inPtr in
                withUnsafeMutablePointer(to: &name) { outPtr in
                    var t = AudioValueTranslation(mInputData: inPtr, mInputDataSize: 4,
                                                  mOutputData: outPtr, mOutputDataSize: UInt32(MemoryLayout<Unmanaged<CFString>?>.size))
                    var tsize = UInt32(MemoryLayout<AudioValueTranslation>.size)
                    guard AudioObjectGetPropertyData(id, &nameAddr, 0, nil, &tsize, &t) == noErr,
                          let n = outPtr.pointee?.takeRetainedValue() as String? else { return "AirPlay \(src)" }
                    return n
                }
            }
            return (src, label)
        }
    }

    static func outputDevices() -> [AudioDevice] {
        var addr = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else { return [] }
        var out: [AudioDevice] = []
        for id in ids {
            guard outputChannels(id) > 0, let uid = string(id, kAudioDevicePropertyDeviceUID) else { continue }
            let name = string(id, kAudioObjectPropertyName) ?? uid
            let airplay = uint32(id, kAudioDevicePropertyTransportType) == kAudioDeviceTransportTypeAirPlay
            let sources = airplay ? airPlaySources(id) : []
            if sources.isEmpty {
                out.append(AudioDevice(id: id, uid: uid, name: airplay ? "AirPlay: \(name)" : name, isAirPlay: airplay, dataSource: nil))
            } else {
                out += sources.map { AudioDevice(id: id, uid: "\(uid)#\($0.0)", name: "AirPlay: \($0.1)", isAirPlay: true, dataSource: $0.0) }
            }
        }
        return out
    }

    static func defaultOutputID() -> AudioDeviceID? {
        var addr = address(kAudioHardwarePropertyDefaultOutputDevice)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id) == noErr else { return nil }
        return id
    }

    func selectDataSource() {
        guard var src = dataSource else { return }
        var addr = AudioDevice.address(kAudioDevicePropertyDataSource, kAudioDevicePropertyScopeOutput)
        AudioObjectSetPropertyData(id, &addr, 0, nil, 4, &src)
    }

    /// Calls `handler` on the main queue whenever the system default output changes
    /// (Control Center, Sound settings, the AirPlay route picker).
    static func observeDefaultOutput(_ handler: @escaping () -> Void) {
        var addr = address(kAudioHardwarePropertyDefaultOutputDevice)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, DispatchQueue.main) { _, _ in handler() }
    }
}

extension AudioEngine {
    /// Routes output to the device with `uid`, or the system default when nil. Playback resumes where it was.
    func setOutputDevice(uid: String?) {
        let dev = uid.flatMap { u in AudioDevice.outputDevices().first { $0.uid == u } }
        guard var id = dev?.id ?? AudioDevice.defaultOutputID(), let unit = engine.outputNode.audioUnit else { return }
        let wasPlaying = state == .playing
        let t = currentTime
        if wasPlaying { pause() }
        engine.stop()
        dev?.selectDataSource()
        AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                             &id, UInt32(MemoryLayout<AudioDeviceID>.size))
        if wasPlaying {
            play()
            seek(to: t)
        }
    }
}
