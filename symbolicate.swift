//
//  symbolicate.swift
//
//  Created by Tomasz Kucharski on 07/10/2021.

// This script loads all *.dSYM files in current directory and tries do apply them
// to symbolicate the crash report
//

import Foundation

struct BacktraceLine {
    let lineNumber: String
    let binaryImageName: String
    let address: String
    let loadAddress: String
}

struct BinaryImage {
    let loadAddress: String
    let name: String
    let architecture: String
    let uuid: String
}

struct DwarfFileInfo {
    let path: String
    let uuid: String
    let architecture: String
    
    var dSYMFileName: String {
        self.path.components(separatedBy: "/").first{ $0.hasSuffix(".dSYM") } ?? self.path
    }
    
    func matches(_ binaryImage: BinaryImage) -> Bool {
        guard self.uuid.lowercased().replacingOccurrences(of: "-", with: "") == binaryImage.uuid.lowercased().replacingOccurrences(of: "-", with: "") else {
            return false
        }
        guard self.architecture == binaryImage.architecture  else { return false }
        return true
    }
}

final class CrashSymbolicator {
    let crashFileName: String
    
    init(crashFileName: String) {
        self.crashFileName = crashFileName
    }
    
    func run() {
        let pwd = shell("pwd")
        print("Working in \(pwd)")

        do {
            let crashUrl = URL(fileURLWithPath: pwd).appendingPathComponent(self.crashFileName)
            
            guard FileManager.default.fileExists(atPath: crashUrl.path) else {
                print("Crash file \(crashUrl.path) does not exists!")
                exit(0)
            }
            
            let dSYMFileNames = try FileManager.default.contentsOfDirectory(atPath: pwd).filter { $0.hasSuffix(".dSYM") }
            
            var dwarfFiles: [DwarfFileInfo] = []
            
            for dSYMFileName in dSYMFileNames {
                var dSYMUrl = URL(fileURLWithPath: pwd).appendingPathComponent(dSYMFileName)
                dSYMUrl.appendPathComponent("Contents/Resources/DWARF")
                let binariesIndSym = try FileManager.default.contentsOfDirectory(atPath: dSYMUrl.path)
                for binaryFile in binariesIndSym {
                    let dwarfUrl = dSYMUrl.appendingPathComponent(binaryFile)
                    let dwarfPath = dwarfUrl.path.replacingOccurrences(of: " ", with: "\\ ")
                    let dwarfDumpOutput = shell("dwarfdump --uuid \(dwarfPath)")
                                            .trimmingCharacters(in: .whitespaces)
                                            .components(separatedBy: .newlines)
                    dwarfFiles.append(contentsOf: dwarfDumpOutput.compactMap{ makeDwarfFileInfo(line: $0) })
                }
            }
            print("---------------------------------------")
            print("Found \(dwarfFiles.count) DWARF files in working directory:\n\(dwarfFiles.map{ $0.description }.joined(separator: "\n"))")
            print("---------------------------------------")
            
            let crashReport = try String(contentsOf: crashUrl, encoding: .utf8)
            let rawStack = getCrashedThreadLines(crashReport: crashReport)
            let binaryImages = getBinaryImages(crashReport: crashReport)
            
            print("This crash report has \(binaryImages.count) binary images assosiated")
            let binaryImagesWithDwarfFiles = binaryImages.compactMap { binaryImage in dwarfFiles.first{ $0.matches(binaryImage) } }
            print("But only \(binaryImagesWithDwarfFiles.count) has corresponding DWARF file")
            print("Desymbolication will use: \(binaryImagesWithDwarfFiles.map{ $0.path.relative(to: pwd) }.joined(separator: ", "))")
            print("---------------------------------------")

            print("Crash stack")
            for line in rawStack {
                
                if let stackEntry = makeBacktraceLine(line: line),
                   let binaryImage = (binaryImages.first{ $0.loadAddress == stackEntry.loadAddress && $0.name == stackEntry.binaryImageName }),
                   let dwarfFile = (dwarfFiles.first{ $0.matches(binaryImage) }) {
                    let command = "atos -arch \(binaryImage.architecture) -o \(dwarfFile.path) -l \(binaryImage.loadAddress) \(stackEntry.address)"
                    let atosOutput = shell(command)
                    
                    if let index = line.range(of: "0x")?.lowerBound {
                        print("\(line[..<index])\(atosOutput)")
                    } else {
                        print(line)
                    }
                } else {
                    print(line)
                }
            }
        } catch {
            print("\(error)")
        }
    }

    @discardableResult
    func shell(_ command: String) -> String {
        let task = Process()
        let pipe = Pipe()
        
        task.standardOutput = pipe
        task.standardError = pipe
        task.arguments = ["-c", command]
        task.launchPath = "/bin/zsh"
        task.launch()
        
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8)!
        
        return output.trimmingCharacters(in: .newlines)
    }

    @discardableResult
    func shellWithLiveOutput(_ args: String...) -> Int32 {
        let task = Process()
        task.launchPath = "/usr/bin/env"
        task.arguments = args
        task.launch()
        task.waitUntilExit()
        return task.terminationStatus
    }

    func getCrashedThreadLines(crashReport: String) -> [String] {
        let crashLines = crashReport.components(separatedBy: .newlines)
        var stack: [String] = []
        var stackRecording = false
        for line in crashLines {
            if stackRecording, line.contains("Thread") {
                return stack
            }
            if stackRecording {
                stack.append(line)
            }
            if line.contains("Thread"), line.contains("Crashed:") {
                stackRecording = true
            }
        }
        return stack
    }

    func getBinaryImages(crashReport: String) -> [BinaryImage] {
        var output: [String] = []
        let crashLines = crashReport.components(separatedBy: .newlines)
        var recording = false
        for line in crashLines {
            let cleanLine = line.trimmingCharacters(in: .whitespaces)
            if recording {
                if cleanLine.starts(with: "0x") {
                    output.append(cleanLine)
                } else {
                    return output.compactMap{ makeBinaryImage(line: $0) }
                }
            }
            if line.contains("Binary Images:") {
                recording = true
            }
        }
        return output.compactMap{ makeBinaryImage(line: $0) }
    }

    func makeBacktraceLine(line: String) -> BacktraceLine? {
        var parts = line.components(separatedBy: .whitespaces)
        parts.reverse()
        guard let lineNumber = parts.popLast() else { return nil }
        let clearedLine = line
            .trimmingCharacters(in: CharacterSet(charactersIn: "1234567890"))
            .trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "+"))
            .trimmingCharacters(in: .whitespaces)
        parts = clearedLine.components(separatedBy: " ").filter{ !$0.isEmpty }
        
        guard let loadAddress = parts.popLast(), let address = parts.popLast() else { return nil }
        let moduleName = parts.joined(separator: " ")
        return BacktraceLine(lineNumber: lineNumber, binaryImageName: moduleName, address: address, loadAddress: loadAddress)

    }

    func makeBinaryImage(line: String) -> BinaryImage? {
        var parts = line.components(separatedBy: .whitespaces)
        parts.reverse()
        guard let loadAddress = parts.popLast() else { return nil }
        parts.removeLast(2)
        parts.reverse()
        parts = parts.joined(separator: " ").components(separatedBy: "<")
        guard let uuid = parts[1].components(separatedBy: ">").first else { return nil }
        parts = parts[0].trimmingCharacters(in: .whitespaces).components(separatedBy: " ")
        guard let architecture = parts.popLast() else { return nil }
        let moduleName = parts.joined(separator: " ").trimmingCharacters(in: .whitespaces)
        return BinaryImage(loadAddress: loadAddress, name: moduleName, architecture: architecture, uuid: uuid)
    }

    func makeDwarfFileInfo(line: String) -> DwarfFileInfo? {
        var parts = line.components(separatedBy: ")")
        guard parts.count > 1 else { return nil }
        let path = parts[1].trimmingCharacters(in: .whitespaces).replacingOccurrences(of: " ", with: "\\ ")
        parts = parts[0].components(separatedBy: "(")
        let architecture = parts[1]
        let uuid = parts[0].replacingOccurrences(of: "UUID:", with: "").trimmingCharacters(in: .whitespaces)
        return DwarfFileInfo(path: path, uuid: uuid, architecture: architecture)
    }
}


extension BacktraceLine: CustomStringConvertible {
    var description: String {
        "{ line: \(lineNumber), name: \(binaryImageName), address: \(address), loadAddress: \(loadAddress) }"
    }
}

extension BinaryImage: CustomStringConvertible {
    var description: String {
        "{ uuid: \(uuid), loadAddress: \(loadAddress), name: \(name), architecture: \(architecture) }"
    }
}

extension DwarfFileInfo: CustomStringConvertible {
    var description: String {
        "{ UUID: \(uuid), arch: \(architecture), dSYMFileName: \(dSYMFileName) }"
    }
}

extension String {
    func relative(to path: String) -> String {
        return self.replacingOccurrences(of: "\(path)/", with: "")
    }
}

let namedArguments = UserDefaults.standard
guard let crashFile = namedArguments.string(forKey: "crash") else {
    print("Provide crash file name with -crash flag")
    exit(0)
}
CrashSymbolicator(crashFileName: crashFile).run()

