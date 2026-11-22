import Foundation
import Darwin

/// Opens a raw disk device read-only. If the device can't be opened directly, Apple's
/// /usr/libexec/authopen shows the standard administrator prompt and passes the
/// open file descriptor back over a Unix socket. The app itself never runs as root.
enum RawDevice {
    enum OpenError: LocalizedError {
        case declined
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .declined: "Administrator approval was declined, so the card couldn't be opened for a surface scan."
            case .failed(let m): m
            }
        }
    }

    static func openReadOnly(_ path: String) throws -> Int32 {
        let direct = open(path, O_RDONLY)
        if direct >= 0 { return direct }

        var fds: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else {
            throw OpenError.failed("Couldn't set up device access: \(String(cString: strerror(errno)))")
        }
        defer { close(fds[0]); close(fds[1]) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/libexec/authopen")
        process.arguments = ["-stdoutpipe", path]
        process.standardOutput = FileHandle(fileDescriptor: fds[1], closeOnDealloc: false)
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch {
            throw OpenError.failed("Couldn't start authopen: \(error.localizedDescription)")
        }
        let fd = receiveDescriptor(fds[0])
        process.waitUntilExit()
        if fd >= 0 { return fd }
        throw OpenError.declined
    }

    /// Receives one file descriptor sent with SCM_RIGHTS. Returns -1 on failure.
    private static func receiveDescriptor(_ socket: Int32) -> Int32 {
        let controlSize = 64
        let control = UnsafeMutableRawPointer.allocate(byteCount: controlSize, alignment: 8)
        defer { control.deallocate() }
        memset(control, 0, controlSize)
        var payload = [UInt8](repeating: 0, count: 64)

        return payload.withUnsafeMutableBytes { bytes -> Int32 in
            var iov = iovec(iov_base: bytes.baseAddress, iov_len: bytes.count)
            return withUnsafeMutablePointer(to: &iov) { iovPtr -> Int32 in
                var msg = msghdr(msg_name: nil, msg_namelen: 0, msg_iov: iovPtr, msg_iovlen: 1,
                                 msg_control: control, msg_controllen: socklen_t(controlSize), msg_flags: 0)
                var r: Int
                repeat { r = recvmsg(socket, &msg, 0) } while r < 0 && errno == EINTR
                guard r > 0, Int(msg.msg_controllen) >= MemoryLayout<cmsghdr>.size else { return -1 }
                let header = control.load(as: cmsghdr.self)
                guard header.cmsg_level == SOL_SOCKET, header.cmsg_type == SCM_RIGHTS else { return -1 }
                // CMSG_DATA: header rounded up to 4-byte alignment on Darwin.
                let dataOffset = (MemoryLayout<cmsghdr>.size + 3) & ~3
                return control.load(fromByteOffset: dataOffset, as: Int32.self)
            }
        }
    }

    /// Device block size and total size via DKIOCGETBLOCKSIZE / DKIOCGETBLOCKCOUNT.
    static func geometry(_ fd: Int32) -> (blockSize: Int64, totalBytes: Int64)? {
        var blockSize: UInt32 = 0
        var blockCount: UInt64 = 0
        let DKIOCGETBLOCKSIZE: UInt = 0x4004_6418   // _IOR('d', 24, uint32_t)
        let DKIOCGETBLOCKCOUNT: UInt = 0x4008_6419  // _IOR('d', 25, uint64_t)
        let okSize = withUnsafeMutablePointer(to: &blockSize) { ioctl(fd, DKIOCGETBLOCKSIZE, UnsafeMutableRawPointer($0)) } == 0
        let okCount = withUnsafeMutablePointer(to: &blockCount) { ioctl(fd, DKIOCGETBLOCKCOUNT, UnsafeMutableRawPointer($0)) } == 0
        guard okSize, okCount, blockSize > 0, blockCount > 0 else { return nil }
        return (Int64(blockSize), Int64(blockCount) * Int64(blockSize))
    }
}
