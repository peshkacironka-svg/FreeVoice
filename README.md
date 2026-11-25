# FreeVoice

FreeVoice is an iOS voice-calling app under active development.

## Current implementation

- SwiftUI app targeting iOS 17.
- Firebase Email/Password Authentication and Firestore user-profile synchronization.
- Firebase App Check startup configuration: debug provider for development and App Attest for release.
- Restrictive Firestore rules: users read only their own profile; call documents and ICE candidates are readable only by call participants; clients cannot directly change call state.
- Cloud Functions for creating, accepting/rejecting, ending, expiring, and rate-limiting calls.
- App-Check-protected Cloud Functions for exchanging WebRTC SDP offers/answers and bounded ICE candidates.
- Scheduled cleanup for unanswered invitations and a composite Firestore index for the expiry query.
- WebRTC audio-only peer connection, Firebase signaling client, and foreground Internet-call UI with shareable user UID, outgoing/incoming calls, mute, and hang-up.
- Existing MultipeerConnectivity nearby-call prototype remains available.
- GitHub Actions workflows build the iOS Simulator target and compile the Cloud Functions TypeScript.

## Important status

The foreground Internet-call flow is now wired in code, but it has **not yet been end-to-end tested between two real iPhones against a deployed Firebase project**. The WebRTC service currently uses a public STUN server only. STUN alone does not guarantee connectivity through every mobile carrier, NAT, or firewall; production needs an authenticated TURN relay.

The app is not production-ready. Do not use it for emergency calls or sensitive communications.

## Next engineering milestones

1. Pass the latest iOS Simulator build and fix any compile errors.
2. Deploy Firebase and test real two-device calls on Wi-Fi and mobile networks.
3. Configure authenticated TURN credentials and test restrictive NAT/firewall scenarios.
4. Add PushKit/CallKit and APNs/FCM for incoming calls when the app is backgrounded or terminated.
5. Design and audit identity-bound end-to-end encryption key verification. WebRTC DTLS-SRTP encrypts the media transport, but by itself does not provide a user-verifiable identity/key verification process.
6. Add email verification, password reset, abuse controls, privacy review, and production security testing.

## Firebase project setup

The repository is configured for Firebase project `freevoice-dd402`. Email/Password sign-in is already enabled in Firebase Authentication.

Before deploying:

1. Create the Cloud Firestore database in the `europe-west3` (Frankfurt) region. The call Cloud Functions are configured in the same European region to reduce round-trip latency for users in Greece and nearby countries. Choose production mode; the repository's rules are intended to be deployed before client access.
2. Register the iOS app in Firebase App Check. On a development build, copy the debug token printed in the Xcode device/simulator log into Firebase Console. For production, enable App Attest for the registered iOS app.
3. Deploy Firestore rules, indexes, and Cloud Functions:
   ```sh
   npm --prefix functions install
   npm --prefix functions run build
   npx firebase-tools deploy --only firestore:rules,firestore:indexes,functions --project freevoice-dd402
   ```
4. Cloud Functions and scheduled jobs may require the Firebase/Google Cloud Blaze billing plan. Review expected costs and configure budget alerts before enabling production traffic.
5. Keep service-account keys and private TURN credentials out of Git. Use Secret Manager / Firebase Functions secrets for server-side credentials.

Account email verification and password-reset UI still need to be added.

## Building on Windows

The source can be edited on Windows. A native iOS app build, signing, and device installation require Xcode on macOS. The repository's GitHub Actions macOS runner performs an unsigned iOS Simulator build; it does not produce a signed App Store or installable device build.
