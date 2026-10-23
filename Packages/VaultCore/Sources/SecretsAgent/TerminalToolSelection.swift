import Darwin
import Foundation

/// Uses the existing terminal without buffering input that the target program must receive.
public enum TerminalToolSelection {
    public static func choose(profiles: [SecretsProfile], input: Int32 = STDIN_FILENO, output: Int32 = STDERR_FILENO) throws -> SecretsProfile? {
        guard isatty(input) == 1, isatty(output) == 1 else {
            throw SecretsFailure("Tool selection requires a terminal. Use tw tools list, then use tw run --profile ID.")
        }
        let menu = try SavedToolSelection(profiles: profiles)
        try write("Choose a saved tool\n\n" + menu.text + "\n\n", to: output)
        while true {
            try write("Tool number (1-\(menu.profiles.count)), or q to cancel: ", to: output)
            guard let line = try readLine(from: input) else { return nil }
            do { return try menu.select(line) }
            catch let error as SecretsFailure { try write(error.message + "\n", to: output) }
        }
    }

    private static func readLine(from fd: Int32) throws -> String? {
        var bytes: [UInt8] = []
        while true {
            var byte: UInt8 = 0
            let count = Darwin.read(fd, &byte, 1)
            if count == 0 { return nil }
            if count < 0 {
                if errno == EINTR { continue }
                throw SecretsFailure("Cannot read the terminal. No tool was started.")
            }
            if byte == 10 || byte == 13 { return String(decoding: bytes, as: UTF8.self) }
            guard bytes.count < 64 else { throw SecretsFailure("The selection is too long. No tool was started.") }
            bytes.append(byte)
        }
    }

    private static func write(_ text: String, to fd: Int32) throws {
        try Data(text.utf8).withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.write(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw SecretsFailure("Cannot write to the terminal. No tool was started.") }
                offset += count
            }
        }
    }
}
