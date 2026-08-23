//
//  SensorPairingService.swift
//  LibreDirect
//
//  Created by Reimar Metzen on 06.07.21.
//

import Foundation
import Combine
import CoreNFC
import OSLog

public enum PairingError: Error {
    case noTagInfo
    case noSensorData
    case incompleteSensorData
    case wrongSensorType
    case unsupportedLibre2PlusBrazil
    case decryptionError
    case noPatchInfo
    case nfcNotSupported
}

extension PairingError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .noTagInfo:
            return LocalizedString("Could not get tag info", comment: "error description for PairingError.noTagInfo")
        case .noSensorData:
            return LocalizedString("Could not get sensor data", comment: "error description for PairingError.noSensorData")
        case .incompleteSensorData:
            return LocalizedString("The NFC scan did not read the complete sensor data", comment: "error description for PairingError.incompleteSensorData")
        case .wrongSensorType:
            return LocalizedString("Wrong sensor type detected", comment: "error description for PairingError.wrongSensorType")
        case .unsupportedLibre2PlusBrazil:
            return LocalizedString("Brazilian Libre 2 Plus direct connection is not supported yet", comment: "error description for PairingError.unsupportedLibre2PlusBrazil")
        case .decryptionError:
            return LocalizedString("Could not decrypt sensor contents", comment: "error description for PairingError.decryptionError")
        case .noPatchInfo:
            return LocalizedString("Could not get patch info", comment: "error description for PairingError.noPatchInfo")
        case .nfcNotSupported:
            return LocalizedString("Phone NFC not supported!", comment: "error description for PairingError.nfcNotSupported")
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case .nfcNotSupported:
            return LocalizedString("Your phone or app is not enabled for NFC communications, which is needed to pair to libre2 sensors", comment: "Recovery suggestion for PairingError.nfcNotSupported")
        case .incompleteSensorData:
            return LocalizedString("Keep the top of the iPhone steadily over the sensor and try the NFC scan again.", comment: "Recovery suggestion for PairingError.incompleteSensorData")
        case .unsupportedLibre2PlusBrazil:
            return LocalizedString("This regional sensor uses a different NFC and Bluetooth protocol. No streaming command was sent and no sensor setting was changed. Continue using the official app or a supported cloud CGM source.", comment: "Recovery suggestion for PairingError.unsupportedLibre2PlusBrazil")
        default:
            return nil
        }
    }
}

public class SensorPairingService: NSObject, NFCTagReaderSessionDelegate, SensorPairingProtocol {
    private var session: NFCTagReaderSession?
    private var readingsSubject = PassthroughSubject<SensorPairingInfo, Never>()
    private var errorSubject  = PassthroughSubject<Error, Never>()
    private lazy var logger = Logger(forType: Self.self)
    private var didReportPairingError = false

    private let nfcQueue = DispatchQueue(label: "libre-direct.nfc-queue")
    private let accessQueue = DispatchQueue(label: "libre-direct.nfc-access-queue")
    private static let diagnosticQueue = DispatchQueue(label: "libre-direct.pairing-diagnostics")

    private static let framBlockCount = 43
    private static let framBlockSize = 8
    private static let blocksPerRequest = 3

    private let unlockCode: UInt32 = 42 // 42

    public var onCancel: (() -> Void)?

    public func pairSensor() throws {
        if !Features.phoneNFCAvailable {
            throw PairingError.nfcNotSupported
        }
        didReportPairingError = false
        logPairingDiagnostic("pairing started; NFC available=\(Features.phoneNFCAvailable)")

        if NFCTagReaderSession.readingAvailable {
            accessQueue.async {
                self.session = NFCTagReaderSession(pollingOption: .iso15693, delegate: self, queue: self.nfcQueue)
                self.session?.alertMessage = LocalizedString("Hold the top of your iPhone near the sensor to pair", comment: "")
                self.session?.begin()
            }
        }
    }

    public var publisher: AnyPublisher<SensorPairingInfo, Never> {
        readingsSubject.eraseToAnyPublisher()
    }
    
    public var errorPublisher: AnyPublisher<Error, Never> {
        errorSubject.eraseToAnyPublisher()
    }
    
    private func sendError(_ error: Error) {
        DispatchQueue.main.async { [weak self] in
            self?.errorSubject.send(error)
        }
    }

    private func sendUpdate(_ info: SensorPairingInfo) {
        DispatchQueue.main.async { [weak self] in
            self?.readingsSubject.send(info)
        }
    }

    private func report(_ error: PairingError, in session: NFCTagReaderSession) {
        didReportPairingError = true
        logPairingDiagnostic("pairing failed: \(error.localizedDescription)")
        session.invalidate(errorMessage: error.localizedDescription)
        sendError(error)
    }

    private func logPairingDiagnostic(_ message: String) {
        logger.info("\(message, privacy: .public)")

        Self.diagnosticQueue.async {
            let fileManager = FileManager.default
            guard let documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first else { return }

            let directory = documents.appendingPathComponent("libreloop", isDirectory: true)
            let fileURL = directory.appendingPathComponent("pairing-diagnostics.log")

            do {
                try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

                if let size = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                   size > 256 * 1024
                {
                    try? fileManager.removeItem(at: fileURL)
                }

                if !fileManager.fileExists(atPath: fileURL.path) {
                    fileManager.createFile(atPath: fileURL.path, contents: nil)
                }

                let timestamp = ISO8601DateFormatter().string(from: Date())
                guard let data = "\(timestamp) \(message)\n".data(using: .utf8) else { return }
                let handle = try FileHandle(forWritingTo: fileURL)
                handle.seekToEndOfFile()
                handle.write(data)
                handle.closeFile()
            } catch {
                // Diagnostics must never interrupt sensor setup.
            }
        }
    }

    public func tagReaderSessionDidBecomeActive(_ session: NFCTagReaderSession) {
    }

    public func tagReaderSession(_ session: NFCTagReaderSession, didInvalidateWithError error: Error) {
        if let error = error as? NFCReaderError,
           error.code != .readerSessionInvalidationErrorUserCanceled,
           !didReportPairingError
        {
            logPairingDiagnostic("NFC session invalidated: \(error.localizedDescription)")
            session.invalidate(errorMessage: "Connection failure: \(error.localizedDescription)")
            self.sendError(error)
        }

        self.onCancel?()
    }

    public func tagReaderSession(_ session: NFCTagReaderSession, didDetect tags: [NFCTag]) {
        guard let firstTag = tags.first else { return }
        guard case .iso15693(let tag) = firstTag else { return }

        session.connect(to: firstTag) { error in
            if let error {
                self.logPairingDiagnostic("NFC tag connection failed: \(error.localizedDescription)")
                self.report(.noTagInfo, in: session)
                return
            }

            tag.getSystemInfo(requestFlags: [.address, .highDataRate]) { result in
                switch result {
                case .failure(let error):
                    self.logPairingDiagnostic("NFC system info failed: \(error.localizedDescription)")
                    self.report(.noTagInfo, in: session)
                    return
                case .success:
                    tag.customCommand(requestFlags: .highDataRate, customCommandCode: 0xA1, customRequestParameters: Data()) { response, error in
                        if let error {
                            self.logPairingDiagnostic("NFC patch info command failed: \(error.localizedDescription)")
                            self.report(.noPatchInfo, in: session)
                            return
                        }

                        let patchInfo = response
                        guard patchInfo.count == 6 else {
                            self.logPairingDiagnostic("invalid patch info length=\(patchInfo.count)")
                            self.report(.noPatchInfo, in: session)
                            return
                        }

                        let sensorType = SensorType(patchInfo: patchInfo)
                        let patchSignature = Data(patchInfo.prefix(4)).hexEncodedString().uppercased()
                        self.logPairingDiagnostic("sensor signature=\(patchSignature); type=\(sensorType.description)")

                        if sensorType == .libre2BR {
                            self.report(.unsupportedLibre2PlusBrazil, in: session)
                            return
                        }

                        guard sensorType == .libre2 else {
                            self.report(.wrongSensorType, in: session)
                            return
                        }

                        self.readFRAMBlocks(from: tag) { result in
                            switch result {
                            case .failure(let error):
                                self.logPairingDiagnostic("FRAM read failed: \(error.localizedDescription)")
                                self.report(.incompleteSensorData, in: session)
                            case .success(let fram):
                                let sensorUID = Data(tag.identifier.reversed())
                                let expectedFRAMSize = Self.framBlockCount * Self.framBlockSize

                                guard sensorUID.count == 8, fram.count == expectedFRAMSize else {
                                    self.logPairingDiagnostic("invalid NFC payload lengths; uid=\(sensorUID.count), fram=\(fram.count), expected=\(expectedFRAMSize)")
                                    self.report(.incompleteSensorData, in: session)
                                    return
                                }

                                let decryptedBytes: [UInt8]
                                do {
                                    decryptedBytes = try Libre2.decryptFRAM(
                                        type: sensorType,
                                        id: [UInt8](sensorUID),
                                        info: patchInfo,
                                        data: [UInt8](fram)
                                    )
                                } catch {
                                    self.logPairingDiagnostic("FRAM decryption failed: \(error.localizedDescription)")
                                    self.report(.decryptionError, in: session)
                                    return
                                }

                                let subCommand: Subcommand = .enableStreaming
                                let command = self.nfcCommand(
                                    subCommand,
                                    unlockCode: self.unlockCode,
                                    patchInfo: patchInfo,
                                    sensorUID: sensorUID
                                )

                                tag.customCommand(
                                    requestFlags: .highDataRate,
                                    customCommandCode: Int(command.code),
                                    customRequestParameters: command.parameters
                                ) { response, error in
                                    let streamingEnabled = error == nil && response.count == 6
                                    let macAddress = streamingEnabled ? Data(response.reversed()).hexEncodedString().uppercased() : nil

                                    if let error {
                                        self.logPairingDiagnostic("streaming command returned an error: \(error.localizedDescription)")
                                    } else {
                                        self.logPairingDiagnostic("pairing completed; streaming enabled=\(streamingEnabled)")
                                    }

                                    self.sendUpdate(SensorPairingInfo(
                                        uuid: sensorUID,
                                        patchInfo: patchInfo,
                                        fram: Data(decryptedBytes),
                                        streamingEnabled: streamingEnabled,
                                        macAddress: macAddress
                                    ))
                                    session.invalidate()
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func readFRAMBlocks(
        from tag: NFCISO15693Tag,
        nextBlock: Int = 0,
        accumulatedData: Data = Data(),
        completion: @escaping (Result<Data, Error>) -> Void
    ) {
        guard nextBlock < Self.framBlockCount else {
            completion(.success(accumulatedData))
            return
        }

        let blockCount = min(Self.blocksPerRequest, Self.framBlockCount - nextBlock)
        let blockRange = NSRange(location: nextBlock, length: blockCount)

        tag.readMultipleBlocks(
            requestFlags: [.highDataRate, .address],
            blockRange: blockRange
        ) { blocks, error in
            if let error {
                completion(.failure(error))
                return
            }

            guard blocks.count == blockCount,
                  blocks.allSatisfy({ $0.count == Self.framBlockSize })
            else {
                completion(.failure(PairingError.incompleteSensorData))
                return
            }

            var updatedData = accumulatedData
            blocks.forEach { updatedData.append($0) }
            self.readFRAMBlocks(
                from: tag,
                nextBlock: nextBlock + blockCount,
                accumulatedData: updatedData,
                completion: completion
            )
        }
    }

    private func readRaw(_ address: UInt16, _ bytes: Int, buffer: Data = Data(), tag: NFCISO15693Tag, handler: @escaping (UInt16, Data, Error?) -> Void) {
        
        var buffer = buffer
        let addressToRead = address + UInt16(buffer.count)

        var remainingBytes = bytes
        let bytesToRead = remainingBytes > 24 ? 24 : bytes

        var remainingWords = bytes / 2
        if bytes % 2 == 1 || (bytes % 2 == 0 && addressToRead % 2 == 1) { remainingWords += 1 }
        let wordsToRead = UInt8(remainingWords > 12 ? 12 : remainingWords) // real limit is 15

        // this is for libre 2 only, ignoring other libre types
        let readRawCommand = NFCCommand(code: 0xB3, parameters: Data([UInt8(addressToRead & 0x00FF), UInt8(addressToRead >> 8), wordsToRead]))

        tag.customCommand(requestFlags: .highDataRate, customCommandCode: Int(readRawCommand.code), customRequestParameters: readRawCommand.parameters) { response, error in
            var data = response

            if error != nil {
                remainingBytes = 0
            } else {
                if addressToRead % 2 == 1 { data = data.subdata(in: 1 ..< data.count) }
                if data.count - Int(bytesToRead) == 1 { data = data.subdata(in: 0 ..< data.count - 1) }
            }

            buffer += data
            remainingBytes -= data.count

            if remainingBytes == 0 {
                handler(address, buffer, error)
            } else {
                self.readRaw(address, remainingBytes, buffer: buffer, tag: tag) { address, data, error in handler(address, data, error) }
            }
        }
    }

    private func writeRaw(_ address: UInt16, _ data: Data, tag: NFCISO15693Tag, handler: @escaping (UInt16, Data, Error?) -> Void) {
        let backdoor = "deadbeef".utf8

        tag.customCommand(requestFlags: .highDataRate, customCommandCode: 0xA4, customRequestParameters: Data(backdoor)) {
            _, error in

            let addressToRead = (address / 8) * 8
            let startOffset = Int(address % 8)
            let endAddressToRead = ((Int(address) + data.count - 1) / 8) * 8 + 7
            let blocksToRead = (endAddressToRead - Int(addressToRead)) / 8 + 1

            self.readRaw(addressToRead, blocksToRead * 8, tag: tag) { _, readData, error in
                if error != nil {
                    handler(address, data, error)
                    return
                }

                var bytesToWrite = readData
                bytesToWrite.replaceSubrange(startOffset ..< startOffset + data.count, with: data)

                let startBlock = Int(addressToRead / 8)
                let blocks = bytesToWrite.count / 8

                if address < 0xF860 { // lower than FRAM blocks
                    for i in 0 ..< blocks {
                        let blockToWrite = bytesToWrite[i * 8 ... i * 8 + 7]

                        // FIXME: doesn't work as the custom commands C1 or A5 for other chips
                        tag.extendedWriteSingleBlock(requestFlags: .highDataRate, blockNumber: startBlock + i, dataBlock: blockToWrite) { error in
                            if error != nil {
                                if i != blocks - 1 { return }
                            }

                            if i == blocks - 1 {
                                tag.customCommand(requestFlags: .highDataRate, customCommandCode: 0xA2, customRequestParameters: Data(backdoor)) { _, error in
                                    handler(address, data, error)
                                }
                            }
                        }
                    }

                } else { // address >= 0xF860: write to FRAM blocks
                    let requestBlocks = 2 // 3 doesn't work
                    let requests = Int(ceil(Double(blocks) / Double(requestBlocks)))
                    let remainder = blocks % requestBlocks
                    var blocksToWrite = [Data](repeating: Data(), count: blocks)

                    for i in 0 ..< blocks {
                        blocksToWrite[i] = Data(bytesToWrite[i * 8 ... i * 8 + 7])
                    }

                    for i in 0 ..< requests {
                        let startIndex = startBlock - 0xF860 / 8 + i * requestBlocks
                        let endIndex = startIndex + (i == requests - 1 ? (remainder == 0 ? requestBlocks : remainder) : requestBlocks) - (requestBlocks > 1 ? 1 : 0)
                        let blockRange = NSRange(UInt8(startIndex) ... UInt8(endIndex))

                        var dataBlocks = [Data]()
                        for j in startIndex ... endIndex { dataBlocks.append(blocksToWrite[j - startIndex]) }

                        // TODO: write to 16-bit addresses as the custom cummand C4 for other chips
                        tag.writeMultipleBlocks(requestFlags: [.highDataRate, .address], blockRange: blockRange, dataBlocks: dataBlocks) { error in // TEST
                            if error != nil {
                                if i != requests - 1 { return }
                            }

                            if i == requests - 1 {
                                // Lock
                                tag.customCommand(requestFlags: .highDataRate, customCommandCode: 0xA2, customRequestParameters: Data(backdoor)) {
                                    _, error in

                                    handler(address, data, error)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func nfcCommand(_ code: Subcommand, unlockCode: UInt32, patchInfo: Data, sensorUID: Data) -> NFCCommand {
        var b: [UInt8] = []
        var y: UInt16

        if code == .enableStreaming {
            // Enables Bluetooth on Libre 2. Returns peripheral MAC address to connect to.
            // unlockCode could be any 32 bit value. The unlockCode and sensor Uid / patchInfo
            // will have also to be provided to the login function when connecting to peripheral.
            b = [UInt8(unlockCode & 0xFF), UInt8((unlockCode >> 8) & 0xFF), UInt8((unlockCode >> 16) & 0xFF), UInt8((unlockCode >> 24) & 0xFF)]
            y = UInt16(patchInfo[4...5]) ^ UInt16(b[1], b[0])
        } else {
            y = 0x1b6a
        }

        let d = Libre2.usefulFunction(id: [UInt8](sensorUID), x: UInt16(code.rawValue), y: y)

        var parameters = Data([code.rawValue])

        if code == .enableStreaming {
            parameters += b
        }

        parameters += d

        return NFCCommand(code: 0xA1, parameters: parameters)
    }
}

extension UInt16 {
    init(_ high: UInt8, _ low: UInt8) {
        self = UInt16(high) << 8 + UInt16(low)
    }

    init(_ data: Data) {
        self = UInt16(data[data.startIndex + 1]) << 8 + UInt16(data[data.startIndex])
    }
}

private struct NFCCommand {
    let code: UInt8
    let parameters: Data
}

private enum Subcommand: UInt8, CustomStringConvertible {
    case activate = 0x1b
    case enableStreaming = 0x1e
    case unknown0x1a = 0x1a
    case unknown0x1c = 0x1c
    case unknown0x1d = 0x1d
    case unknown0x1f = 0x1f

    var description: String {
        switch self {
        case .activate: return "activate"
        case .enableStreaming: return "enable BLE streaming"
        default: return "[unknown: 0x\(String(format: "%x", rawValue))]"
        }
    }
}
