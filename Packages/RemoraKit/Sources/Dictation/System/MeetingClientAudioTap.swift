import AppKit
import AVFoundation
import CoreAudio
import Darwin

public enum MeetingAudioStartupError: Error {
    /// A newly joined client can expose its call controls before registering a Core Audio process.
    case waitingForClientAudio
}

enum MeetingProcessOwnership {
    /// Helpers must be installed inside the app AND descend from this running instance. A shared
    /// helper bundle ID, a similar app name or a second running copy cannot authorize a process.
    static func contains(pid: pid_t, executable: URL?, rootPID: pid_t, bundle: URL,
                         parent: (pid_t) -> pid_t?) -> Bool {
        guard rootPID > 1, pid > 1 else { return false }
        if pid == rootPID { return true }
        let contents = bundle.appendingPathComponent("Contents").resolvingSymlinksInPath().path + "/"
        guard let executable, executable.resolvingSymlinksInPath().path.hasPrefix(contents) else { return false }
        var candidate = pid
        for _ in 0..<32 {
            guard let ancestor = parent(candidate), ancestor > 1, ancestor != candidate else { return false }
            if ancestor == rootPID { return true }
            candidate = ancestor
        }
        return false
    }

    static func verifiedObjects(application: NSRunningApplication, bundleID: String) throws -> Set<AudioObjectID> {
        guard !application.isTerminated, application.bundleIdentifier == bundleID, let bundle = application.bundleURL else {
            throw DictationError.audio("The meeting app is no longer available.")
        }
        let rootPID = application.processIdentifier
        let objects = try AudioHardwareSystem.shared.processes.compactMap { process -> AudioObjectID? in
            guard let pid = try? process.pid, pid > 1 else { return nil }
            if pid == rootPID { return process.id }
            var path = [CChar](repeating: 0, count: Int(PROC_PIDPATHINFO_SIZE))
            let count = proc_pidpath(pid, &path, UInt32(path.count))
            guard count > 0 else { return nil }
            let executable = URL(fileURLWithPath: String(decoding: path.prefix { $0 != 0 }.map(UInt8.init(bitPattern:)),
                                                         as: UTF8.self))
            return contains(pid: pid, executable: executable, rootPID: rootPID, bundle: bundle, parent: parent)
                ? process.id : nil
        }
        guard !objects.isEmpty else { throw MeetingAudioStartupError.waitingForClientAudio }
        return Set(objects)
    }

    private static func parent(of pid: pid_t) -> pid_t? {
        var info = proc_bsdshortinfo()
        let size = Int32(MemoryLayout.size(ofValue: info))
        guard proc_pidinfo(pid, PROC_PIDT_SHORTBSDINFO, 0, &info, size) == size else { return nil }
        return pid_t(exactly: info.pbsi_ppid)
    }
}

@MainActor final class MeetingClientAudioTap {
    private let system = AudioHardwareSystem.shared
    private var tap: AudioHardwareTap?
    private var aggregate: AudioHardwareAggregateDevice?
    private var ioProc: AudioDeviceIOProcID?
    private var monitoring: Task<Void, Never>?

    func start(bundleID: String, pid: pid_t, output: MeetingAudioInput) throws {
        guard let app = NSRunningApplication(processIdentifier: pid) else {
            throw DictationError.audio("The meeting app is unavailable.")
        }
        let objects = try MeetingProcessOwnership.verifiedObjects(application: app, bundleID: bundleID)
        let description = CATapDescription(monoMixdownOfProcesses: Array(objects))
        description.name = "Remora meeting audio"
        description.isPrivate = true
        description.isProcessRestoreEnabled = false
        guard let tap = try system.makeProcessTap(description: description) else {
            throw DictationError.audio("System audio capture is unavailable.")
        }
        self.tap = tap
        do {
            let composition: [String: Any] = [
                kAudioAggregateDeviceNameKey: "Remora meeting audio",
                kAudioAggregateDeviceUIDKey: UUID().uuidString,
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceTapAutoStartKey: true,
                kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: try tap.uid]]
            ]
            guard let aggregate = try system.makeAggregateDevice(description: composition) else {
                throw DictationError.audio("Could not open the meeting audio device.")
            }
            self.aggregate = aggregate
            var streamFormat = try tap.format
            guard let format = AVAudioFormat(streamDescription: &streamFormat), format.channelCount == 1 else {
                throw DictationError.noCompatibleFormat
            }
            let block = try Self.audioCallback(format: format, output: output)
            let queue = DispatchQueue(label: "dev.remora.meeting-audio", qos: .userInitiated)
            guard AudioDeviceCreateIOProcIDWithBlock(&ioProc, aggregate.id, queue, block) == noErr, let ioProc else {
                throw DictationError.audio("Could not open the meeting audio stream.")
            }
            try aggregate.start(IOProcID: ioProc)
            let installedFormat = streamFormat
            monitoring = Task.detached(priority: .utility) {
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(1)) } catch { return }
                    // A restarted helper or a replacement output device needs a new verified tap.
                    guard (try? MeetingProcessOwnership.verifiedObjects(application: app, bundleID: bundleID)) == objects,
                          (try? aggregate.isAlive) == true,
                          let currentFormat = try? tap.format,
                          currentFormat.mSampleRate == installedFormat.mSampleRate,
                          currentFormat.mFormatID == installedFormat.mFormatID,
                          currentFormat.mFormatFlags == installedFormat.mFormatFlags,
                          currentFormat.mBytesPerFrame == installedFormat.mBytesPerFrame,
                          currentFormat.mChannelsPerFrame == installedFormat.mChannelsPerFrame else {
                        output.interrupt()
                        return
                    }
                }
            }
        } catch {
            stop()
            throw error
        }
    }

    /// The callback's PCM references belong to Core Audio. Conversion makes a separate buffer
    /// before returning, so the analyzer never holds a pointer into HAL-owned memory.
    private nonisolated static func audioCallback(format: AVAudioFormat,
                                                   output: MeetingAudioInput) throws -> AudioDeviceIOBlock {
        let converter = try MeetingPCMConverter(input: format, output: output)
        let bytesPerFrame = format.streamDescription.pointee.mBytesPerFrame
        guard bytesPerFrame > 0 else { throw DictationError.noCompatibleFormat }
        return { _, input, time, _, _ in
            let list = input.pointee
            guard list.mNumberBuffers == 1, list.mBuffers.mData != nil, list.mBuffers.mDataByteSize > 0 else { return }
            let frames = list.mBuffers.mDataByteSize / bytesPerFrame
            guard frames > 0, frames <= 65_536, list.mBuffers.mDataByteSize % bytesPerFrame == 0,
                  let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: input, deallocator: nil) else {
                output.interrupt()
                return
            }
            guard time.pointee.mFlags.contains(.hostTimeValid) else {
                output.interrupt()
                return
            }
            buffer.frameLength = frames
            converter.append(buffer, hostTime: time.pointee.mHostTime)
        }
    }

    func stop() {
        monitoring?.cancel()
        monitoring = nil
        if let aggregate {
            if let ioProc {
                try? aggregate.stop(IOProcID: ioProc)
                AudioDeviceDestroyIOProcID(aggregate.id, ioProc)
            }
            try? system.destroyAggregateDevice(aggregate)
        }
        ioProc = nil
        aggregate = nil
        if let tap { try? system.destroyProcessTap(tap) }
        tap = nil
    }

    isolated deinit { stop() }
}
