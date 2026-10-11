import AuthenticationServices
import SwiftUI

/// System AutoFill entry point. Every request needs the vault unlocked (Touch ID or master password)
/// inside the extension; nothing is filled silently.
final class CredentialProviderViewController: ASCredentialProviderViewController {
    private let state = AutoFillState()

    override func loadView() {
        state.completePassword = { [weak self] user, password in
            self?.extensionContext.completeRequest(withSelectedCredential: ASPasswordCredential(user: user, password: password))
        }
        state.completeCode = { [weak self] code in
            self?.extensionContext.completeOneTimeCodeRequest(using: ASOneTimeCodeCredential(code: code))
        }
        state.completeAssertion = { [weak self] credential in
            self?.extensionContext.completeAssertionRequest(using: credential)
        }
        state.completeRegistration = { [weak self] credential in
            self?.extensionContext.completeRegistrationRequest(using: credential)
        }
        state.fail = { [weak self] code in
            self?.extensionContext.cancelRequest(withError: NSError(domain: ASExtensionErrorDomain, code: code.rawValue))
        }
        state.cancel = { [weak self] in
            self?.extensionContext.cancelRequest(withError: NSError(domain: ASExtensionErrorDomain,
                                                                    code: ASExtensionError.userCanceled.rawValue))
        }
        let host = NSHostingView(rootView: AutoFillView(state: state))
        host.wantsLayer = true
        host.layer?.isOpaque = false
        host.layer?.backgroundColor = NSColor.clear.cgColor
        view = host
        preferredContentSize = NSSize(width: 440, height: 500)
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        // The material has to sample through a clear window, the same way the palette and shortcuts panels do.
        view.window?.isOpaque = false
        view.window?.backgroundColor = .clear
        view.window?.titlebarAppearsTransparent = true
    }

    // Password list for the current site.
    override func prepareCredentialList(for serviceIdentifiers: [ASCredentialServiceIdentifier]) {
        state.begin(mode: .password, services: serviceIdentifiers, preselect: nil)
    }

    // A QuickType suggestion was picked: show unlock, then fill that exact item.
    override func prepareInterfaceToProvideCredential(for credentialRequest: any ASCredentialRequest) {
        if let request = credentialRequest as? ASPasskeyCredentialRequest,
           let identity = request.credentialIdentity as? ASPasskeyCredentialIdentity {
            state.begin(passkey: .init(rpId: identity.relyingPartyIdentifier, clientDataHash: request.clientDataHash,
                                       credentialIDs: [identity.credentialID]),
                        registering: false, preselect: identity.recordIdentifier)
            return
        }
        let mode: AutoFillState.Mode = credentialRequest.type == .oneTimeCode ? .oneTimeCode : .password
        state.begin(mode: mode, services: [credentialRequest.credentialIdentity.serviceIdentifier],
                    preselect: credentialRequest.credentialIdentity.recordIdentifier)
    }

    // We never fill without the user present.
    override func provideCredentialWithoutUserInteraction(for credentialRequest: any ASCredentialRequest) {
        extensionContext.cancelRequest(withError: NSError(domain: ASExtensionErrorDomain,
                                                          code: ASExtensionError.userInteractionRequired.rawValue))
    }

    // A site asked for a passkey and the user chose Triwarden.
    override func prepareCredentialList(for serviceIdentifiers: [ASCredentialServiceIdentifier],
                                        requestParameters: ASPasskeyCredentialRequestParameters) {
        state.begin(passkey: .init(rpId: requestParameters.relyingPartyIdentifier, clientDataHash: requestParameters.clientDataHash,
                                   credentialIDs: requestParameters.allowedCredentials),
                    registering: false)
    }

    // A site is creating a passkey and the user chose to save it in Triwarden.
    override func prepareInterface(forPasskeyRegistration registrationRequest: any ASCredentialRequest) {
        guard let request = registrationRequest as? ASPasskeyCredentialRequest,
              let identity = request.credentialIdentity as? ASPasskeyCredentialIdentity else {
            state.fail(.failed)
            return
        }
        state.begin(passkey: .init(rpId: identity.relyingPartyIdentifier, clientDataHash: request.clientDataHash,
                                   credentialIDs: request.excludedCredentials?.map(\.credentialID) ?? [],
                                   userName: identity.userName, userHandle: identity.userHandle,
                                   algorithms: request.supportedAlgorithms.map(\.rawValue)),
                    registering: true)
    }

    override func prepareOneTimeCodeCredentialList(for serviceIdentifiers: [ASCredentialServiceIdentifier]) {
        state.begin(mode: .oneTimeCode, services: serviceIdentifiers, preselect: nil)
    }
}
