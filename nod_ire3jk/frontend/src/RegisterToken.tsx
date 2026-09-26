import { useState } from "react";
import { encodeAbiParameters, isAddress, isHex, keccak256, stringToBytes, zeroAddress, type Address, type Hex } from "viem";
import { useAccount, useReadContract, useReadContracts } from "wagmi";
import { iLaunchpadAdapterAbi } from "./abi/ILaunchpadAdapter";
import { sameAddress, short } from "./format";
import { registryAbi } from "./abi/Registry";
import { feeVaultFactoryAbi } from "./abi/FeeVaultFactory";
import type { Deployment } from "./deployments";
import { TxNotice } from "./TxNotice";
import { useTx } from "./useTx";

type Row = { recipient: string; percent: string };

/** Ownable2Step surface of a pull-model fee source (e.g. a Bullcheese LP locker). */
const lockerAbi = [
  { type: "function", name: "owner", stateMutability: "view", inputs: [], outputs: [{ type: "address" }] },
  { type: "function", name: "pendingOwner", stateMutability: "view", inputs: [], outputs: [{ type: "address" }] },
  { type: "function", name: "transferOwnership", stateMutability: "nonpayable", inputs: [{ name: "newOwner", type: "address" }], outputs: [] },
] as const;

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
  const [lockAck, setLockAck] = useState(false);

  const tokenOk = isAddress(token);
  const { data: predicted } = useReadContract({
    address: d.factory, abi: feeVaultFactoryAbi, functionName: "predictVaultAddress",
    args: me && tokenOk ? [me, token] : undefined, query: { enabled: !!me && tokenOk },
  });

  const predictedVault = predicted?.[0];
  const { data: source } = useReadContract({
    address: isAddress(adapter) ? adapter : undefined, abi: iLaunchpadAdapterAbi, functionName: "feeSource",
    args: tokenOk ? [token] : undefined, query: { enabled: tokenOk && isAddress(adapter) },
  });
  const locker = source && source !== zeroAddress ? source : undefined;
  const { data: lockerState } = useReadContracts({
    contracts: locker ? [
      { address: locker, abi: lockerAbi, functionName: "owner" },
      { address: locker, abi: lockerAbi, functionName: "pendingOwner" },
    ] : [],
    query: { enabled: !!locker },
  });
  const lockerOwner = lockerState?.[0]?.result as Address | undefined;
  const lockerPending = lockerState?.[1]?.result as Address | undefined;
  const lockerReady = !locker || sameAddress(lockerPending, predictedVault);

  const bpsTotal = rows.reduce((s, r) => s + Math.round(Number(r.percent) * 100 || 0), 0);
  const problems = [
    !me && "Connectez un wallet.",
    !tokenOk && "Adresse du token invalide.",
    !isAddress(adapter) && "Adresse de l'adaptateur invalide.",
    !externalId && "Identifiant du compte créateur manquant.",
    !isAddress(fallback) && "Adresse de repli invalide.",
    rows.some((r) => !isAddress(r.recipient)) && "Adresse de bénéficiaire invalide.",
    bpsTotal !== 10_000 && `Les parts totalisent ${bpsTotal / 100} % au lieu de 100 %.`,
    !lockerReady && "Transférez d'abord le verrou de liquidité au vault prédit (étape ci-dessus).",
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
      {(d.adapter || d.bullcheeseAdapter) && (
        <div className="actions">
          {d.adapter && <button className="secondary" onClick={() => setAdapter(d.adapter!)}>Launchpad classique</button>}
          {d.bullcheeseAdapter && <button className="secondary" onClick={() => setAdapter(d.bullcheeseAdapter!)}>Bullcheese</button>}
        </div>
      )}
      {locker && predictedVault && (
        <div className="notice">
          <p>
            Ce launchpad verse les frais au propriétaire du verrou de liquidité{" "}
            <span className="mono">{short(locker)}</span>. Transférez-le au vault prédit{" "}
            <span className="mono">{short(predictedVault)}</span>, puis enregistrez depuis ce même
            wallet : la liquidité restera verrouillée définitivement dans le vault.
          </p>
          {lockerReady ? (
            <p className="notice ok" role="status">Transfert du verrou en attente d'acceptation par le vault.</p>
          ) : sameAddress(me, lockerOwner) ? (
            <>
            <label className="ack">
              <input type="checkbox" checked={lockAck} onChange={(e) => setLockAck(e.target.checked)} />
              Je comprends que la liquidité de ce token restera verrouillée définitivement dans le
              vault Nod : ni moi ni personne ne pourra plus la retirer ni récupérer le verrou.
            </label>
            <button
              disabled={tx.busy || !lockAck}
              onClick={() => tx.send("Transférer le verrou", {
                address: locker, abi: lockerAbi, functionName: "transferOwnership", args: [predictedVault],
              })}
            >
              Transférer le verrou au vault
            </button>
            </>
          ) : (
            <p className="notice err">Seul le propriétaire du verrou ({short(lockerOwner)}) peut le transférer.</p>
          )}
        </div>
      )}
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
