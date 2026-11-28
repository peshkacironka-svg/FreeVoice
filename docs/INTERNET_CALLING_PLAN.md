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

## First engineering task

Inspect the Xcode project and CI workflow to establish the deployment target and whether Swift Package Manager dependencies can be added cleanly. Then design the transport interface before implementing network calling.
