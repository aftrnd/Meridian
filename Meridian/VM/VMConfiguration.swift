import Virtualization
import Foundation
import Darwin

/// Builds a VZVirtualMachineConfiguration for the Meridian VM.
///
/// Hardware layout:
///   - ARM64 Linux boot (VZLinuxBootLoader)
///   - virtio-net (NAT — outbound internet for Steam downloads + game updates)
///   - virtio-blk read-only  — Meridian base image
///   - virtio-blk read-write — per-user expansion disk (game installs)
///   - virtio-fs  "meridian-games"         → /mnt/games      (writable, shared library)
///   - virtio-fs  "meridian-steam-session" → /mnt/steam-session (read-only, auth staging)
///   - virtio-gpu 1920×1080 (resizable at runtime via bridge resize command)
///   - USB keyboard + pointer pass-through
///   - virtio-rng
///   - virtio-serial  hvc0 — kernel console (guest boot log, /dev/null on host for now)
///   - virtio-vsock   — ProtonBridge RPC channel (host calls connect(toPort:1234))
///
/// Why vsock instead of serial for the bridge:
///   The serial port is suitable for kernel console output but is a single
///   byte stream with no framing. virtio-vsock gives us proper port-multiplexed
///   bidirectional connections — ProtonBridge uses port 1234 for game commands
///   and future services (install progress, resize, screenshots) can use other
///   ports without any plumbing changes.
enum VMConfiguration {

    // MARK: - Constants

    /// vsock port the meridian-bridge daemon listens on inside the guest.
    static let bridgeVsockPort: UInt32 = 1234

    // MARK: - Support directory

    private static let vmSupportDir: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir  = base.appending(path: "com.meridian.app/vm", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    static var assembledImageURL: URL { vmSupportDir.appending(path: "meridian-base.img") }

    // MARK: - Build

    static func build(settings: AppSettings) throws -> VZVirtualMachineConfiguration {
        // Best-effort scrub of quarantine/provenance xattrs from the VM support
        // tree. A quarantined parent directory can cause new/updated VM artifacts
        // to inherit quarantine and trigger opaque VZ start failures.
        stripQuarantineRecursively(in: vmSupportDir)

        let config = VZVirtualMachineConfiguration()

        config.cpuCount   = validatedCPUCount(settings.vmCPUCount)
        config.memorySize = validatedMemorySize(settings.vmMemoryGiB)

        config.bootLoader             = try makeBootLoader()
        config.storageDevices         = try makeStorageDevices(settings: settings)
        config.networkDevices         = [makeNetworkDevice()]
        config.graphicsDevices        = [makeGraphicsDevice(settings: settings)]
        config.keyboards              = [VZUSBKeyboardConfiguration()]
        config.pointingDevices        = [VZUSBScreenCoordinatePointingDeviceConfiguration()]
        config.entropyDevices         = [VZVirtioEntropyDeviceConfiguration()]
        config.serialPorts            = [makeConsoleSerialPort()]
        config.socketDevices          = [VZVirtioSocketDeviceConfiguration()]   // ProtonBridge vsock
        config.directorySharingDevices = try makeDirectoryShares()

        try config.validate()
        return config
    }

    // MARK: - Boot

    private static func makeBootLoader() throws -> VZLinuxBootLoader {
        let vmDir    = vmSupportDir
        let kernelURL = vmDir.appending(path: "vmlinuz")
        let initrdURL = vmDir.appending(path: "initrd")

        guard FileManager.default.fileExists(atPath: kernelURL.path) else {
            throw ConfigError.kernelNotFound
        }
        if isGzipFile(at: kernelURL) {
            throw ConfigError.kernelCompressed
        }
        // Defensive: remove quarantine xattr each start so VZ can open kernel/initrd.
        stripQuarantine(from: kernelURL)

        let loader = VZLinuxBootLoader(kernelURL: kernelURL)
        if FileManager.default.fileExists(atPath: initrdURL.path) {
            stripQuarantine(from: initrdURL)
            loader.initialRamdiskURL = initrdURL
        }
        // root=         — rootfs device in the current base image
        // console=hvc0  — kernel log on virtio-serial (written to console.log on host)
        // meridian=1    — tells the guest init it is running inside Meridian
        loader.commandLine = "root=/dev/vda1 rootwait rw console=hvc0 loglevel=3 meridian=1"
        return loader
    }

    // MARK: - Storage

    private static func makeStorageDevices(settings: AppSettings) throws -> [VZStorageDeviceConfiguration] {
        let baseImageURL = assembledImageURL

        guard FileManager.default.fileExists(atPath: baseImageURL.path) else {
            throw ConfigError.baseImageNotFound
        }
        // VZ start can fail with generic Code=1 when sandbox files carry quarantine.
        stripQuarantine(from: baseImageURL)

        // Read-write base image (needs rw for systemd to function properly)
        let baseAttachment = try VZDiskImageStorageDeviceAttachment(url: baseImageURL, readOnly: false)
        let baseDisk = VZVirtioBlockDeviceConfiguration(attachment: baseAttachment)

        // Writable expansion disk — game installs, Steam data
        let expandURL = vmSupportDir.appending(path: "expansion.img")
        if !FileManager.default.fileExists(atPath: expandURL.path) {
            try createExpansionDisk(at: expandURL, sizeGiB: settings.vmDiskGiB)
        }
        stripQuarantine(from: expandURL)
        let expandAttachment = try VZDiskImageStorageDeviceAttachment(url: expandURL, readOnly: false)
        let expandDisk = VZVirtioBlockDeviceConfiguration(attachment: expandAttachment)

        return [baseDisk, expandDisk]
    }

    private static func createExpansionDisk(at url: URL, sizeGiB: Int) throws {
        let sizeBytes = UInt64(sizeGiB) * 1_024 * 1_024 * 1_024
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw ConfigError.diskCreationFailed
        }
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: sizeBytes)
        try handle.close()
    }

    private static func stripQuarantine(from url: URL) {
        _ = removexattr(url.path, "com.apple.quarantine", 0)
        _ = removexattr(url.path, "com.apple.provenance", 0)
    }

    private static func isGzipFile(at url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 2) else { return false }
        return data.count == 2 && data[0] == 0x1f && data[1] == 0x8b
    }

    private static func stripQuarantineRecursively(in directory: URL) {
        stripQuarantine(from: directory)
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsPackageDescendants]
        ) else {
            return
        }

        for case let url as URL in enumerator {
            stripQuarantine(from: url)
        }
    }

    // MARK: - Network

    private static func makeNetworkDevice() -> VZNetworkDeviceConfiguration {
        let net = VZVirtioNetworkDeviceConfiguration()
        net.attachment = VZNATNetworkDeviceAttachment()
        return net
    }

    // MARK: - Graphics

    private static func makeGraphicsDevice(settings: AppSettings) -> VZGraphicsDeviceConfiguration {
        let display = VZVirtioGraphicsScanoutConfiguration(
            widthInPixels:  settings.vmDisplayWidth,
            heightInPixels: settings.vmDisplayHeight
        )
        let gpu = VZVirtioGraphicsDeviceConfiguration()
        gpu.scanouts = [display]
        return gpu
    }

    // MARK: - Serial (kernel console only — NOT the bridge channel)

    /// The serial port captures the kernel console (hvc0) to a log file on the host.
    /// Tail it with: tail -f ~/Library/Containers/com.meridian.app/.../vm/console.log
    private static func makeConsoleSerialPort() -> VZSerialPortConfiguration {
        let serial = VZVirtioConsoleDeviceSerialPortConfiguration()
        let logURL = vmSupportDir.appending(path: "console.log")
        // Truncate/create fresh log on each boot so it doesn't grow unbounded.
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        guard
            let rh = FileHandle(forReadingAtPath: "/dev/null"),
            let wh = FileHandle(forWritingAtPath: logURL.path)
        else {
            return serial
        }
        serial.attachment = VZFileHandleSerialPortAttachment(
            fileHandleForReading: rh,
            fileHandleForWriting: wh
        )
        return serial
    }

    // MARK: - Directory sharing (virtio-fs)

    private static func makeDirectoryShares() throws -> [VZDirectorySharingDeviceConfiguration] {
        var shares: [VZDirectorySharingDeviceConfiguration] = []

        // Rosetta x86_64 translation — tag "rosetta", guest mounts at /opt/rosetta.
        // The guest's rosetta-setup.service calls `rosetta --register` to hook binfmt_misc
        // so x86_64 ELF binaries (Steam, Proton) run transparently via Apple's Rosetta.
        if VZLinuxRosettaDirectoryShare.availability == .installed {
            let rosettaFS = VZVirtioFileSystemDeviceConfiguration(tag: "rosetta")
            rosettaFS.share = try VZLinuxRosettaDirectoryShare()
            shares.append(rosettaFS)
        }

        // Game library — writable. Guest mounts at /mnt/games.
        // Steam's steamapps/ symlink inside the guest points here so game installs
        // land on the expansion disk's games share, surviving base image updates.
        let gamesDir = vmSupportDir.appending(path: "games", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: gamesDir, withIntermediateDirectories: true)
        let gamesShare = VZSharedDirectory(url: gamesDir, readOnly: false)
        let gamesFS = VZVirtioFileSystemDeviceConfiguration(tag: "meridian-games")
        gamesFS.share = VZSingleDirectoryShare(directory: gamesShare)
        shares.append(gamesFS)

        // Steam session / credential staging — read-only. Guest mounts at /mnt/steam-session.
        // Prepared by SteamSessionBridge before VM boot.
        let sessionDir = SteamSessionBridge.stagingDir
        let sessionShare = VZSharedDirectory(url: sessionDir, readOnly: true)
        let sessionFS = VZVirtioFileSystemDeviceConfiguration(tag: "meridian-steam-session")
        sessionFS.share = VZSingleDirectoryShare(directory: sessionShare)
        shares.append(sessionFS)

        return shares
    }

    // MARK: - Resource validation

    private static func validatedCPUCount(_ requested: Int) -> Int {
        let max = VZVirtualMachineConfiguration.maximumAllowedCPUCount
        let min = VZVirtualMachineConfiguration.minimumAllowedCPUCount
        return Swift.min(Swift.max(min, requested), max)
    }

    private static func validatedMemorySize(_ requestedGiB: Int) -> UInt64 {
        let min = VZVirtualMachineConfiguration.minimumAllowedMemorySize
        let max = VZVirtualMachineConfiguration.maximumAllowedMemorySize
        let requested = UInt64(Swift.max(2, requestedGiB)) * 1_024 * 1_024 * 1_024
        return Swift.min(Swift.max(min, requested), max)
    }

    // MARK: - Errors

    enum ConfigError: LocalizedError {
        case kernelNotFound
        case kernelCompressed
        case baseImageNotFound
        case diskCreationFailed

        var errorDescription: String? {
            switch self {
            case .kernelNotFound:
                return "VM kernel (vmlinuz) not found. The base image doesn't include a kernel yet — use 'Set Up VM' to install an updated image."
            case .kernelCompressed:
                return "VM kernel is gzip-compressed. Virtualization.framework requires an uncompressed ARM64 kernel Image. Reinstall VM artifacts with an uncompressed vmlinuz."
            case .baseImageNotFound:
                return "Meridian base image not found. Please provision the VM first."
            case .diskCreationFailed:
                return "Failed to create the VM expansion disk."
            }
        }
    }
}
