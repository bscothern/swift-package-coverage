//
//  SwiftPackageCoverage.swift
//  swift-package-coverage
//
//  Created by Braden Scothern on 5/26/21.
//  Copyright © 2021 Braden Scothern. All rights reserved.
//

import ArgumentParser
import Foundation
import LLVMCovJSON
import OptionsModule
import ShellOut
import SwiftyJSON

// Temporary hack around GitHub action's not supporting macOS 11 which means they don't support Xcode 12.5 which adds support for @main in SwiftPM...
#if swift(>=5.4)
@main
extension SwiftPackageCoverageCommand {}
#endif

public struct SwiftPackageCoverageCommand: ParsableCommand {
    public static let configuration: CommandConfiguration = .init(
        commandName: "package-coverage",
        abstract: "Tests a Swift Package and gathers its code coverage.",
        version: "0.1.0" + {
            #if DEBUG
            return "-debug"
            #else
            return ""
            #endif
        }()
    )

    struct ExitError: Swift.Error, CustomStringConvertible {
        let description: String
    }

    @OptionGroup
    var options: Options

    public init() {}

    public mutating func run() {
        if options.cleanBefore {
            runCleanUp()
        }

        runSwiftTestWithCoverage()

        let coverageFilePath = findCoverageFilePath()
        let coverage = processCoverageFile(atPath: coverageFilePath)

        output(coverage: coverage)

        if options.cleanAfter {
            runCleanUp()
        }
    }

    /// Runs `swift test` and generates the coverage file.
    func runSwiftTestWithCoverage() {
        guard !options.skipRun else {
            return
        }

        let arguments = options.arguments
        guard !options.dryRun else {
            print("swift test --enable-code-coverage", terminator: "")
            if !arguments.isEmpty {
                print("", arguments.joined(separator: " "))
            }
            Self.exit(withError: ExitCode.success)
        }
        do {
            try shellOut(
                to: "swift test",
                arguments: ["--enable-code-coverage"] + arguments,
                at: options.runPath
            )
        } catch let error as ShellOutError {
            print(error.output)
            print(error.message)
            Self.exit(withError: ExitError(description: "Unable to run swift tests and gather coverage."))
        } catch {
            Self.exit(withError: ExitError(description: "Unknown Error. Unable to run swift tests and gather coverage. \(error)"))
        }
    }

    /// Finds the coverage file that should be processed.
    func findCoverageFilePath() -> String {
        do {
            return try shellOut(
                to: "swift test",
                arguments: ["--show-codecov-path"],
                at: options.runPath
            )
        } catch let error as ShellOutError {
            print(error.output)
            print(error.message)
            Self.exit(withError: ExitError(description: "Unknown Error. Unable to find coverage file."))
        } catch {
            Self.exit(withError: ExitError(description: "Unknown Error. Unable to find coverage file. \(error)"))
        }
    }

    /// Open and process the coverage JSON file.
    ///
    /// This will remove files that aren't applicable and recalculate totals to create an updated version of the JSON.
    func processCoverageFile(atPath path: String) -> JSON {
        let coverage: JSON
        do {
            let json = try Data(contentsOf: URL(fileURLWithPath: path))
            coverage = try .init(data: json)
        } catch {
            Self.exit(withError: ExitError(description: "Unable to open coverage JSON file: \(path)."))
        }

        // See Documentation/llvm-cov-2.0.1.md for details on this spec.
        var processedCoverage: JSON = [:]
        processedCoverage[.type] = coverage[.type]
        processedCoverage[.version] = coverage[.version]

        func shouldInclude(fileName: String) -> Bool {
            options.includedPaths.contains(where:) { includedPath in
                fileName.contains(includedPath)
            }
        }

        let filesData = JSON(coverage[.data].array?[0][.files].arrayValue.filter { file in
            guard let fileName = file[.filename].string else {
                Self.exit(withError: ExitError(description: "Unexpected JSON format. Unable to parse file data:\n\(file)"))
            }
            return shouldInclude(fileName: fileName)
        } ?? [])

        let functionsData = JSON(coverage[.data].array?[0][.functions].arrayValue.filter { function in
            guard let fileNames = function[.filenames].array?.compactMap(\.string) else {
                Self.exit(withError: ExitError(description: "Unexpected JSON format. Unable to parse function data:\n\(function)"))
            }
            for fileName in fileNames where shouldInclude(fileName: fileName) {
                return true
            }
            return false
        } ?? [])

        let totalSections = [LLVMCovPath.branches, .functions, .instantiations, .lines, .regions]

        var totalsData: JSON = [:]
        for section in totalSections {
            totalsData[section] = [:]
            totalsData[section][.count] = 0
            totalsData[section][.covered] = 0

            if section == .branches || section == .regions {
                totalsData[section][.notcovered] = 0
            }
        }

        for file in filesData.arrayValue {
            for section in totalSections {
                let summary = file[.summary][section]
                totalsData[section][.count].intValue += summary[.count].intValue
                totalsData[section][.covered].intValue += summary[.covered].intValue

                if section == .branches || section == .regions {
                    totalsData[section][.notcovered].intValue += summary[.notcovered].intValue
                }
            }
        }

        for section in totalSections {
            var percentage = 100.0 * totalsData[section][.covered].doubleValue / totalsData[section][.count].doubleValue
            if !percentage.isNormal {
                percentage = 0.0
            }
            totalsData[section][.percent].doubleValue = percentage
        }

        var exportData: JSON = [:]
        exportData[.files] = filesData
        exportData[.functions] = functionsData
        exportData[.totals] = totalsData
        processedCoverage[.data] = [exportData]
        return processedCoverage
    }

    /// Write the coverage data to the appropriate places according to options.
    func output(coverage: JSON) {
        let totals = coverage[.data].arrayValue[0][.totals]
        let section: JSON

        switch options.llvmTotalType {
        case .branches:
            section = totals[.branches]
        case .functions:
            section = totals[.functions]
        case .instantiations:
            section = totals[.instantiations]
        case .lines:
            section = totals[.lines]
        case .regions:
            section = totals[.regions]
        }

        if options.showLineCounts {
            print("""
               Covered: \(section[.covered].intValue)
                 Total: \(section[.count].intValue)
            """)
        }

        if options.showPercentage {
            print("""
            Percentage: \(section[.percent].doubleValue)
            """)
        }

        if let llvmCovJSONOutputPath = options.llvmCovJSONOutputPath {
            do {
                var data = try coverage.rawData(options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
                data.append("\n".data(using: .utf8)!)
                try data.write(to: URL(fileURLWithPath: llvmCovJSONOutputPath))
            } catch {
                Self.exit(withError: ExitError(description: "Unable to write llvm-cov JSON file to: \(llvmCovJSONOutputPath)."))
            }
        }
    }

    /// Deletes .build at the target path
    func runCleanUp() {
        do {
            try shellOut(
                to: "rm",
                arguments: ["-rf", ".build"],
                at: options.runPath)
        } catch {
            Self.exit(withError: ExitError(description: "Unable to clean up after processing coverage. \(error)"))
        }
    }
}
