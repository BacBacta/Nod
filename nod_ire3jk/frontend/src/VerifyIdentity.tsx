import { useEffect, useState } from "react";
import { createAppClient, viemConnector } from "@farcaster/auth-client";
import { isHex, zeroAddress, type Address, type Hex } from "viem";
import { useAccount, useBlock, useReadContract, useSignMessage } from "wagmi";
import { identityAttestorAbi } from "./abi/IdentityAttestor";
import { api, type Attestation, type Identity, type PlatformInfo } from "./attestationApi";
import type { Deployment } from "./deployments";
import { sameAddress, short } from "./format";
import { TxNotice } from "./TxNotice";
import { useTx } from "./useTx";

const NAMES: Record<string, string> = {
  x: "X", farcaster: "Farcaster", github: "GitHub", tiktok: "TikTok", reddit: "Reddit",
};

const RETURN_ERRORS: Record<string, string> = {
  denied: "Vous avez refusé l'autorisation sur la plateforme.",
  invalid_state: "Lien de retour invalide ou déjà utilisé. Recommencez.",
  provider_error: "La plateforme n'a pas pu confirmer votre compte. Recommencez.",
};

/** Session to resume after an OAuth round trip (the service redirects back here). */
export function readReturn(): { session: string; status: string } | undefined {
  const q = new URLSearchParams(window.location.search);
  const status = q.get("verify");
  if (!status) return undefined;
  window.history.replaceState(null, "", window.location.pathname);
  return { session: q.get("session") ?? "", status };
}

type Step =
  | { kind: "choose" }
  | { kind: "working"; label: string }
  | { kind: "farcaster"; url: string }
  | { kind: "verified"; sessionId: string; identity: Identity; wallet: Address }
  | { kind: "submitted"; attestation: Attestation; identity: Identity };

export function VerifyIdentity({ d, resume }: { d: Deployment; resume?: { session: string; status: string } }) {
  const { address } = useAccount();
  const { signMessageAsync } = useSignMessage();
  const tx = useTx();
  const [platforms, setPlatforms] = useState<PlatformInfo[] | undefined>();
  const [error, setError] = useState<string>();
  const [step, setStep] = useState<Step>({ kind: "choose" });

  useEffect(() => {
    api.platforms().then((p) => {
      // The service must sign for the contract this app talks to.
      if (!sameAddress(p.attestor, d.attestor) || p.chainId !== d.chainId) {
        setError("Le service d'attestation est configuré pour un autre contrat ou un autre réseau.");
      } else {
        setPlatforms(p.platforms);
      }
    }, (e: Error) => setError(e.message));
  }, [d.attestor, d.chainId]);

  // Back from an OAuth provider.
  useEffect(() => {
    if (!resume) return;
    if (resume.status !== "ok") {
      setError(RETURN_ERRORS[resume.status] ?? "La vérification a échoué. Recommencez.");
      return;
    }
    setStep({ kind: "working", label: "Récupération de la vérification…" });
    api.session(resume.session).then(
      (s) => s.identity
        ? setStep({ kind: "verified", sessionId: resume.session, identity: s.identity, wallet: s.wallet })
        : (setError("Le compte n'a pas été vérifié. Recommencez."), setStep({ kind: "choose" })),
      (e: Error) => { setError(e.message); setStep({ kind: "choose" }); },
    );
  }, [resume]);

  async function start(p: PlatformInfo) {
    if (!address) return;
    setError(undefined);
    try {
      setStep({ kind: "working", label: "Signature du message par votre wallet…" });
      const { sessionId, message, nonce } = await api.start(address);
      const signature = await signMessageAsync({ message });
      await api.proveWallet(sessionId, signature);

      if (p.method === "oauth") {
        setStep({ kind: "working", label: `Redirection vers ${NAMES[p.id] ?? p.id}…` });
        window.location.assign(api.oauthUrl(sessionId, p.id));
        return;
      }
      await farcaster(sessionId, nonce);
    } catch (e) {
      setError((e as Error).message.split("\n")[0]);
      setStep({ kind: "choose" });
    }
  }

  async function farcaster(sessionId: string, nonce: string) {
    const client = createAppClient({ relay: "https://relay.farcaster.xyz", ethereum: viemConnector() });
    const channel = await client.createChannel({
      siweUri: window.location.origin, domain: window.location.host, nonce,
    });
    if (channel.isError) throw new Error("Impossible de contacter le relais Farcaster.");
    setStep({ kind: "farcaster", url: channel.data.url });
    const res = await client.watchStatus({ channelToken: channel.data.channelToken, timeout: 300_000, interval: 1_500 });
    if (res.isError || !res.data.message || !res.data.signature) throw new Error("Connexion Farcaster annulée ou expirée.");
    const { identity } = await api.farcaster(sessionId, res.data.message, res.data.signature as Hex);
    setStep({ kind: "verified", sessionId, identity, wallet: address! });
  }

  async function attest(sessionId: string, identity: Identity) {
    setError(undefined);
    try {
      const a = await api.attestation(sessionId);
      if (!sameAddress(a.contract, d.attestor)) throw new Error("Attestation émise pour un autre contrat : refusée.");
      const ok = await tx.send(
        a.mode === "attest" ? "Enregistrer l'attestation" : "Demander le changement de wallet",
        { address: d.attestor, abi: identityAttestorAbi, functionName: a.functionName, args: a.args },
      );
      if (ok) setStep({ kind: "submitted", attestation: a, identity });
    } catch (e) {
      setError((e as Error).message);
    }
  }

  return (
    <section className="card">
      <h2>Vérifier mon identité</h2>
      <p className="muted">
        Reliez votre compte de créateur à votre wallet pour pouvoir accepter vos tokens et
        recevoir vos frais. Vous signez un message (sans frais), vous vous connectez à la
        plateforme, puis vous enregistrez l'attestation sur la chaîne.
      </p>
      {!address && <p className="muted">Connectez d'abord votre wallet.</p>}
      {error && <p className="notice err" role="alert">{error}</p>}

      {step.kind === "choose" && address && platforms && (
        platforms.length === 0 ? <p className="muted">Aucune plateforme n'est activée sur le service.</p> : (
          <div className="actions">
            {platforms.map((p) => (
              <button key={p.id} onClick={() => start(p)}>Continuer avec {NAMES[p.id] ?? p.id}</button>
            ))}
          </div>
        )
      )}

      {step.kind === "working" && <p className="notice" role="status">{step.label}</p>}

      {step.kind === "farcaster" && (
        <p className="notice" role="status">
          Approuvez la connexion dans votre application Farcaster :{" "}
          <a href={step.url} target="_blank" rel="noreferrer">ouvrir la demande</a>.
        </p>
      )}

      {step.kind === "verified" && (
        <>
          <IdentitySummary identity={step.identity} />
          {address && !sameAddress(address, step.wallet) && (
            <p className="notice err">
              Attention : l'attestation liera {short(step.wallet)}, pas le wallet connecté.
            </p>
          )}
          <div className="actions">
            <button disabled={tx.busy} onClick={() => attest(step.sessionId, step.identity)}>
              Enregistrer l'attestation
            </button>
          </div>
        </>
      )}

      {step.kind === "submitted" && <Result d={d} attestation={step.attestation} identity={step.identity} />}
      <TxNotice status={tx.status} />
      <PendingRotation d={d} initialId={step.kind === "submitted" && step.attestation.mode === "initiateRotation" ? step.attestation.creatorId : undefined} />
    </section>
  );
}

/** Finish a wallet change once its 7-day delay has passed (anyone may call completeRotation). */
function PendingRotation({ d, initialId }: { d: Deployment; initialId?: Hex }) {
  const tx = useTx();
  const [input, setInput] = useState<string>(initialId ?? "");
  useEffect(() => { if (initialId) setInput(initialId); }, [initialId]);
  const id = isHex(input) && input.length === 66 ? (input as Hex) : undefined;
  const { data: block } = useBlock({ watch: true });
  const { data: rec } = useReadContract({
    address: d.attestor, abi: identityAttestorAbi, functionName: "attestations",
    args: id ? [id] : undefined, query: { enabled: !!id },
  });
  const pending = rec?.[1];
  const activatesAt = rec ? BigInt(rec[2]) : undefined;
  const hasPending = !!pending && pending !== zeroAddress;
  const ready = hasPending && activatesAt !== undefined && block !== undefined && block.timestamp >= activatesAt;

  return (
    <div className="subsection">
      <h3>Finaliser un changement de wallet</h3>
      <label>
        creatorId
        <input value={input} onChange={(e) => setInput(e.target.value.trim())} placeholder="0x… (64 caractères hexadécimaux)" />
      </label>
      {id && rec && !hasPending && <p className="muted">Aucun changement de wallet en attente pour cette identité.</p>}
      {hasPending && (
        <p className="muted">
          {short(pending)} remplacera {short(rec?.[0])}
          {ready ? " : le délai est écoulé." : ` à partir du ${new Date(Number(activatesAt) * 1000).toLocaleString("fr-FR")}.`}
        </p>
      )}
      {hasPending && (
        <button
          disabled={!ready || tx.busy}
          onClick={() => tx.send("Finaliser le changement de wallet", {
            address: d.attestor, abi: identityAttestorAbi, functionName: "completeRotation", args: [id!],
          })}
        >
          Finaliser le changement de wallet
        </button>
      )}
      <TxNotice status={tx.status} />
    </div>
  );
}

function IdentitySummary({ identity }: { identity: Identity }) {
  return (
    <dl className="grid">
      <dt>Plateforme</dt><dd>{NAMES[identity.platform] ?? identity.platform}</dd>
      {identity.handle && (<><dt>Compte</dt><dd>{identity.handle}</dd></>)}
      <dt>Identifiant</dt><dd className="mono">{identity.externalId}</dd>
      <dt>creatorId</dt><dd className="mono">{identity.creatorId}</dd>
    </dl>
  );
}

function Result({ d, attestation, identity }: { d: Deployment; attestation: Attestation; identity: Identity }) {
  const { data: rec } = useReadContract({
    address: d.attestor, abi: identityAttestorAbi, functionName: "attestations", args: [attestation.creatorId],
  });
  const wallet = rec?.[0];
  const pending = rec?.[1];
  const activatesAt = rec?.[2];
  return (
    <>
      <IdentitySummary identity={identity} />
      {attestation.mode === "attest" ? (
        <p className="notice ok" role="status">
          Identité liée à {short(wallet)}. Utilisez ce creatorId pour enregistrer vos tokens ; vous
          pourrez accepter un token 7 jours après votre première vérification.
        </p>
      ) : (
        <p className="notice" role="status">
          Changement de wallet demandé : {short(pending && pending !== zeroAddress ? pending : undefined)} remplacera{" "}
          {short(wallet)} le{" "}
          {activatesAt ? new Date(Number(activatesAt) * 1000).toLocaleString("fr-FR") : "…"}. D'ici là,
          l'ancien wallet reste actif.
        </p>
      )}
    </>
  );
}
