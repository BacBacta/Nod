import { useState } from "react";
import { encodeAbiParameters, isAddress, isHex, keccak256, stringToBytes, type Address, type Hex } from "viem";
import { useAccount, useReadContract } from "wagmi";
import { registryAbi } from "./abi/Registry";
import { feeVaultFactoryAbi } from "./abi/FeeVaultFactory";
import type { Deployment } from "./deployments";
import { TxNotice } from "./TxNotice";
import { useTx } from "./useTx";

type Row = { recipient: string; percent: string };

const PLATFORMS = [
  ["x", "X"], ["farcaster", "Farcaster (FID)"], ["github", "GitHub"],
  ["tiktok", "TikTok (open_id)"], ["reddit", "Reddit"],
] as const;

/** Same derivation as IdentityAttestor.creatorIdOf and the attestation service. */
function creatorIdOf(platform: string, externalId: string): Hex {
  return keccak256(encodeAbiParameters(
    [{ type: "bytes32" }, { type: "string" }],
    [keccak256(stringToBytes(platform)), externalId],
  ));
}

/** A 32-byte hex id is used as is; any other text is hashed (keccak256). */
function toBytes32(v: string): Hex {
  return isHex(v) && v.length === 66 ? v : keccak256(stringToBytes(v));
}

export function RegisterToken({ d, onRegistered }: { d: Deployment; onRegistered: (t: Address) => void }) {
  const { address: me } = useAccount();
  const tx = useTx();
  const [token, setToken] = useState("");
  const [adapter, setAdapter] = useState<string>(d.adapter ?? "");
  const [platform, setPlatform] = useState<string>("x");
  const [externalId, setExternalId] = useState("");
  const [fallback, setFallback] = useState<string>(d.fallback ?? "");
  const [launchpadId, setLaunchpadId] = useState("");
  const [rows, setRows] = useState<Row[]>([{ recipient: "", percent: "100" }]);

  const tokenOk = isAddress(token);
  const { data: predicted } = useReadContract({
    address: d.factory, abi: feeVaultFactoryAbi, functionName: "predictVaultAddress",
    args: me && tokenOk ? [me, token] : undefined, query: { enabled: !!me && tokenOk },
  });

  const bpsTotal = rows.reduce((s, r) => s + Math.round(Number(r.percent) * 100 || 0), 0);
  const problems = [
    !me && "Connectez un wallet.",
    !tokenOk && "Adresse du token invalide.",
    !isAddress(adapter) && "Adresse de l'adaptateur invalide.",
    !externalId && "Identifiant du compte créateur manquant.",
    !isAddress(fallback) && "Adresse de repli invalide.",
    rows.some((r) => !isAddress(r.recipient)) && "Adresse de bénéficiaire invalide.",
    bpsTotal !== 10_000 && `Les parts totalisent ${bpsTotal / 100} % au lieu de 100 %.`,
  ].filter(Boolean) as string[];

  const update = (i: number, patch: Partial<Row>) =>
    setRows(rows.map((r, j) => (j === i ? { ...r, ...patch } : r)));

  async function submit() {
    const splits = rows.map((r) => ({
      recipient: r.recipient as Address,
      bps: Math.round(Number(r.percent) * 100),
    }));
    const ok = await tx.send("Enregistrer le token", {
      address: d.registry, abi: registryAbi, functionName: "registerToken",
      args: [token as Address, adapter as Address, creatorIdOf(platform, externalId), splits,
        fallback as Address, toBytes32(launchpadId || "nod")],
    });
    if (ok) onRegistered(token as Address);
  }

  return (
    <section className="card">
      <h2>Enregistrer un token</h2>
      <p className="muted">
        Le launchpad doit avoir fixé le vault prédit comme destinataire des frais, de façon
        définitive, avant l'enregistrement.
      </p>
      <label>Adresse du token<input value={token} onChange={(e) => setToken(e.target.value.trim())} placeholder="0x…" /></label>
      {predicted && (
        <p className="hint">Vault prédit pour ce token : <span className="mono">{predicted[0]}</span></p>
      )}
      <label>Adaptateur du launchpad<input value={adapter} onChange={(e) => setAdapter(e.target.value.trim())} placeholder="0x…" /></label>
      <label>
        Plateforme du créateur
        <select value={platform} onChange={(e) => setPlatform(e.target.value)}>
          {PLATFORMS.map(([id, name]) => <option key={id} value={id}>{name}</option>)}
        </select>
      </label>
      <label>
        Identifiant du compte (numérique, jamais le pseudo)
        <input value={externalId} onChange={(e) => setExternalId(e.target.value.trim())} placeholder="ex. 2244994945" />
      </label>
      {externalId && <p className="hint">creatorId : <span className="mono">{creatorIdOf(platform, externalId)}</span></p>}
      <fieldset>
        <legend>Répartition des frais</legend>
        {rows.map((r, i) => (
          <div className="split-input" key={i}>
            <input aria-label={`Bénéficiaire ${i + 1}`} value={r.recipient} onChange={(e) => update(i, { recipient: e.target.value.trim() })} placeholder="0x…" />
            <input aria-label={`Part ${i + 1} en %`} value={r.percent} onChange={(e) => update(i, { percent: e.target.value })} inputMode="decimal" />
            <span>%</span>
            {rows.length > 1 && (
              <button className="secondary" onClick={() => setRows(rows.filter((_, j) => j !== i))}>Retirer</button>
            )}
          </div>
        ))}
        {rows.length < 10 && (
          <button className="secondary" onClick={() => setRows([...rows, { recipient: "", percent: "0" }])}>
            Ajouter un bénéficiaire
          </button>
        )}
      </fieldset>
      <label>Adresse de repli (si refus)<input value={fallback} onChange={(e) => setFallback(e.target.value.trim())} placeholder="0x…" /></label>
      <label>Identifiant du launchpad (optionnel)<input value={launchpadId} onChange={(e) => setLaunchpadId(e.target.value)} /></label>
      {problems.length > 0 && <ul className="problems">{problems.map((p) => <li key={p}>{p}</li>)}</ul>}
      <button disabled={problems.length > 0 || tx.busy} onClick={submit}>Enregistrer</button>
      <TxNotice status={tx.status} />
    </section>
  );
}
