import Darwin
import Foundation

final class LineProcess {
    private let process = Process()
    private let writer: FileHandle
    private let reader: FileHandle
    private let name: String
    private var buffer = Data()

    init(executable: URL, arguments: [String], name: String) throws {
        let input = Pipe()
        let output = Pipe()
        writer = input.fileHandleForWriting
        reader = output.fileHandleForReading
        self.name = name
        _ = fcntl(writer.fileDescriptor, F_SETNOSIGPIPE, 1)
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
    }

    deinit {
        try? writer.close()
        if process.isRunning { process.terminate() }
    }

    func writeLine(_ payload: Data) throws {
        var data = payload
        data.append(10)
        try writer.write(contentsOf: data)
    }

    func readLine(deadline: UInt64) throws -> Data {
        while true {
            let now = DispatchTime.now().uptimeNanoseconds
            guard now < deadline else { throw MemoryError.invalid("读取 \(name) 超时。") }
            if let end = buffer.firstIndex(of: 10) {
                let line = Data(buffer[..<end])
                buffer.removeSubrange(...end)
                return line
            }
            guard buffer.count < 64 * 1024 * 1024 else { throw MemoryError.invalid("\(name) 响应过大。") }
            var descriptor = pollfd(fd: reader.fileDescriptor, events: Int16(POLLIN), revents: 0)
            let count = Darwin.poll(&descriptor, 1, Int32((deadline - now) / 1_000_000 + 1))
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { throw MemoryError.invalid("读取 \(name) 超时。") }
            let data = reader.availableData
            guard !data.isEmpty else { throw MemoryError.invalid("\(name) 已退出。") }
            buffer.append(data)
        }
    }
}
