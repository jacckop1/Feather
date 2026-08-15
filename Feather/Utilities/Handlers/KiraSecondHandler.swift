//
//  KiraSecondHandler.swift
//  Feather
//
//  Native Kira Second / Stealth GuardChain injector.
//

import Foundation
import Zip
import ZsignSwift
import OSLog

final class KiraSecondHandler {
	private let fileManager = FileManager.default
	private let app: URL

	private let requiredLoads = [
		"@loader_path/../iKiraPlus.dylib",
		"@loader_path/../UIDisplayServices.dylib",
		"@loader_path/../SystemEnvironment.framework/SystemEnvironment",
		"@loader_path/../ProcessServices.framework/ProcessServices",
		"@loader_path/../CoreLifecycle.framework/CoreLifecycle",
		"@loader_path/../UIInfrastructure.framework/UIInfrastructure",
		"@loader_path/../ProcessSupport.framework/ProcessSupport"
	]

	private let guardFrameworkNames: Set<String> = [
		"SystemEnvironment",
		"ProcessServices",
		"CoreLifecycle",
		"UIInfrastructure",
		"ProcessSupport"
	]

	private let bridgeRelativePath = "SystemEnvironment.framework/SystemEnvironment"
	private let bridgeSelfLoad = "@loader_path/../SystemEnvironment.framework/SystemEnvironment"
	private let bootstrapLoad = "@executable_path/Frameworks/SystemEnvironment.framework/SystemEnvironment"

	init(app: URL) {
		self.app = app
	}

	func inject() async throws {
		guard let mainExecutable = Bundle(url: app)?.executableURL else {
			throw KiraSecondError.mainExecutableNotFound
		}

		Logger.misc.info("Kira Second: preparing embedded GuardChain assets")
		try await _installEmbeddedAssets()

		if let anchor = try _chooseAnchor(mainExecutable: mainExecutable) {
			Logger.misc.info("Kira Second: using anchor framework \(anchor.lastPathComponent)")
			try _injectRequiredLoads(into: anchor, loads: requiredLoads)
			try _verify(executable: anchor, requires: requiredLoads)
		} else {
			Logger.misc.info("Kira Second: no suitable original framework, using bridge mode")
			try _buildBridge(mainExecutable: mainExecutable)
		}
	}
}

// MARK: - Assets
private extension KiraSecondHandler {
	func _installEmbeddedAssets() async throws {
		guard let archive = Bundle.main.url(forResource: "KiraSecondAssets", withExtension: "zip") else {
			throw KiraSecondError.assetsMissing
		}

		let temporary = fileManager.temporaryDirectory
			.appendingPathComponent("FeatherKiraSecond_\(UUID().uuidString)", isDirectory: true)
		defer { try? fileManager.removeItem(at: temporary) }

		try fileManager.createDirectory(at: temporary, withIntermediateDirectories: true)
		try Zip.unzipFile(
			archive,
			destination: temporary,
			overwrite: true,
			password: nil,
			progress: nil
		)

		let frameworks = app.appendingPathComponent("Frameworks", isDirectory: true)
		try fileManager.createDirectory(at: frameworks, withIntermediateDirectories: true)

		let items = try fileManager.contentsOfDirectory(
			at: temporary,
			includingPropertiesForKeys: [.isDirectoryKey],
			options: [.skipsHiddenFiles]
		)

		for source in items {
			let destination = frameworks.appendingPathComponent(source.lastPathComponent)
			if fileManager.fileExists(atPath: destination.path) {
				try fileManager.removeItem(at: destination)
			}
			try fileManager.copyItem(at: source, to: destination)
		}

		try _applyEmbeddedPermissions(in: frameworks)
	}

	func _applyEmbeddedPermissions(in frameworks: URL) throws {
		let executableNames: Set<String> = [
			"iKiraPlus.dylib",
			"UIDisplayServices.dylib",
			"SystemEnvironment",
			"ProcessServices",
			"CoreLifecycle",
			"UIInfrastructure",
			"ProcessSupport"
		]

		guard let enumerator = fileManager.enumerator(
			at: frameworks,
			includingPropertiesForKeys: [.isRegularFileKey],
			options: [.skipsHiddenFiles]
		) else { return }

		for case let file as URL in enumerator {
			guard (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
			let mode = executableNames.contains(file.lastPathComponent) ? 0o755 : 0o644
			try? fileManager.setAttributes([.posixPermissions: mode], ofItemAtPath: file.path)
		}
	}
}

// MARK: - GuardChain
private extension KiraSecondHandler {
	func _chooseAnchor(mainExecutable: URL) throws -> URL? {
		guard let mainInfo = try? _machOInfo(at: mainExecutable) else {
			return nil
		}

		let frameworksRoot = app.appendingPathComponent("Frameworks", isDirectory: true).standardizedFileURL
		var seen = Set<String>()
		var candidates: [(url: URL, remainingSlack: Int)] = []

		for load in mainInfo.loads {
			guard let candidate = _resolve(load: load, from: mainExecutable) else { continue }
			let standardized = candidate.standardizedFileURL
			guard standardized.path.hasPrefix(frameworksRoot.path + "/") else { continue }
			guard fileManager.fileExists(atPath: standardized.path) else { continue }
			guard seen.insert(standardized.path).inserted else { continue }

			let frameworkName = standardized.deletingLastPathComponent().deletingPathExtension().lastPathComponent
			guard !guardFrameworkNames.contains(frameworkName) else { continue }

			guard let info = try? _machOInfo(at: standardized), info.fileType == 6 else { continue }
			let missing = requiredLoads.filter { !info.loads.contains($0) }
			let needed = missing.reduce(0) { $0 + _loadCommandSize(for: $1) }
			guard info.slack >= needed else { continue }

			candidates.append((standardized, info.slack - needed))
		}

		return candidates.max(by: { $0.remainingSlack < $1.remainingSlack })?.url
	}

	func _buildBridge(mainExecutable: URL) throws {
		let bridge = app
			.appendingPathComponent("Frameworks", isDirectory: true)
			.appendingPathComponent(bridgeRelativePath)

		guard fileManager.fileExists(atPath: bridge.path) else {
			throw KiraSecondError.bridgeMissing
		}

		let bridgeDependencies = requiredLoads.filter { $0 != bridgeSelfLoad }
		try _injectRequiredLoads(into: bridge, loads: bridgeDependencies)
		try _injectLoad(bootstrapLoad, into: mainExecutable)

		try _verify(executable: bridge, requires: bridgeDependencies)
		try _verify(executable: mainExecutable, requires: [bootstrapLoad], allowUnsupportedMachO: true)
	}

	func _injectRequiredLoads(into executable: URL, loads: [String]) throws {
		for load in loads {
			try _injectLoad(load, into: executable)
		}
	}

	func _injectLoad(_ load: String, into executable: URL) throws {
		if let info = try? _machOInfo(at: executable), info.loads.contains(load) {
			return
		}

		guard Zsign.injectDyLib(appExecutable: executable.path, with: load) else {
			throw KiraSecondError.injectionFailed(executable.lastPathComponent, load)
		}
	}

	func _verify(executable: URL, requires loads: [String], allowUnsupportedMachO: Bool = false) throws {
		do {
			let info = try _machOInfo(at: executable)
			for load in loads where !info.loads.contains(load) {
				throw KiraSecondError.verificationFailed(executable.lastPathComponent, load)
			}
		} catch KiraSecondError.unsupportedMachO where allowUnsupportedMachO {
			// Zsign handles formats beyond the lightweight parser used for verification.
			return
		}
	}

	func _resolve(load: String, from executable: URL) -> URL? {
		if load.hasPrefix("@rpath/") {
			return app
				.appendingPathComponent("Frameworks", isDirectory: true)
				.appendingPathComponent(String(load.dropFirst("@rpath/".count)))
		}
		if load.hasPrefix("@executable_path/") {
			return app.appendingPathComponent(String(load.dropFirst("@executable_path/".count)))
		}
		if load.hasPrefix("@loader_path/") {
			return executable.deletingLastPathComponent()
				.appendingPathComponent(String(load.dropFirst("@loader_path/".count)))
		}
		return nil
	}
}

// MARK: - Lightweight Mach-O reader
private extension KiraSecondHandler {
	struct MachOInfo {
		let fileType: UInt32
		let loads: [String]
		let commandEnd: Int
		let firstDataOffset: Int

		var slack: Int {
			guard firstDataOffset > 0 else { return 0 }
			return max(0, firstDataOffset - commandEnd)
		}
	}

	func _machOInfo(at url: URL) throws -> MachOInfo {
		let data = try Data(contentsOf: url, options: [.mappedIfSafe])
		guard data.count >= 32, _u32(data, 0) == 0xfeedfacf else {
			throw KiraSecondError.unsupportedMachO
		}

		let fileType = _u32(data, 12)
		let ncmds = Int(_u32(data, 16))
		let sizeofcmds = Int(_u32(data, 20))
		let commandEnd = 32 + sizeofcmds
		guard commandEnd <= data.count else { throw KiraSecondError.unsupportedMachO }

		var offset = 32
		var loads: [String] = []
		var firstDataOffset = Int.max

		for _ in 0..<ncmds {
			guard offset + 8 <= data.count else { throw KiraSecondError.unsupportedMachO }
			let rawCommand = _u32(data, offset)
			let command = rawCommand & 0x7fffffff
			let commandSize = Int(_u32(data, offset + 4))
			guard commandSize >= 8, offset + commandSize <= data.count else {
				throw KiraSecondError.unsupportedMachO
			}

			if [UInt32(0x0c), 0x18, 0x1f, 0x20, 0x23].contains(command), commandSize >= 24 {
				let nameOffset = Int(_u32(data, offset + 8))
				if nameOffset > 0, nameOffset < commandSize {
					loads.append(_cstring(data, from: offset + nameOffset, to: offset + commandSize))
				}
			}

			if command == 0x19, commandSize >= 72 {
				let sectionCount = Int(_u32(data, offset + 64))
				var sectionOffset = offset + 72
				for _ in 0..<sectionCount where sectionOffset + 80 <= offset + commandSize {
					let fileOffset = Int(_u32(data, sectionOffset + 48))
					if fileOffset > 0 { firstDataOffset = min(firstDataOffset, fileOffset) }
					sectionOffset += 80
				}
			}

			offset += commandSize
		}

		return MachOInfo(
			fileType: fileType,
			loads: loads,
			commandEnd: commandEnd,
			firstDataOffset: firstDataOffset == Int.max ? 0 : firstDataOffset
		)
	}

	func _loadCommandSize(for path: String) -> Int {
		let byteCount = path.lengthOfBytes(using: .utf8) + 1
		return (24 + byteCount + 7) & ~7
	}

	func _u32(_ data: Data, _ offset: Int) -> UInt32 {
		guard offset + 4 <= data.count else { return 0 }
		return data.withUnsafeBytes { raw in
			let p = raw.baseAddress!.advanced(by: offset).assumingMemoryBound(to: UInt8.self)
			return UInt32(p[0]) |
				(UInt32(p[1]) << 8) |
				(UInt32(p[2]) << 16) |
				(UInt32(p[3]) << 24)
		}
	}

	func _cstring(_ data: Data, from start: Int, to end: Int) -> String {
		guard start < end, start < data.count else { return "" }
		let upper = min(end, data.count)
		var bytes: [UInt8] = []
		for index in start..<upper {
			let byte = data[index]
			if byte == 0 { break }
			bytes.append(byte)
		}
		return String(bytes: bytes, encoding: .utf8) ?? ""
	}
}

enum KiraSecondError: Error, LocalizedError {
	case assetsMissing
	case mainExecutableNotFound
	case bridgeMissing
	case unsupportedMachO
	case injectionFailed(String, String)
	case verificationFailed(String, String)

	var errorDescription: String? {
		switch self {
		case .assetsMissing:
			"Kira Second assets are missing from Feather."
		case .mainExecutableNotFound:
			"Kira Second could not locate the app executable."
		case .bridgeMissing:
			"Kira Second could not create the SystemEnvironment bridge."
		case .unsupportedMachO:
			"Kira Second encountered an unsupported Mach-O format."
		case .injectionFailed(let executable, let load):
			"Kira Second failed to inject \(load) into \(executable)."
		case .verificationFailed(let executable, let load):
			"Kira Second verification failed for \(load) in \(executable)."
		}
	}
}
