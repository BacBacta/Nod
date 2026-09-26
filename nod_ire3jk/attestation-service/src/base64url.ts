/** URL-safe base64 without padding (session ids, OAuth state, PKCE). */
export function base64urlnopad(bytes: Uint8Array): string {
  return Buffer.from(bytes).toString("base64url");
}
