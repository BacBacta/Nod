# Nod attestation service

Links a creator's platform account to a wallet. The service checks two proofs, then
signs an EIP-712 attestation with the `ATTESTER_ROLE` key. The user submits it to
`IdentityAttestor` themselves, so the service never needs gas.

Platforms: **X, Farcaster, GitHub, TikTok, Reddit**.

## Flow

```
frontend                          service                                 chain
   | POST /v1/sessions {wallet}      |                                       |
   |-------------------------------->| challenge (nonce, expiry)            |
   | wallet signs the challenge      |                                       |
   | POST /sessions/:id/wallet-signature ------------------------> verifyMessage (EOA, ERC-1271/6492)
   |                                 |                                       |
   | OAuth:     GET /sessions/:id/oauth/:platform -> provider consent        |
   |            provider -> GET /v1/oauth/:platform/callback -> frontend ?verify=ok&session=:id
   | Farcaster: POST /sessions/:id/farcaster {SIWF message, signature}       |
   |                                 |                                       |
   | POST /sessions/:id/attestation  |  reads walletOf/platformOf/revoked -->|
   |<--------------------------------| {functionName: attest | initiateRotation, args}
   | user sends the tx ------------------------------------------------------>| IdentityAttestor
```

- `creatorId = keccak256(abi.encode(keccak256(platform), externalId))`, the same as
  `IdentityAttestor.creatorIdOf`. `externalId` is the platform's immutable account id,
  never the handle.
- If the identity already has a different wallet, the service issues an
  `initiateRotation` signature instead of `attest`: the new wallet becomes active only
  after the contract's 7-day delay. The contract rejects `attest` for a different
  wallet, so a hijacked social account cannot redirect fees instantly.
- Sessions last 15 minutes and are single use. Attestation signatures expire after 30
  minutes and carry a random nonce, which the contract marks as used.

## Platforms

| Platform | Proof | Account id used | Setup |
|---|---|---|---|
| X | OAuth 2.0 + PKCE, scopes `users.read tweet.read` | numeric user id (`/2/users/me`) | Developer app with OAuth 2.0 as a confidential client. Check that your API tier allows `/2/users/me`. |
| GitHub | OAuth web flow, no scope | numeric user id (`/user`) | OAuth App. |
| TikTok | Login Kit v2, scope `user.info.basic` | `open_id` | Login Kit app, reviewed by TikTok. `open_id` is specific to your app: keep the same client key forever, or every creator's id changes. |
| Reddit | OAuth2, scope `identity`, `duration=temporary` | account id (`/api/v1/me`) | "web app" type. Reddit requires a descriptive User-Agent, which the service sends. |
| Farcaster | Sign In With Farcaster (SIWF) | FID | No app registration. The frontend obtains the signed message (e.g. `@farcaster/auth-kit`) using the session `nonce` and the frontend domain. The service checks it against the FID's keys on Optimism. |

Register this redirect URI with each OAuth provider:
`<PUBLIC_URL>/v1/oauth/<platform>/callback`, for example `https://attest.example.com/v1/oauth/github/callback`.

## Run

```bash
cp .env.example .env   # fill it in
bun install
bun run start          # or: bun run dev
```

## Tests

```bash
bun run test                                        # flow + providers (mocked HTTP)
NOD_ANVIL_RPC=http://127.0.0.1:8545 bun run test    # plus the real IdentityAttestor on anvil
```

The on-chain test deploys `IdentityAttestor` from `../contracts/out` (run `forge build`
first), submits a service-issued attestation, then a rotation, and checks the contract
state.

## Before production

- **Attester key:** move it out of the environment into a KMS/HSM or a Circle
  developer-controlled wallet. Both can sign EIP-712; implement `AttestationSigner`.
- **Sessions:** the store is in memory. Use Redis or similar when running more than one
  instance.
- **Rate limiting and HTTPS** at the reverse proxy.
- **Revocation:** the contract has no way for the current wallet to cancel a pending
  rotation. Only the attester can `revoke`. The attester needs a monitoring and response
  process for `WalletRotationInitiated` events.
- **Provider tests** use mocked HTTP. Test each platform against its real API with real
  app credentials before launch.
