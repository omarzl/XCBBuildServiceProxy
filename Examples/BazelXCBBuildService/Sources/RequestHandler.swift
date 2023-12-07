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
    private var buildContext: BuildContext<BazelXCBBuildServiceResponsePayload>?
    
    private var sessionAppPaths: [SessionHandle: String] = [:]
    private var sessionXcodeBuildVersionFutures: [SessionHandle: (Any, EventLoopFuture<String>)] = [:]
    private var sessionPIFCachePaths: [SessionHandle: String] = [:]
    private var sessionWorkplaceSignatures: [SessionHandle: String] = [:]
    private var sessionBazelTargetsFutures: [SessionHandle: (environment: [String: String], EventLoopFuture<[String: BazelBuild.Target]?>)] = [:]
    private var sessionBazelBuilds: [SessionHandle: BazelBuild] = [:]
    private var targets = [String: BazelBuild.Target]()
    
    func handleRequest(_ request: RPCRequest<BazelXCBBuildServiceRequestPayload>, context: Context) {
        context.forwardRequest()
    }
}
