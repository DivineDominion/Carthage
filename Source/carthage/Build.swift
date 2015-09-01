//
//  Build.swift
//  Carthage
//
//  Created by Justin Spahr-Summers on 2014-10-11.
//  Copyright (c) 2014 Carthage. All rights reserved.
//

import Box
import CarthageKit
import Commandant
import Foundation
import Result
import ReactiveCocoa
import ReactiveTask

public struct BuildCommand: CommandType {
	public let verb = "build"
	public let function = "Build the project's dependencies"

	public func run(mode: CommandMode) -> Result<(), CommandantError<CarthageError>> {
		return producerWithOptions(BuildOptions.evaluate(mode))
			|> flatMap(.Merge) { options in
				return self.buildWithOptions(options)
					|> promoteErrors
			}
			|> waitOnCommand
	}

	/// Builds a project with the given options.
	public func buildWithOptions(options: BuildOptions) -> SignalProducer<(), CarthageError> {
		return self.openLoggingHandle(options)
			|> flatMap(.Merge) { (stdoutHandle, temporaryURL) -> SignalProducer<(), CarthageError> in
				let directoryURL = NSURL.fileURLWithPath(options.directoryPath, isDirectory: true)!

				var buildProgress = self.buildProjectInDirectoryURL(directoryURL, options: options)
					|> flatten(.Concat)

				let stderrHandle = NSFileHandle.fileHandleWithStandardError()

				// Redirect any error-looking messages from stdout, because
				// Xcode doesn't always forward them.
				if !options.verbose {
					let (stdoutProducer, stdoutSink) = SignalProducer<NSData, NoError>.buffer(0)
					let grepTask: BuildSchemeProducer = launchTask(TaskDescription(launchPath: "/usr/bin/grep", arguments: [ "--extended-regexp", "(warning|error|failed):" ], standardInput: stdoutProducer))
						|> on(next: { taskEvent in
							switch taskEvent {
							case let .StandardOutput(data):
								stderrHandle.writeData(data)

							default:
								break
							}
						})
						|> catch { _ in .empty }
						|> then(.empty)
						|> promoteErrors(CarthageError.self)

					buildProgress = buildProgress
						|> on(next: { taskEvent in
							switch taskEvent {
							case let .StandardOutput(data):
								sendNext(stdoutSink, data)

							default:
								break
							}
						}, terminated: {
							sendCompleted(stdoutSink)
						}, interrupted: {
							sendInterrupted(stdoutSink)
						})

					buildProgress = SignalProducer(values: [ grepTask, buildProgress ])
						|> flatten(.Merge)
				}

				let formatting = options.colorOptions.formatting

				return buildProgress
					|> on(started: {
						if let path = temporaryURL?.path {
							carthage.println(formatting.bullets + "xcodebuild output can be found in " + formatting.path(string: path))
						}
					}, next: { taskEvent in
						switch taskEvent {
						case let .StandardOutput(data):
							stdoutHandle.writeData(data)

						case let .StandardError(data):
							stderrHandle.writeData(data)

						case let .Success(box):
							let (project, scheme) = box.value
							carthage.println(formatting.bullets + "Building scheme " + formatting.quote(scheme) + " in " + formatting.projectName(string: project.description))
						}
					})
					|> then(.empty)
			}
	}

	/// Builds the project in the given directory, using the given options.
	///
	/// Returns a producer of producers, representing each scheme being built.
	private func buildProjectInDirectoryURL(directoryURL: NSURL, options: BuildOptions) -> SignalProducer<BuildSchemeProducer, CarthageError> {
		let project = Project(directoryURL: directoryURL)

		var eventSink = ProjectEventSink(colorOptions: options.colorOptions)
		project.projectEvents.observe(next: { eventSink.put($0) })

		let buildProducer = project.loadCombinedCartfile()
			|> map { _ in project }
			|> catch { error in
				if options.skipCurrent {
					return SignalProducer(error: error)
				} else {
					// Ignore Cartfile loading failures. Assume the user just
					// wants to build the enclosing project.
					return .empty
				}
			}
			|> flatMap(.Merge) { project in
				return project.migrateIfNecessary(options.colorOptions)
					|> on(next: carthage.println)
					|> then(SignalProducer(value: project))
			}
			|> flatMap(.Merge) { project in
				return project.buildCheckedOutDependenciesWithConfiguration(options.configuration, forPlatforms: options.buildPlatformList.platforms)
			}

		if options.skipCurrent {
			return buildProducer
		} else {
			let currentProducers = buildInDirectory(directoryURL, withConfiguration: options.configuration, platforms: options.buildPlatformList.platforms)
				|> catch { error -> SignalProducer<BuildSchemeProducer, CarthageError> in
					switch error {
					case let .NoSharedFrameworkSchemes(project, _):
						// Log that building the current project is being skipped.
						eventSink.put(.SkippedBuilding(project, error.description))
						return .empty

					default:
						return SignalProducer(error: error)
					}
				}
			return buildProducer |> concat(currentProducers)
		}
	}

	/// Opens a temporary file on disk, returning a handle and the URL to the
	/// file.
	private func openTemporaryFile() -> SignalProducer<(NSFileHandle, NSURL), NSError> {
		return SignalProducer.try {
			var temporaryDirectoryTemplate: ContiguousArray<CChar> = NSTemporaryDirectory().stringByAppendingPathComponent("carthage-xcodebuild.XXXXXX.log").nulTerminatedUTF8.map { CChar($0) }
			let logFD = temporaryDirectoryTemplate.withUnsafeMutableBufferPointer { (inout template: UnsafeMutableBufferPointer<CChar>) -> Int32 in
				return mkstemps(template.baseAddress, 4)
			}

			if logFD < 0 {
				return .failure(NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: nil))
			}

			let temporaryPath = temporaryDirectoryTemplate.withUnsafeBufferPointer { (ptr: UnsafeBufferPointer<CChar>) -> String in
				return String.fromCString(ptr.baseAddress)!
			}

			let handle = NSFileHandle(fileDescriptor: logFD, closeOnDealloc: true)
			let fileURL = NSURL.fileURLWithPath(temporaryPath, isDirectory: false)!
			return .success((handle, fileURL))
		}
	}

	/// Opens a file handle for logging, returning the handle and the URL to any
	/// temporary file on disk.
	private func openLoggingHandle(options: BuildOptions) -> SignalProducer<(NSFileHandle, NSURL?), CarthageError> {
		if options.verbose {
			let out: (NSFileHandle, NSURL?) = (NSFileHandle.fileHandleWithStandardOutput(), nil)
			return SignalProducer(value: out)
		} else {
			return openTemporaryFile()
				|> map { handle, URL in (handle, .Some(URL)) }
				|> mapError { error in
					let temporaryDirectoryURL = NSURL.fileURLWithPath(NSTemporaryDirectory(), isDirectory: true)!
					return .WriteFailed(temporaryDirectoryURL, error)
				}
		}
	}
}

public struct BuildOptions: OptionsType {
	public let configuration: String
	public let buildPlatformList: BuildPlatformList
	public let skipCurrent: Bool
	public let colorOptions: ColorOptions
	public let verbose: Bool
	public let directoryPath: String

	public static func create(configuration: String)(buildPlatformList: BuildPlatformList)(skipCurrent: Bool)(colorOptions: ColorOptions)(verbose: Bool)(directoryPath: String) -> BuildOptions {
		return self(configuration: configuration, buildPlatformList: buildPlatformList, skipCurrent: skipCurrent, colorOptions: colorOptions, verbose: verbose, directoryPath: directoryPath)
	}

	public static func evaluate(m: CommandMode) -> Result<BuildOptions, CommandantError<CarthageError>> {
		return create
			<*> m <| Option(key: "configuration", defaultValue: "Release", usage: "the Xcode configuration to build")
			<*> m <| Option(key: "platform", defaultValue: BuildPlatformList(), usage: "the platforms to build for (one of ‘all’, ‘Mac’, ‘iOS’, ‘watchOS’ or comma-separated values of the formers except for ‘all’)")
			<*> m <| Option(key: "skip-current", defaultValue: true, usage: "don't skip building the Carthage project (in addition to its dependencies)")
			<*> ColorOptions.evaluate(m)
			<*> m <| Option(key: "verbose", defaultValue: false, usage: "print xcodebuild output inline")
			<*> m <| Option(defaultValue: NSFileManager.defaultManager().currentDirectoryPath, usage: "the directory containing the Carthage project")
	}
}

/// Represents the user’s chosen platform to build for.
public enum BuildPlatform {
	/// Build for all available platforms.
	case All

	/// Build only for iOS.
	case iOS

	/// Build only for OS X.
	case Mac

	/// Build only for watchOS.
	case watchOS

	/// The `Platform` corresponding to this setting.
	public var platform: Platform? {
		switch self {
		case .All:
			return nil

		case .iOS:
			return .iOS

		case .Mac:
			return .Mac

		case .watchOS:
			return .watchOS
		}
	}

	private static let acceptedStrings: [String: BuildPlatform] = [
		"Mac": .Mac, "macosx": .Mac,
		"iOS": .iOS, "iphoneos": .iOS, "iphonesimulator": .iOS,
		"watchOS": .watchOS, "watchsimulator": .watchOS,
		"all": .All
	]
}

extension BuildPlatform: Printable {
	public var description: String {
		switch self {
		case .All:
			return "all"

		case .iOS:
			return "iOS"

		case .Mac:
			return "Mac"

		case .watchOS:
			return "watchOS"
		}
	}
}

/// A wrapper type for a list of `BuildPlatform` which can be used as `ArgumentType`.
public struct BuildPlatformList {
	let buildPlatforms: [BuildPlatform]

	public init(_ buildPlatforms: [BuildPlatform] = []) {
		self.buildPlatforms = buildPlatforms
	}

	/// The set of `Platform` corresponding to this setting.
	public var platforms: Set<Platform> {
		return buildPlatforms.reduce([]) { (var set, buildPlatform) in
			if let platform = buildPlatform.platform {
				set.insert(platform)
			}
			return set
		}
	}
}

extension BuildPlatformList: ArgumentType {
	public static let name = "platform"

	public static func fromString(string: String) -> BuildPlatformList? {
		let commaSeparated = split(string, allowEmptySlices: false) { $0 == "," }

		let findBuildPlatform: String -> BuildPlatform? = { string in
			for (key, platform) in BuildPlatform.acceptedStrings {
				if string.caseInsensitiveCompare(key) == NSComparisonResult.OrderedSame {
					return platform
				}
			}
			return nil
		}

		switch commaSeparated.count {
		case 0:
			return nil

		case 1:
			return findBuildPlatform(commaSeparated[0]).map { BuildPlatformList([ $0 ]) }

		default:
			var buildPlatforms = [BuildPlatform]()
			for string in commaSeparated {
				if let found = findBuildPlatform(string) where found != .All {
					buildPlatforms.append(found)
				} else {
					// Reject if an invalid value is included in the comma-
					// separated string.
					return nil
				}
			}
			return BuildPlatformList(buildPlatforms)
		}
	}
}
