import Foundation
import Logging
import NIO
import XCBBuildServiceProxy
import XCBProtocol

@_exported import XCBProtocol_13_0
typealias BazelXCBBuildServiceRequestPayload = XCBProtocol_13_0.RequestPayload
typealias BazelXCBBuildServiceResponsePayload = XCBProtocol_13_0.ResponsePayload

final class RequestHandler: HybridXCBBuildServiceRequestHandler {
    typealias Context = HybridXCBBuildServiceRequestHandlerContext<BazelXCBBuildServiceRequestPayload, BazelXCBBuildServiceResponsePayload>
    
    private typealias SessionHandle = String
    
    private var sessionAppPaths: [SessionHandle: String] = [:]
    private var sessionXcodeBuildVersionFutures: [SessionHandle: (Any, EventLoopFuture<String>)] = [:]
    private var sessionPIFCachePaths: [SessionHandle: String] = [:]
    private var sessionWorkplaceSignatures: [SessionHandle: String] = [:]
    private var sessionBazelTargetsFutures: [SessionHandle: (environment: [String: String], EventLoopFuture<[String: BazelBuild.Target]?>)] = [:]
    private var sessionBazelBuilds: [SessionHandle: BazelBuild] = [:]
    
    // We use negative numbers to ensure no duplication with XCBBuildService (though it seems that doesn't matter)
    private var lastBazelBuildNumber: Int64 = 0
    private var buildContext: BuildContext<BazelXCBBuildServiceResponsePayload>?
    
    func handleRequest(_ request: RPCRequest<BazelXCBBuildServiceRequestPayload>, context: Context) {
        // Unless `forwardRequest` is set to `false`, at the end we forward the request to XCBBuildService
        var shouldForwardRequest = true
        defer {
            if shouldForwardRequest {
                context.forwardRequest()
            }
        }
        
        func handleBazelTargets(
            session: String,
            handler: @escaping (
                _ environment: [String: String],
                _ targets: [String: BazelBuild.Target],
                _ xcodeBuildVersion: String
            ) -> Void
        ) {
            guard let (environment, bazelTargetsFuture) = sessionBazelTargetsFutures[session] else {
                logger.error("Bazel target mapping future not found for session “\(session)”")
                return
            }
            
            guard let (_, xcodeBuildVersionFuture) = sessionXcodeBuildVersionFutures[session] else {
                logger.error("Xcode Build Version future not found for session “\(session)”")
                return
            }
            
            let future = bazelTargetsFuture.and(xcodeBuildVersionFuture)
            
            // We are handling this ourselves
            shouldForwardRequest = false
            
            future.whenFailure { error in
                // If we have a failure it means we should build with bazel, but we can't
                // We need to report an error back
                context.sendErrorResponse(
                    "[\(session)] Failed to parse targets for BazelXCBBuildService: \(error)",
                    request: request
                )
                return
            }
            future.whenSuccess { bazelTargets, xcodeBuildVersion in
                // If we don't have any mappings we forward the request
                guard let bazelTargets = bazelTargets else {
                    context.forwardRequest()
                    return
                }
                
                handler(environment, bazelTargets, xcodeBuildVersion)
            }
        }
        
        switch request.payload {
        case let .createBuildRequest(message):
            shouldForwardRequest = false
            let buildNumber: Int64 = 123
            self.buildContext = BuildContext(
                sendResponse: context.sendResponse,
                session: message.sessionHandle,
                buildNumber: buildNumber,
                responseChannel: message.responseChannel
            )
            context.sendResponseMessage(BuildCreated(buildNumber: buildNumber), channel: request.channel)
            
            
//            let session = message.sessionHandle
//
//            // Reset in case we decide not to build
//            sessionBazelBuilds[session]?.cancel()
//            sessionBazelBuilds[session] = nil
//
//            handleBazelTargets(session: session) { baseEnvironment, bazelTargets, xcodeBuildVersion in
//                logger.trace("Parsed targets for BazelXCBBuildService: \(bazelTargets.map { $1.name })")
//
//                message.buildRequest.configuredTargets
//
//                self.lastBazelBuildNumber -= 1
//                let buildNumber = self.lastBazelBuildNumber
//
                
                
//                do {
//                    let build = try BazelBuild(
//                        buildContext: buildContext,
//                        environment: baseEnvironment,
//                        xcodeBuildVersion: xcodeBuildVersion,
//                        developerDir: baseEnvironment["DEVELOPER_DIR"]!,
//                        buildRequest: message.buildRequest,
//                        targets: []
//                    )
//
//                    self.sessionBazelBuilds[session] = build
//
//                } catch {
//                    context.sendErrorResponse(error, session: session, request: request)
//                }
//            }
            
        case .buildStartRequest(_):
            shouldForwardRequest = false
            context.sendResponseMessage(BoolResponse(true), channel: request.channel)
            buildContext?.buildStarted()
//            context.diagnostic(
//                "Some targets are set to build with Bazel, but \(Target.shouldBuildWithBazelBuildSetting) and/or \(Target.bazelLabelBuildSetting) is not set for the following targets: \(nonBazelTargets.map(\.name).joined(separator: ", ")). All, or none of, the targets need to be setup to build with Bazel.",
//                kind: .error,
//                appendToOutputStream: true
//            )
            buildContext?.buildEnded(cancelled: false)
//            buildContext?.sendErrorResponse(error, session: session, request: request)
        case .buildCancelRequest(_):
            shouldForwardRequest = false
        default:
            break
        }
    }
}

extension RequestHandler {
    private func decodeJSON<T>(
        _ type: T.Type,
        context: Context,
        filePath: String
    ) -> EventLoopFuture<T> where T: Decodable {
        return fileIO.openFile(path: filePath, eventLoop: context.eventLoop).flatMap { [fileIO] fileHandle, region in
            return fileIO.read(
                fileRegion: region,
                allocator: context.allocator,
                eventLoop: context.eventLoop
            ).flatMapThrowing { buffer in
                defer { try? fileHandle.close() }
                return try JSONDecoder().decode(T.self, from: Data(buffer.readableBytesView))
            }
        }
    }

    /// - Returns: `true` if we should build with Bazel. This future will never error.
    private func shouldBuildWithBazel(
        context: Context,
        workspacePIFFuture: EventLoopFuture<WorkspacePIF>
    ) -> EventLoopFuture<Bool> {
        return workspacePIFFuture.flatMap { [fileIO] pif in
            let path = "\(pif.path)/xcshareddata/BazelXCBBuildServiceSettings.plist"
            return fileIO.openFile(path: path, eventLoop: context.eventLoop)
                .map { fileHandle, _ in
                    // Close the file, we just wanted to ensure it exists for now
                    // Later we might read the contents
                    try? fileHandle.close()
                    logger.debug("“\(path)” found. Building with Bazel.")
                    return true
                }.recover { error in
                    logger.debug("“\(path)” could not be opened (\(error)). Not building with Bazel.")
                    return false
                }
        }
    }
    
    /// - Returns: parsed projects or an error, if we should build with Bazel, or `nil` if we shouldn't.
    private func generateSessionBazelTargets(
        context: Context,
        session: String
    ) -> EventLoopFuture<[String: BazelBuild.Target]?>? {
        guard let pifCachePath = sessionPIFCachePaths[session] else {
            logger.error("PIF cache path not found for session “\(session)”")
            return nil
        }
        
        guard let workspaceSignature = sessionWorkplaceSignatures[session] else {
            logger.error("Workspace signature not found for session “\(session)”")
            return nil
        }
        
        let path = "\(pifCachePath)/workspace/\(workspaceSignature)-json"
        let workspacePIFFuture = decodeJSON(
            WorkspacePIF.self,
            context: context,
            filePath: path
        )
        
        workspacePIFFuture.whenFailure { error in
            logger.error("Failed to decode workspace PIF “\(path)”: \(error)")
        }
        
        return shouldBuildWithBazel(
            context: context,
            workspacePIFFuture: workspacePIFFuture
        ).flatMap { shouldBuildWithBazel in
            guard shouldBuildWithBazel else { return context.eventLoop.makeSucceededFuture(nil) }
            
            return workspacePIFFuture.map { pif in
                pif.projects.map { self.processPIFProject(cachePath: pifCachePath, signature: $0, context: context) }
            }.flatMap { futures in
                EventLoopFuture.reduce(into: [:], futures, on: context.eventLoop) { targetMappings, projectTargets in
                    for case let projectTarget in projectTargets {
                        targetMappings[projectTarget.xcodeGUID] = projectTarget
                    }
                }
            }.map { .some($0) }
        }
    }
    
    private func processPIFProject(
        cachePath: String,
        signature: String,
        context: Context
    ) -> EventLoopFuture<[BazelBuild.Target]> {
        let path = "\(cachePath)/project/\(signature)-json"
        return decodeJSON(ProjectPIF.self, context: context, filePath: path).flatMap { pif in
            let project = BazelBuild.Project(
                name: pif.name,
                path: pif.path,
                projectDirectory: pif.projectDirectory,
                isPackage: pif.isPackage,
                buildConfigurations: pif.buildConfigurations.reduce(into: [:]) { $0[$1.name] = $1.buildSettings }
            )
            
            return EventLoopFuture.whenAllSucceed(
                pif.targets.map {
                    self.processPIFTarget(cachePath: cachePath, signature: $0, project: project, context: context)
                },
                on: context.eventLoop
            )
        }
    }
    
    private func processPIFTarget(
        cachePath: String,
        signature: String,
        project: BazelBuild.Project,
        context: Context
    ) -> EventLoopFuture<BazelBuild.Target> {
        let path = "\(cachePath)/target/\(signature)-json"
        return decodeJSON(TargetPIF.self, context: context, filePath: path).map { pif in
            return BazelBuild.Target(
                name: pif.name,
                xcodeGUID: pif.guid,
                project: project,
                productTypeIdentifier: pif.productTypeIdentifier,
                buildConfigurations: pif.buildConfigurations.reduce(into: [:]) { $0[$1.name] = $1.buildSettings }
            )
        }
    }
}
