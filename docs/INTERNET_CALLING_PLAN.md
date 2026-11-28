# FreeVoice Internet Calling — Implementation Plan

## Current baseline

The current iOS app discovers nearby devices with Apple's MultipeerConnectivity framework. `NearbyAudioService` advertises and browses the `freevoice` service, establishes an encrypted `MCSession`, and sends low-latency audio packets between connected peers. This is a nearby-device transport, not an Internet calling transport.

## Goal

Allow two FreeVoice users to place voice calls over Wi-Fi or mobile data, including when they are in different locations. Keep the existing nearby implementation intact until the Internet path is implemented and tested.

## Proposed first architecture

- **Call media:** WebRTC audio first. WebRTC provides real-time media transport, congestion handling, and support for NAT traversal.
- **Signaling:** A small authenticated backend exchanges call invitations, accept/reject events, and WebRTC offer/answer/ICE messages. Signaling does not carry the call audio.
- **Connectivity:** STUN for address discovery and TURN relay fallback for networks where direct peer-to-peer connectivity is not possible.
- **Identity:** Use stable app-issued user IDs; do not treat a device display name as a secure identity. Contact discovery and phone-number verification are separate later decisions.
- **Security:** Use WebRTC's encrypted media transport, authenticate signaling, and avoid logging call media or sensitive tokens.

## Delivery sequence

1. Confirm the Xcode project structure, supported iOS deployment target, build workflow, and dependency-management approach.
2. Define a transport-neutral call interface so the current nearby transport can remain available while a WebRTC transport is added.
3. Add a minimal signaling service and call invitation flow.
4. Add WebRTC audio calling and STUN/TURN configuration.
5. Test two devices on different networks, including mobile data and restrictive NATs.
6. Only after voice calls work reliably, add video, Android interoperability, voice assistant, and live translation.

## Important constraints

- Do not replace the current nearby implementation in-place.
- Do not commit credentials, API keys, TURN passwords, or private certificates. Use server-side secrets and short-lived credentials.
- Do not claim Internet calling works until two real devices have completed calls across different networks.
- The backend provider, hosting cost, authentication method, and TURN provider must be selected before production service implementation.

## Repository inspection findings

- The Xcode project currently targets iOS 17.0 and uses Swift 5 language mode.
- The project is a small hand-maintained `.pbxproj` with six Swift source files and no existing third-party framework entries.
- GitHub Actions builds the iOS app on `macos-latest` with `xcodebuild` and packages an unsigned IPA. Pull requests also trigger this build.
- The current CI workflow is a useful compile gate, but it does not run device-to-device call tests.

## WebRTC dependency foundation

- Added the WebRTC binary framework through Swift Package Manager, pinned to the exact `158.0.0` release from `stasel/WebRTC`.
- The package distributes an XCFramework and supports iOS 15+, which is compatible with this app's iOS 17 deployment target.
- Added `WebRTCModule` as a small initialization point that creates an `RTCPeerConnectionFactory`.
- The new module is not yet connected to the call UI and does not place calls. This is intentional: a working Internet call also needs authenticated signaling, remote user identity, and STUN/TURN configuration.
- The existing MultipeerConnectivity implementation remains unchanged.

## Next engineering task

Implement the WebRTC peer-connection layer: local audio track, offer/answer exchange, ICE candidate handling, connection-state reporting, and explicit cleanup. Keep signaling behind a separate interface so the backend can be selected without rewriting the media layer. Do not enable Internet calls in the UI until signaling and TURN configuration are available and real-device tests pass.


## WebRTC audio peer-connection layer

- Added `WebRTCPeerConnection`, a signaling-independent owner for one audio peer connection.
- It creates a local microphone audio track, supports offer and answer creation, applies remote session descriptions, accepts remote ICE candidates, emits local ICE candidates, reports ICE connection state, and closes the connection.
- ICE servers are injected by the caller. No public STUN/TURN credentials or production relay configuration are hard-coded.
- The class is not yet wired into `CallManager` or the user interface. The app still uses the nearby transport until signaling, permissions, ICE configuration, and device testing are complete.
- The next gate is a clean Xcode build and API compatibility check against the pinned WebRTC package. After that, implement authenticated signaling and connect the signaling events to this peer-connection layer.


## Backend-neutral signaling contract

- Added `CallSignalingClient` and Codable call-signal message types for invitations, accept/reject, SDP offer/answer, ICE candidates, and call termination.
- The contract uses stable app-level participant IDs and does not depend on MultipeerConnectivity identities.
- No signaling provider or backend SDK is included. In particular, Supabase has not been started or configured.
- A future provider implementation must authenticate each user and enforce sender, recipient, and call ownership on the server. Client-provided IDs alone are not authentication.
- The next step is to validate this contract with the WebRTC negotiation flow and then add a provider implementation only when the backend choice is approved.


## Backend-neutral WebRTC signaling coordinator

- Added `WebRTCCallCoordinator`, which connects the signaling contract to the WebRTC peer-connection layer without selecting or importing a backend SDK.
- The initiating caller sends an invitation; after acceptance, that caller creates and sends the SDP offer. The callee applies the offer and returns an SDP answer.
- Local ICE candidates are sent through the injected signaling client. Remote candidates that arrive before the remote SDP is applied are buffered and flushed afterward.
- Incoming messages are checked against the local participant ID, active call ID, and expected remote participant ID before they can affect the call.
- Call termination and negotiation failures close the peer connection and clear per-call ICE state.
- This coordinator is an integration layer, not a complete Internet calling feature: it is not connected to the current call UI or `CallManager`, and no concrete signaling provider exists yet. The signaling implementation must authenticate users and enforce authorization server-side; client-side ID checks are only defensive validation.
- No Supabase code, project, credentials, or configuration has been added. Real two-device Internet calling still requires an authenticated signaling provider, STUN/TURN configuration, UI integration, and cross-network device tests.


## CallManager integration gate

- The backend-neutral coordinator is intentionally kept separate from `CallManager` for now. The app currently has no authenticated Internet user identity and no concrete `CallSignalingClient` implementation to inject.
- Connecting it to the live call manager before those dependencies exist would create an unusable Internet-call path and risk confusing it with the working nearby flow.
- Once the signaling provider and stable signed-in user identity are available, inject the coordinator into `CallManager`, add microphone/AVAudioSession lifecycle handling, then expose Internet call controls. Keep the nearby transport as a separate supported path until cross-network device tests pass.
- The current coordinator build validates compilation only; it does not validate network signaling, media routing, microphone behavior, or real calls.
