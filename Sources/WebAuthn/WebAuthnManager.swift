//===----------------------------------------------------------------------===//
//
// This source file is part of the WebAuthn Swift open source project
//
// Copyright (c) 2022 the WebAuthn Swift project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of WebAuthn Swift project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import Foundation

/// Main entrypoint for WebAuthn operations.
///
/// Use this struct to perform registration and authentication ceremonies.
///
/// Registration: To generate registration options, call `beginRegistration()`. Pass the resulting
/// ``PublicKeyCredentialCreationOptions`` to the client.
/// When the client has received the response from the authenticator, pass the response to
/// `finishRegistration()`.
///
/// Authentication: To generate authentication options, call `beginAuthentication()`. Pass the resulting
/// ``PublicKeyCredentialRequestOptions`` to the client.
/// When the client has received the response from the authenticator, pass the response to
/// `finishAuthentication()`.
public struct WebAuthnManager {
    private let config: WebAuthnConfig

    private let challengeGenerator: ChallengeGenerator

    /// Create a new WebAuthnManager using the given configuration and challenge generator.
    ///
    /// - Parameters:
    ///   - config: The configuration to use for this manager.
    ///   - challengeGenerator: The challenge generator to use for this manager. Defaults to a live generator.
    public init(config: WebAuthnConfig, challengeGenerator: ChallengeGenerator = .live) {
        self.config = config
        self.challengeGenerator = challengeGenerator
    }

    /// Generate a new set of registration data to be sent to the client and authenticator.
    ///
    /// - Parameters:
    ///   - user: The user to register.
    ///   - attestation: The level of attestation to be provided by the authenticator.
    ///   - publicKeyCredentialParameters: A list of public key algorithms the Relying Party chooses to restrict
    ///     support to. Defaults to all supported algorithms.
    /// - Returns: Registration options ready for the browser.
    public func beginRegistration(
        user: WebAuthnUser,
        timeout: TimeInterval = 60000,
        attestation: AttestationConveyancePreference = .none,
        publicKeyCredentialParameters: [PublicKeyCredentialParameters] = PublicKeyCredentialParameters.supported
    ) throws -> PublicKeyCredentialCreationOptions {
        guard let base64ID = user.userID.data(using: .utf8)?.base64EncodedString() else {
            throw WebAuthnError.invalidUserID
        }

        let userEntity = PublicKeyCredentialUserEntity(name: user.name, id: base64ID, displayName: user.displayName)
        let relyingParty = PublicKeyCredentialRpEntity(name: config.relyingPartyDisplayName, id: config.relyingPartyID)

        let challenge = challengeGenerator.generate()

        return PublicKeyCredentialCreationOptions(
            challenge: challenge.base64EncodedString(),
            user: userEntity,
            rp: relyingParty,
            pubKeyCredParams: publicKeyCredentialParameters,
            timeout: timeout,
            attestation: attestation
        )
    }

    /// Take response from authenticator and client and verify credential against the user's credentials and
    /// session data.
    ///
    /// - Parameters:
    ///   - challenge: The challenge passed to the authenticator within the preceding registration options.
    ///   - credentialCreationData: The value returned from `navigator.credentials.create()`
    ///   - requireUserVerification: Whether or not to require that the authenticator verified the user.
    ///   - supportedPublicKeyAlgorithms: A list of public key algorithms the Relying Party chooses to restrict
    ///     support to. Defaults to all supported algorithms.
    ///   - pemRootCertificatesByFormat: A list of root certificates used for attestation verification.
    ///     If attestation verification is not required (default behavior) this parameter does nothing.
    ///   - confirmCredentialIDNotRegisteredYet: For a successful registration ceremony we need to verify that the
    ///     `credentialId`, generated by the authenticator, is not yet registered for any user. This is a good place to
    ///     handle that.
    /// - Returns:  A new `Credential` with information about the authenticator and registration
    public func finishRegistration(
        challenge: EncodedBase64,
        credentialCreationData: RegistrationCredential,
        requireUserVerification: Bool = false,
        supportedPublicKeyAlgorithms: [PublicKeyCredentialParameters] = PublicKeyCredentialParameters.supported,
        pemRootCertificatesByFormat: [AttestationFormat: [Data]] = [:],
        confirmCredentialIDNotRegisteredYet: (String) async throws -> Bool
    ) async throws -> Credential {
        let parsedData = try ParsedCredentialCreationResponse(from: credentialCreationData)
        let attestedCredentialData = try await parsedData.verify(
            storedChallenge: challenge.urlEncoded,
            verifyUser: requireUserVerification,
            relyingPartyID: config.relyingPartyID,
            relyingPartyOrigin: config.relyingPartyOrigin,
            supportedPublicKeyAlgorithms: supportedPublicKeyAlgorithms,
            pemRootCertificatesByFormat: pemRootCertificatesByFormat
        )

        // TODO: Step 18. -> Verify client extensions

        // Step 24.
        guard try await confirmCredentialIDNotRegisteredYet(parsedData.id) else {
            throw WebAuthnError.credentialIDAlreadyExists
        }

        // Step 25.
        return Credential(
            type: parsedData.type,
            id: parsedData.id,
            publicKey: attestedCredentialData.publicKey,
            signCount: parsedData.response.attestationObject.authenticatorData.counter,
            backupEligible: parsedData.response.attestationObject.authenticatorData.flags.isBackupEligible,
            isBackedUp: parsedData.response.attestationObject.authenticatorData.flags.isCurrentlyBackedUp,
            attestationObject: parsedData.response.attestationObject,
            attestationClientDataJSON: parsedData.response.clientData
        )
    }

    /// Generate options for retrieving a credential via navigator.credentials.get()
    ///
    /// - Parameters:
    ///   - challenge: Optionally generate a challenge on your own. Defaults to `nil` which will let the library
    ///     generate it.
    ///   - timeout: How long the browser should give the user to choose an authenticator. This value
    ///     is a *hint* and may be ignored by the browser. Defaults to 60 seconds.
    ///   - allowCredentials: A list of credentials registered to the user.
    ///   - userVerification: The Relying Party's preference for the authenticator's enforcement of the
    ///     "user verified" flag.
    /// - Returns: Authentication options ready for the browser.
    public func beginAuthentication(
        challenge: EncodedBase64? = nil,
        timeout: TimeInterval? = 60,
        allowCredentials: [PublicKeyCredentialDescriptor]? = nil,
        userVerification: UserVerificationRequirement = .preferred
    ) throws -> PublicKeyCredentialRequestOptions {
        let challenge = challenge ?? challengeGenerator.generate().base64EncodedString()
        var timeoutInMilliseconds: UInt32? = nil
        if let timeout {
            timeoutInMilliseconds = UInt32(timeout * 1000)
        }
        return PublicKeyCredentialRequestOptions(
            challenge: challenge,
            timeout: timeoutInMilliseconds,
            rpId: config.relyingPartyID,
            allowCredentials: allowCredentials,
            userVerification: userVerification
        )
    }

    /// Verify a response from navigator.credentials.get()
    ///
    /// - Parameters:
    ///   - credential: The value returned from `navigator.credentials.get()`.
    ///   - expectedChallenge: The challenge passed to the authenticator within the preceding authentication options.
    ///   - credentialPublicKey: The public key for the credential's ID as provided in a preceding authenticator
    ///     registration ceremony.
    ///   - credentialCurrentSignCount: The current known number of times the authenticator was used.
    ///   - requireUserVerification: Whether or not to require that the authenticator verified the user.
    /// - Returns: Information about the authenticator
    public func finishAuthentication(
        credential: AuthenticationCredential,
        // clientExtensionResults: ,
        expectedChallenge: URLEncodedBase64,
        credentialPublicKey: [UInt8],
        credentialCurrentSignCount: UInt32,
        requireUserVerification: Bool = false
    ) throws -> VerifiedAuthentication {
        guard credential.type == "public-key" else { throw WebAuthnError.invalidAssertionCredentialType }

        let parsedAssertion = try ParsedAuthenticatorAssertionResponse(from: credential.response)
        try parsedAssertion.verify(
            expectedChallenge: expectedChallenge,
            relyingPartyOrigin: config.relyingPartyOrigin,
            relyingPartyID: config.relyingPartyID,
            requireUserVerification: requireUserVerification,
            credentialPublicKey: credentialPublicKey,
            credentialCurrentSignCount: credentialCurrentSignCount
        )

        return VerifiedAuthentication(
            credentialID: credential.id,
            newSignCount: parsedAssertion.authenticatorData.counter,
            credentialDeviceType: parsedAssertion.authenticatorData.flags.deviceType,
            credentialBackedUp: parsedAssertion.authenticatorData.flags.isCurrentlyBackedUp
        )
    }
}
