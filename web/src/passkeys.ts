import { api, setCredential } from "./api";

// Passkeys belong to 4n.studio (see Server/Passkeys.swift): only pages there can use them.

function bytes(base64url: string): ArrayBuffer {
  const base64 = base64url.replace(/-/g, "+").replace(/_/g, "/").padEnd(Math.ceil(base64url.length / 4) * 4, "=");
  return Uint8Array.from(atob(base64), (c) => c.charCodeAt(0)).buffer;
}

function text(buffer: ArrayBuffer): string {
  let binary = "";
  for (const byte of new Uint8Array(buffer)) binary += String.fromCharCode(byte);
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

/** Passkeys only work on the site they belong to. */
export const canUsePasskeys = () => location.hostname === "4n.studio" && "PublicKeyCredential" in window;

/**
 * Signs in with a passkey: this device's, or (on one without it) your phone's, by scanning the
 * code the browser shows.
 */
export async function signIn() {
  const { challenge, site } = await api.beginSignIn();
  const credential = (await navigator.credentials.get({
    publicKey: { challenge: bytes(challenge), rpId: site, userVerification: "required", timeout: 120_000 },
  })) as PublicKeyCredential | null;
  if (!credential) return;
  const response = credential.response as AuthenticatorAssertionResponse;
  const { session } = await api.finishSignIn({
    id: credential.id,
    clientData: text(response.clientDataJSON),
    authenticatorData: text(response.authenticatorData),
    signature: text(response.signature),
  });
  setCredential(session);
}

/** A passkey for Seek, made here and kept by this device's passkey manager (iCloud Keychain…). */
export async function addPasskey(name: string) {
  const { challenge, userID, site } = await api.beginRegister();
  const existing = await api.passkeys();
  const credential = (await navigator.credentials.create({
    publicKey: {
      challenge: bytes(challenge),
      rp: { id: site, name: "Seek" },
      user: { id: bytes(userID), name: "Seek", displayName: "Seek" },
      pubKeyCredParams: [{ type: "public-key", alg: -7 }],
      authenticatorSelection: { residentKey: "required", userVerification: "required" },
      excludeCredentials: existing.map((p) => ({ type: "public-key" as const, id: bytes(p.id) })),
      attestation: "none",
      timeout: 120_000,
    },
  })) as PublicKeyCredential | null;
  if (!credential) return;
  const response = credential.response as AuthenticatorAttestationResponse;
  const publicKey = response.getPublicKey();
  if (!publicKey) throw new Error("This browser can't add passkeys for Seek.");
  const { session } = await api.finishRegister({
    id: credential.id,
    clientData: text(response.clientDataJSON),
    authenticatorData: text(response.getAuthenticatorData()),
    publicKey: text(publicKey),
    algorithm: response.getPublicKeyAlgorithm(),
    name,
  });
  setCredential(session);
}

/** "iPhone", "Mac"…: a name for a new passkey, from where it was made. */
export function deviceName(): string {
  const agent = navigator.userAgent;
  if (/iPhone/.test(agent)) return "iPhone";
  if (/iPad/.test(agent)) return "iPad";
  if (/Android/.test(agent)) return "Android";
  if (/Mac/.test(agent)) return "Mac";
  if (/Windows/.test(agent)) return "Windows";
  return "Passkey";
}
