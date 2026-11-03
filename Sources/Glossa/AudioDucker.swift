import AudioToolbox
import CoreAudio

/// Lowers the default output device's volume while recording, when something is playing,
/// and restores it afterwards (unless the user moved the volume in the meantime).
final class AudioDucker {
    private var restoreTo: Float32?
    private var duckedTo: Float32?

    func duck(byPercent percent: Int, onlyIfPlaying: Bool) {
        guard percent > 0, restoreTo == nil, let device = defaultOutputDevice() else { return }
        if onlyIfPlaying, !isRunning(device) { return }
        guard let current = volume(of: device) else { return }
        let target = max(0, current - Float32(percent) / 100)
        guard target < current, setVolume(target, of: device) else { return }
        restoreTo = current
        duckedTo = target
        Log.write("ducked output \(Int((current * 100).rounded()))% -> \(Int((target * 100).rounded()))%")
    }

    func restore() {
        guard let to = restoreTo, let ducked = duckedTo else { return }
        defer { restoreTo = nil; duckedTo = nil }
        guard let device = defaultOutputDevice(), let now = volume(of: device) else { return }
        guard abs(now - ducked) < 0.02 else { return }   // the user changed it; leave it alone
        _ = setVolume(to, of: device)
    }

    // MARK: - Core Audio

    private func defaultOutputDevice() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        return status == noErr && device != 0 ? device : nil
    }

    /// True when any process has audio I/O running on the device, i.e. something is playing.
    private func isRunning(_ device: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var running = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(device, &address, 0, nil, &size, &running) == noErr && running != 0
    }

    private var volumeAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
        mScope: kAudioDevicePropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain)

    private func volume(of device: AudioDeviceID) -> Float32? {
        guard AudioObjectHasProperty(device, &volumeAddress) else { return nil }
        var value = Float32(0)
        var size = UInt32(MemoryLayout<Float32>.size)
        return AudioObjectGetPropertyData(device, &volumeAddress, 0, nil, &size, &value) == noErr ? value : nil
    }

    private func setVolume(_ value: Float32, of device: AudioDeviceID) -> Bool {
        var settable = DarwinBoolean(false)
        guard AudioObjectIsPropertySettable(device, &volumeAddress, &settable) == noErr, settable.boolValue else { return false }
        var v = value
        return AudioObjectSetPropertyData(device, &volumeAddress, 0, nil, UInt32(MemoryLayout<Float32>.size), &v) == noErr
    }
}
