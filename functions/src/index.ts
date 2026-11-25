import { initializeApp } from "firebase-admin/app";
import { FieldValue, Timestamp, getFirestore } from "firebase-admin/firestore";
import { HttpsError, onCall } from "firebase-functions/v2/https";
import { onSchedule } from "firebase-functions/v2/scheduler";

initializeApp();
const db = getFirestore();

type CallStatus = "ringing" | "accepted" | "rejected" | "ended" | "expired";

function requireUid(request: { auth?: { uid: string } | null }): string {
  const uid = request.auth?.uid;
  if (!uid) {
    throw new HttpsError("unauthenticated", "You must be signed in.");
  }
  return uid;
}

function requireAppCheck(request: { app?: unknown }): void {
  if (!request.app) {
    throw new HttpsError("failed-precondition", "App Check verification is required.");
  }
}

export const createCall = onCall(
  { region: "europe-west3", enforceAppCheck: true, maxInstances: 20 },
  async (request) => {
    const callerUid = requireUid(request);
    requireAppCheck(request);
    const calleeUid = request.data?.calleeUid;

    if (typeof calleeUid !== "string" || calleeUid.length < 1 || calleeUid.length > 128) {
      throw new HttpsError("invalid-argument", "A valid calleeUid is required.");
    }
    if (calleeUid === callerUid) {
      throw new HttpsError("invalid-argument", "You cannot call yourself.");
    }

    const callRef = db.collection("calls").doc();
    const rateLimitRef = db.collection("callRateLimits").doc(callerUid);
    const expiresAt = Timestamp.fromMillis(Date.now() + 60_000);

    await db.runTransaction(async (transaction) => {
      const [callee, rateLimit] = await Promise.all([
        transaction.get(db.collection("users").doc(calleeUid)),
        transaction.get(rateLimitRef)
      ]);
      if (!callee.exists) {
        throw new HttpsError("not-found", "The recipient account was not found.");
      }

      const lastCallAt = rateLimit.data()?.lastCallAt;
      if (lastCallAt instanceof Timestamp && Date.now() - lastCallAt.toMillis() < 5_000) {
        throw new HttpsError("resource-exhausted", "Please wait before starting another call.");
      }

      transaction.create(callRef, {
        callId: callRef.id,
        callerUid,
        calleeUid,
        participants: [callerUid, calleeUid],
        status: "ringing" satisfies CallStatus,
        createdAt: FieldValue.serverTimestamp(),
        updatedAt: FieldValue.serverTimestamp(),
        expiresAt
      });
      transaction.set(rateLimitRef, {
        lastCallAt: FieldValue.serverTimestamp(),
        updatedAt: FieldValue.serverTimestamp()
      });
    });

    return { callId: callRef.id, status: "ringing", expiresAt: expiresAt.toMillis() };
  }
);

export const respondToCall = onCall(
  { region: "europe-west3", enforceAppCheck: true, maxInstances: 20 },
  async (request) => {
    const uid = requireUid(request);
    requireAppCheck(request);
    const { callId, response } = request.data ?? {};

    if (typeof callId !== "string" || callId.length < 1 || callId.length > 128 ||
        !["accepted", "rejected"].includes(response)) {
      throw new HttpsError("invalid-argument", "A valid callId and response are required.");
    }

    const ref = db.collection("calls").doc(callId);
    await db.runTransaction(async (transaction) => {
      const snapshot = await transaction.get(ref);
      if (!snapshot.exists) throw new HttpsError("not-found", "Call not found.");
      const call = snapshot.data()!;
      if (call.calleeUid !== uid) throw new HttpsError("permission-denied", "Only the recipient can respond.");
      if (call.status !== "ringing") throw new HttpsError("failed-precondition", "Call is no longer ringing.");
      if (call.expiresAt instanceof Timestamp && call.expiresAt.toMillis() < Date.now()) {
        throw new HttpsError("deadline-exceeded", "The call invitation has expired.");
      }
      transaction.update(ref, {
        status: response,
        updatedAt: FieldValue.serverTimestamp(),
        respondedAt: FieldValue.serverTimestamp()
      });
    });
    return { callId, status: response };
  }
);

export const endCall = onCall(
  { region: "europe-west3", enforceAppCheck: true, maxInstances: 20 },
  async (request) => {
    const uid = requireUid(request);
    requireAppCheck(request);
    const callId = request.data?.callId;
    if (typeof callId !== "string" || callId.length < 1 || callId.length > 128) {
      throw new HttpsError("invalid-argument", "A valid callId is required.");
    }

    const ref = db.collection("calls").doc(callId);
    await db.runTransaction(async (transaction) => {
      const snapshot = await transaction.get(ref);
      if (!snapshot.exists) throw new HttpsError("not-found", "Call not found.");
      const call = snapshot.data()!;
      if (!Array.isArray(call.participants) || !call.participants.includes(uid)) {
        throw new HttpsError("permission-denied", "You are not a participant in this call.");
      }
      if (call.status === "ended" || call.status === "rejected") return;
      transaction.update(ref, {
        status: "ended",
        updatedAt: FieldValue.serverTimestamp(),
        endedAt: FieldValue.serverTimestamp()
      });
    });
    return { callId, status: "ended" };
  }
);


// Close invitations that were never answered. The bounded batch avoids exceeding
// Firestore's 500-write transaction/batch limit.
export const expireStaleCalls = onSchedule(
  { schedule: "every 1 minutes", timeZone: "Etc/UTC", region: "europe-west3", maxInstances: 1 },
  async () => {
    const now = Timestamp.now();
    const staleCalls = await db.collection("calls")
      .where("status", "==", "ringing")
      .where("expiresAt", "<=", now)
      .orderBy("expiresAt", "asc")
      .limit(450)
      .get();

    if (staleCalls.empty) return;

    const batch = db.batch();
    for (const document of staleCalls.docs) {
      batch.update(document.ref, {
        status: "expired" satisfies CallStatus,
        updatedAt: FieldValue.serverTimestamp(),
        expiredAt: FieldValue.serverTimestamp()
      });
    }
    await batch.commit();
  }
);


// Exchange the SDP offer/answer only through the trusted callable backend.
export const setCallDescription = onCall(
  { region: "europe-west3", enforceAppCheck: true, maxInstances: 20 },
  async (request) => {
    const uid = requireUid(request);
    requireAppCheck(request);
    const { callId, type, sdp } = request.data ?? {};

    if (
      typeof callId !== "string" || callId.length < 1 || callId.length > 128 ||
      (type !== "offer" && type !== "answer") ||
      typeof sdp !== "string" || sdp.length < 1 || sdp.length > 100_000
    ) {
      throw new HttpsError("invalid-argument", "A valid callId, SDP type, and SDP are required.");
    }

    const ref = db.collection("calls").doc(callId);
    await db.runTransaction(async (transaction) => {
      const snapshot = await transaction.get(ref);
      if (!snapshot.exists) throw new HttpsError("not-found", "Call not found.");
      const call = snapshot.data()!;
      if (!Array.isArray(call.participants) || !call.participants.includes(uid)) {
        throw new HttpsError("permission-denied", "You are not a participant in this call.");
      }

      if (type === "offer") {
        // The callee may accept before the caller's SDP write reaches Firestore.
        // Allow the caller to submit the single offer while ringing or just accepted.
        if (
          call.callerUid !== uid ||
          (call.status !== "ringing" && call.status !== "accepted") ||
          (call.status === "ringing" &&
            call.expiresAt instanceof Timestamp &&
            call.expiresAt.toMillis() <= Date.now())
        ) {
          throw new HttpsError("failed-precondition", "Only the caller can submit an offer for an active call.");
        }
        if (typeof call.offerSdp === "string") {
          throw new HttpsError("already-exists", "An offer has already been submitted.");
        }
        transaction.update(ref, {
          offerSdp: sdp,
          updatedAt: FieldValue.serverTimestamp()
        });
      } else {
        if (call.calleeUid !== uid || call.status !== "accepted") {
          throw new HttpsError("failed-precondition", "Only the accepted recipient can submit an answer.");
        }
        if (typeof call.answerSdp === "string") {
          throw new HttpsError("already-exists", "An answer has already been submitted.");
        }
        transaction.update(ref, {
          answerSdp: sdp,
          updatedAt: FieldValue.serverTimestamp()
        });
      }
    });

    return { callId, type, saved: true };
  }
);

// ICE candidates are written to a participant-readable subcollection. A per-call
// cap bounds signaling storage and prevents unbounded candidate spam.
export const addCallIceCandidate = onCall(
  { region: "europe-west3", enforceAppCheck: true, maxInstances: 20 },
  async (request) => {
    const uid = requireUid(request);
    requireAppCheck(request);
    const { callId, sdp, sdpMid, sdpMLineIndex } = request.data ?? {};

    if (
      typeof callId !== "string" || callId.length < 1 || callId.length > 128 ||
      typeof sdp !== "string" || sdp.length < 1 || sdp.length > 4_096 ||
      (sdpMid !== null && sdpMid !== undefined &&
        (typeof sdpMid !== "string" || sdpMid.length > 128)) ||
      !Number.isInteger(sdpMLineIndex) || sdpMLineIndex < 0 || sdpMLineIndex > 255
    ) {
      throw new HttpsError("invalid-argument", "Invalid ICE candidate payload.");
    }

    const callRef = db.collection("calls").doc(callId);
    const candidateRef = callRef.collection("iceCandidates").doc();
    await db.runTransaction(async (transaction) => {
      const snapshot = await transaction.get(callRef);
      if (!snapshot.exists) throw new HttpsError("not-found", "Call not found.");
      const call = snapshot.data()!;
      if (!Array.isArray(call.participants) || !call.participants.includes(uid)) {
        throw new HttpsError("permission-denied", "You are not a participant in this call.");
      }
      if (call.status !== "ringing" && call.status !== "accepted") {
        throw new HttpsError("failed-precondition", "This call is no longer active.");
      }
      if (
        call.status === "ringing" &&
        call.expiresAt instanceof Timestamp &&
        call.expiresAt.toMillis() <= Date.now()
      ) {
        throw new HttpsError("deadline-exceeded", "The call invitation has expired.");
      }
      const count = typeof call.iceCandidateCount === "number" ? call.iceCandidateCount : 0;
      if (count >= 128) {
        throw new HttpsError("resource-exhausted", "The ICE candidate limit for this call has been reached.");
      }

      transaction.create(candidateRef, {
        fromUid: uid,
        sdp,
        sdpMid: sdpMid ?? null,
        sdpMLineIndex,
        createdAt: FieldValue.serverTimestamp()
      });
      transaction.update(callRef, {
        iceCandidateCount: count + 1,
        updatedAt: FieldValue.serverTimestamp()
      });
    });

    return { callId, candidateId: candidateRef.id, saved: true };
  }
);
