import Foundation

public enum ApprovalProviderResponse: Sendable {
    case macApproved
    case iPhoneDecision(ApprovalDecision)
}

@MainActor
public protocol ApprovalProviding {
    func responses(to request: ApprovalRequest, onPromptStarted: @escaping () -> Void)
        -> AsyncThrowingStream<ApprovalProviderResponse, Error>
    func cancel(requestID: UUID)
}

/// The existing LocalAuthentication operation, including its native cancellation path.
@MainActor
public final class MacApprovalProvider: ApprovalProviding {
    private let prompt: @MainActor (@escaping () -> Void) async throws -> Void
    private let cancelPrompt: () -> Void
    private var task: Task<Void, Never>?
    private var continuation: AsyncThrowingStream<ApprovalProviderResponse, Error>.Continuation?

    public init(prompt: @escaping @MainActor (@escaping () -> Void) async throws -> Void,
        cancelPrompt: @escaping () -> Void) {
        self.prompt = prompt
        self.cancelPrompt = cancelPrompt
    }

    public func responses(to request: ApprovalRequest, onPromptStarted: @escaping () -> Void)
        -> AsyncThrowingStream<ApprovalProviderResponse, Error> {
        let (stream, continuation) = AsyncThrowingStream<ApprovalProviderResponse, Error>.makeStream()
        self.continuation = continuation
        task = Task { @MainActor in
            do {
                try Task.checkCancellation()
                try await prompt(onPromptStarted)
                guard !Task.isCancelled else { return }
                continuation.yield(.macApproved)
                continuation.finish()
            } catch {
                guard !Task.isCancelled else { return }
                continuation.finish(throwing: error)
            }
        }
        return stream
    }

    public func cancel(requestID: UUID) {
        task?.cancel()
        cancelPrompt()
        continuation?.finish()
    }
}

/// The phone channel publishes only the Mac's request and returns signed decisions.
/// CloudKit and the iPhone app will implement this in a later slice.
@MainActor
public protocol IPhoneApprovalChannel {
    func publish(_ request: ApprovalRequest) -> AsyncStream<ApprovalDecision>
    func cancel(requestID: UUID)
}

@MainActor
public final class IPhoneApprovalProvider: ApprovalProviding {
    private let channel: any IPhoneApprovalChannel
    private var task: Task<Void, Never>?
    private var continuation: AsyncThrowingStream<ApprovalProviderResponse, Error>.Continuation?

    private init(channel: any IPhoneApprovalChannel) { self.channel = channel }

    public static func paired(channel: any IPhoneApprovalChannel,
        devices: any PairedDevicePublicKeyProviding) async throws -> IPhoneApprovalProvider? {
        guard !(try await devices.pairedDevicePublicKeys()).isEmpty else { return nil }
        return IPhoneApprovalProvider(channel: channel)
    }

    public func responses(to request: ApprovalRequest, onPromptStarted: @escaping () -> Void)
        -> AsyncThrowingStream<ApprovalProviderResponse, Error> {
        let decisions = channel.publish(request)
        onPromptStarted()
        let (stream, continuation) = AsyncThrowingStream<ApprovalProviderResponse, Error>.makeStream()
        self.continuation = continuation
        task = Task { @MainActor in
            for await decision in decisions {
                guard !Task.isCancelled else { return }
                continuation.yield(.iPhoneDecision(decision))
            }
            continuation.finish()
        }
        return stream
    }

    public func cancel(requestID: UUID) {
        task?.cancel()
        channel.cancel(requestID: requestID)
        continuation?.finish()
    }
}
