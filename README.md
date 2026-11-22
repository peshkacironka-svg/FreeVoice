# FreeVoice

FreeVoice is an iOS voice-calling app under active development.

## Current implementation

- SwiftUI app targeting iOS 17.
- Firebase Email/Password Authentication.
- Firestore user profile synchronization.
- Firestore security rules: users can access their own profile; call documents are readable only by participants; clients cannot mutate call state.
- Callable Cloud Functions for creating, accepting/rejecting, ending, expiring, and rate-limiting calls.
- Authenticated Cloud Functions for exchanging WebRTC SDP offers/answers and bounded ICE candidate signaling.
- App Check enforcement on callable call endpoints, with the iOS debug provider and production App Attest provider wired into app startup.
- Scheduled cleanup that marks unanswered invitations as expired.
- Firestore composite index for the scheduled expiry query.
- WebRTC audio-only peer connection connected to Firebase SDP/ICE signaling and a foreground outgoing/incoming call screen; calls are not yet end-to-end tested on deployed infrastructure.
- GitHub Actions builds the iOS Simulator target and compiles the Cloud Functions TypeScript.

## Important status

**Internet voice calling is not implemented yet.** The current audio path uses MultipeerConnectivity and works only with nearby Apple devices. Firebase currently handles identity, profiles, and call signaling; it does not transport audio.

The next major engineering milestones are:
1. Integrate WebRTC audio and ICE negotiation.
2. Configure authenticated TURN relay for restrictive NAT/firewall networks.
3. Connect signaling to the call documents/functions and implement reconnect/timeout handling.
4. Add PushKit/CallKit and APNs/FCM for incoming calls while the app is backgrounded or terminated.
5. Design and audit identity-bound end-to-end encryption key verification. DTLS-SRTP protects WebRTC transport but by itself is not a complete user-verifiable E2EE design.

## Firebase project setup

The repository is configured for Firebase project `freevoice-dd402`.

Before deploying:
1. Create a Cloud Firestore database in Firebase Console.
2. Register the iOS app in Firebase App Check. On a debug build, copy the debug token from the Xcode device/simulator log into Firebase Console; for production, enable App Attest for the registered iOS app.
3. Deploy Firestore rules, indexes, and Cloud Functions:
   ```sh
   npm --prefix functions install
   npm --prefix functions run build
   npx firebase-tools deploy --only firestore:rules,firestore:indexes,functions --project freevoice-dd402
   ```
4. Cloud Functions and scheduled jobs may require the Firebase/Google Cloud Blaze billing plan. Review expected costs and configure budget alerts before enabling production traffic.
5. Keep service-account keys and private TURN credentials out of Git. Use Secret Manager / Firebase Functions secrets for server-side credentials.

Email/Password sign-in is enabled in Firebase Authentication. Account email verification and password-reset UI still need to be added.

## Building on Windows

The source can be edited on Windows. A native iOS app build, signing, and device installation require Xcode on macOS. The repository's GitHub Actions macOS runner performs an unsigned iOS Simulator build; it does not produce a signed App Store or installable device build.

## Development status

This project is not production-ready. Do not use it for emergency calls or sensitive communications until WebRTC, TURN, push/call lifecycle, abuse prevention, privacy review, and security testing are complete.
