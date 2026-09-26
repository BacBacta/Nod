import { erc20Abi, type Address } from "viem";
import { useAccount, useBlock, useReadContract, useReadContracts } from "wagmi";
import { registryAbi } from "./abi/Registry";
import { payoutRouterAbi } from "./abi/PayoutRouter";
import { feeVaultAbi } from "./abi/FeeVault";
import { identityAttestorAbi } from "./abi/IdentityAttestor";
import type { Deployment } from "./deployments";
import { STATES, TokenState, sameAddress, short, usdc } from "./format";
import { TxNotice } from "./TxNotice";
import { useTx } from "./useTx";

export function TokenPanel({ d, token }: { d: Deployment; token: Address }) {
  const { address: me } = useAccount();
  const { data: block } = useBlock({ watch: true });
  const tx = useTx();

  const { data: head } = useReadContracts({
    contracts: [
      { address: d.registry, abi: registryAbi, functionName: "getRecord", args: [token] },
      { address: d.registry, abi: registryAbi, functionName: "splitCountOf", args: [token] },
    ],
  });
  const record = head?.[0].result;
  const splitCount = Number(head?.[1].result ?? 0);

  if (head && (!record || record[2] === TokenState.NONE)) {
    return <p className="muted">Ce token n'est pas enregistré dans Nod.</p>;
  }
  if (!record) return <p className="muted">Chargement…</p>;

  const [vault, creatorId, state, deadline] = record;
  const now = block?.timestamp ?? 0n;
  const deadlinePassed = now > BigInt(deadline);

  return (
    <section className="card">
      <h2>
        Token {short(token)} <span className={`badge s${state}`}>{STATES[state]}</span>
      </h2>
      <TokenSummary d={d} vault={vault} creatorId={creatorId} deadline={deadline} />
      <CreatorActions
        d={d} token={token} creatorId={creatorId} state={state}
        deadlinePassed={deadlinePassed} tx={tx} me={me}
      />
      <h3>Répartition</h3>
      <div className="table-wrap">
      <table>
        <thead>
          <tr><th>#</th><th>Bénéficiaire</th><th>Part</th><th>État</th><th>Réservé</th><th>À réclamer</th><th></th></tr>
        </thead>
        <tbody>
          {Array.from({ length: splitCount }, (_, i) => (
            <SplitRow
              key={i} d={d} token={token} vault={vault} index={i} tokenState={state}
              deadlinePassed={deadlinePassed} me={me} tx={tx}
            />
          ))}
        </tbody>
      </table>
      </div>
      <div className="actions">
        <button
          disabled={tx.busy || state === TokenState.PENDING}
          title={state === TokenState.PENDING ? "Les frais s'accumulent tant que le créateur n'a pas décidé" : ""}
          onClick={() => tx.send("Distribuer les frais", {
            address: d.registry, abi: registryAbi, functionName: "distributeIncoming", args: [token],
          })}
        >
          Distribuer les frais reçus
        </button>
      </div>
      <TxNotice status={tx.status} />
    </section>
  );
}

function TokenSummary({ d, vault, creatorId, deadline }: {
  d: Deployment; vault: Address; creatorId: `0x${string}`; deadline: number;
}) {
  const { data } = useReadContracts({
    contracts: [
      { address: d.usdc, abi: erc20Abi, functionName: "balanceOf", args: [vault] },
      { address: vault, abi: feeVaultAbi, functionName: "availableBalance" },
      { address: vault, abi: feeVaultAbi, functionName: "depositCap" },
      { address: d.attestor, abi: identityAttestorAbi, functionName: "walletOf", args: [creatorId] },
    ],
  });
  const cap = data?.[2].result;
  return (
    <dl className="grid">
      <dt>Vault</dt><dd className="mono">{vault}</dd>
      <dt>Wallet du créateur</dt><dd className="mono">{data?.[3].result ?? "…"}</dd>
      <dt>USDC dans le vault</dt><dd>{usdc(data?.[0].result)}</dd>
      <dt>Non encore distribué</dt><dd>{usdc(data?.[1].result)}</dd>
      <dt>Plafond de dépôt</dt><dd>{cap === undefined ? "…" : cap === 0n ? "Aucun" : usdc(cap)}</dd>
      <dt>Date limite de décision</dt><dd>{new Date(deadline * 1000).toLocaleString("fr-FR")}</dd>
    </dl>
  );
}

function CreatorActions({ d, token, creatorId, state, deadlinePassed, tx, me }: {
  d: Deployment; token: Address; creatorId: `0x${string}`; state: number;
  deadlinePassed: boolean; tx: ReturnType<typeof useTx>; me?: Address;
}) {
  const { data: creatorWallet } = useReadContract({
    address: d.attestor, abi: identityAttestorAbi, functionName: "walletOf", args: [creatorId],
  });
  const isCreator = sameAddress(me, creatorWallet);
  const call = (label: string, functionName: "accept" | "refuse" | "expire") =>
    tx.send(label, { address: d.registry, abi: registryAbi, functionName, args: [token] });

  return (
    <div className="actions">
      {isCreator && (state === TokenState.PENDING || state === TokenState.REFUSED) && (
        <button disabled={tx.busy} onClick={() => call("Accepter le token", "accept")}>
          Accepter le token
        </button>
      )}
      {isCreator && state !== TokenState.REFUSED && (
        <button className="secondary" disabled={tx.busy} onClick={() => call("Refuser le token", "refuse")}>
          Refuser le token
        </button>
      )}
      {state === TokenState.PENDING && deadlinePassed && (
        <button className="secondary" disabled={tx.busy} onClick={() => call("Expirer le token", "expire")}>
          Expirer (délai dépassé)
        </button>
      )}
      {!isCreator && state === TokenState.PENDING && !deadlinePassed && (
        <p className="muted">En attente de la décision du créateur.</p>
      )}
    </div>
  );
}

function SplitRow({ d, token, vault, index, tokenState, deadlinePassed, me, tx }: {
  d: Deployment; token: Address; vault: Address; index: number; tokenState: number;
  deadlinePassed: boolean; me?: Address; tx: ReturnType<typeof useTx>;
}) {
  const i = index;
  const { data } = useReadContracts({
    contracts: [
      { address: d.registry, abi: registryAbi, functionName: "getSplit", args: [token, i] },
      { address: d.registry, abi: registryAbi, functionName: "reservedOf", args: [token, i] },
    ],
  });
  const split = data?.[0].result;
  const recipient = split?.[0];
  const { data: claimable } = useReadContract({
    address: vault, abi: feeVaultAbi, functionName: "claimable",
    args: recipient ? [recipient] : undefined, query: { enabled: !!recipient },
  });
  if (!split) return <tr><td colSpan={7}>…</td></tr>;

  const [, bps, state] = split;
  const mine = sameAddress(me, recipient);
  const tokenAccepted = tokenState === TokenState.ACCEPTED;
  const splitCall = (label: string, functionName: "acceptSplit" | "refuseSplit" | "expireSplitRecipient") =>
    tx.send(label, { address: d.registry, abi: registryAbi, functionName, args: [token, i] });

  return (
    <tr className={mine ? "mine" : ""}>
      <td>{i}</td>
      <td className="mono" title={recipient}>{short(recipient)}{mine && " (vous)"}</td>
      <td>{bps / 100} %</td>
      <td><span className={`badge s${state}`}>{STATES[state]}</span></td>
      <td>{usdc(data?.[1].result)}</td>
      <td>{usdc(claimable)}</td>
      <td className="row-actions">
        {mine && tokenAccepted && state === TokenState.PENDING && (
          <>
            <button disabled={tx.busy} onClick={() => splitCall(`Accepter la part #${i}`, "acceptSplit")}>Accepter ma part</button>
            <button className="secondary" disabled={tx.busy} onClick={() => splitCall(`Refuser la part #${i}`, "refuseSplit")}>Refuser</button>
          </>
        )}
        {mine && state === TokenState.ACCEPTED && (claimable ?? 0n) > 0n && (
          <button
            disabled={tx.busy}
            onClick={() => tx.send(`Réclamer la part #${i}`, {
              address: d.payoutRouter, abi: [...payoutRouterAbi, ...registryAbi],
              functionName: "claim", args: [token, i],
            })}
          >
            Réclamer
          </button>
        )}
        {!mine && state === TokenState.PENDING && deadlinePassed && (
          <button className="secondary" disabled={tx.busy} onClick={() => splitCall(`Expirer la part #${i}`, "expireSplitRecipient")}>
            Expirer
          </button>
        )}
      </td>
    </tr>
  );
}
