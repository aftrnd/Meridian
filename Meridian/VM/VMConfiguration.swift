import Virtualization
import Foundation

/// Builds a VZVirtualMachineConfiguration for the Meridian VM.
///
/// Hardware layout:
///   - ARM64 Linux boot (VZLinuxBootLoader)  
///   - virtio-net (NAT, outbound internet for Steam in-guest + game updates)
///   - virtio-blk backed by the assembled Meridian base image (read-only base)
///   - virtio-blk backed by a per-user expansion qcow2 for game installs (writable)
///   - virtio-fs share mapping ~/Library/Application Support/com.meridian.app/games
///     into /mnt/games inside the guest (for shared Steam library paths)
///   - virtio-gpu (VZVirtioGraphicsDevice) for display
///   - virtio-keyboard + virtio-pointer for input pass-through
///   - virtio-rng for entropy
///   - virtio-serial for the host↔guest RPC channel (ProtonBridge)
enum VMConfiguration {
    private static let vmSupportDir: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appending(path: "com.meridian.app/vm", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private static var assembledImageURL: URL { vmSupportDir.appending(path: "meridian-base.img") }

    static func build(settings: AppSettings) throws -> VZVirtualMachineConfiguration {
        let config = VZVirtualMachineConfiguration()

        config.cpuCount   = validatedCPUCount(settings.vmCPUCount)
        config.memorySize = UInt64(settings.vmMemoryGiB) * 1024 * 1024 * 1024

        config.bootLoader    = try makeBootLoader()
        config.storageDevices = try makeStorageDevices(settings: settings)
        config.networkDevices = [makeNetworkDevice()]
        config.graphicsDevices = [makeGraphicsDevice()]
        config.keyboards     = [VZUSBKeyboardConfiguration()]
        config.pointingDevices = [VZUSBScreenCoordinatePointingDeviceConfiguration()]
        config.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]
        config.serialPorts   = [try makeSerialPort()]
        config.directorySharingDevices = try makeDirectoryShares()

        try config.validate()
        return config
    }

    // MARK: - Boot

    private static func makeBootLoader() throws -> VZLinuxBootLoader {
        let vmDir = vmSupportDir

        // The Meridian base image ships a separate vmlinuz + initrd alongside the disk.
        // If they don't exist yet, we fall back gracefully — the provision flow will
        // download them as part of the image setup.
        let kernelURL  = vmDir.appending(path: "vmlinuz")
        let initrdURL  = vmDir.appending(path: "initrd")

        guard FileManager.default.fileExists(atPath: kernelURL.path()) else {
            throw ConfigError.kernelNotFound
        }

        let loader = VZLinuxBootLoader(kernelURL: kernelURL)
        if FileManager.default.fileExists(atPath: initrdURL.path()) {
            loader.initialRamdiskURL = initrdURL
        }
        // Pass Proton-optimised kernel parameters:
        // quiet          — suppress verbose boot output
        // loglevel=0     — minimal kernel noise
        // console=hvc0   — serial console on virtio serial (ProtonBridge)
        // meridian=1     — tells the guest init it's running inside Meridian
        loader.commandLine = "quiet loglevel=0 console=hvc0 meridian=1"
        return loader
    }

    // MARK: - Storage

    private static func makeStorageDevices(settings: AppSettings) throws -> [VZStorageDeviceConfiguration] {
        let baseImageURL = assembledImageURL

        guard FileManager.default.fileExists(atPath: baseImageURL.path()) else {
            throw ConfigError.baseImageNotFound
        }

        // Read-only base disk
        let baseAttachment = try VZDiskImageStorageDeviceAttachment(
            url: baseImageURL,
            readOnly: true
        )
        let baseDisk = VZVirtioBlockDeviceConfiguration(attachment: baseAttachment)

        // Writable expansion disk (created on first boot if absent)
        let expandURL = vmSupportDir.appending(path: "expansion.img")
        if !FileManager.default.fileExists(atPath: expandURL.path()) {
            try createExpansionDisk(at: expandURL, sizeGiB: settings.vmDiskGiB)
        }
        let expandAttachment = try VZDiskImageStorageDeviceAttachment(url: expandURL, readOnly: false)
        let expandDisk = VZVirtioBlockDeviceConfiguration(attachment: expandAttachment)

        return [baseDisk, expandDisk]
    }

    private static func createExpansionDisk(at url: URL, sizeGiB: Int) throws {
        let sizeBytes = sizeGiB * 1024 * 1024 * 1024
        guard FileManager.default.createFile(atPath: url.path(), contents: nil) else {
            throw ConfigError.diskCreationFailed
        }
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: UInt64(sizeBytes))
        try handle.close()
    }

    // MARK: - Network

    private static func makeNetworkDevice() -> VZNetworkDeviceConfiguration {
        let net = VZVirtioNetworkDeviceConfiguration()
        net.attachment = VZNATNetworkDeviceAttachment()
        return net
    }

    // MARK: - Graphics

    private static func makeGraphicsDevice() -> VZGraphicsDeviceConfiguration {
        let display = VZVirtioGraphicsScanoutConfiguration(
            widthInPixels: 1920,
            heightInPixels: 1080
        )
        let gpu = VZVirtioGraphicsDeviceConfiguration()
        gpu.scanouts = [display]
        return gpu
    }

    // MARK: - Serial (ProtonBridge RPC)

    private static func makeSerialPort() throws -> VZSerialPortConfiguration {
        let serial = VZVirtioConsoleDeviceSerialPortConfiguration()
        // Keep a valid serial console attached for the guest kernel console.
        // A socket-backed bridge can be added later with a dedicated host daemon.
        guard
            let readHandle = FileHandle(forReadingAtPath: "/dev/null"),
            let writeHandle = FileHandle(forWritingAtPath: "/dev/null")
        else {
            throw ConfigError.serialAttachmentFailed
        }
        serial.attachment = VZFileHandleSerialPortAttachment(
            fileHandleForReading: readHandle,
            fileHandleForWriting: writeHandle
        )
        return serial
    }

    // MARK: - Directory sharing (virtio-fs)

    private static func makeDirectoryShares() throws -> [VZDirectorySharingDeviceConfiguration] {
        var shares: [VZDirectorySharingDeviceConfiguration] = []

        // Game library share — writable, mounted at /mnt/games in the guest.
        let gamesDir = vmSupportDir.appending(path: "games", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: gamesDir, withIntermediateDirectories: true)
        let gamesShare = VZSharedDirectory(url: gamesDir, readOnly: false)
        let gamesFS = VZVirtioFileSystemDeviceConfiguration(tag: "meridian-games")
        gamesFS.share = VZSingleDirectoryShare(directory: gamesShare)
        shares.append(gamesFS)

        // Steam session share — read-only, mounted at /mnt/steam-session in the guest.
        // The guest init script uses these files to auto-sign into Steam without prompting.
        // The staging directory is prepared by SteamSessionBridge before VM launch.
        let sessionDir = SteamSessionBridge.stagingDir
        let sessionShare = VZSharedDirectory(url: sessionDir, readOnly: true)
        let sessionFS = VZVirtioFileSystemDeviceConfiguration(tag: "meridian-steam-session")
        sessionFS.share = VZSingleDirectoryShare(directory: sessionShare)
        shares.append(sessionFS)

        return shares
    }

    // MARK: - CPU validation

    private static func validatedCPUCount(_ requested: Int) -> Int {
        let available = VZVirtualMachineConfiguration.maximumAllowedCPUCount
        let minimum   = VZVirtualMachineConfiguration.minimumAllowedCPUCount
        return min(max(minimum, requested), available)
    }

    // MARK: - Errors

    enum ConfigError: LocalizedError {
        case kernelNotFound
        case baseImageNotFound
        case diskCreationFailed
        case serialAttachmentFailed

        var errorDescription: String? {
            switch self {
            case .kernelNotFound:    return "VM kernel (vmlinuz) not found. Please provision the VM first."
            case .baseImageNotFound: return "Meridian base image not found. Please provision the VM first."
            case .diskCreationFailed: return "Failed to create VM expansion disk."
            case .serialAttachmentFailed: return "Failed to create VM serial attachment."
            }
        }
    }
}
