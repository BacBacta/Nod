import { useEffect, useState } from "react";
import { erc20Abi, isAddress, type Address } from "viem";
import { useAccount, useChainId, useConnect, useDisconnect, useReadContract, useSwitchChain } from "wagmi";
import { deploymentFor } from "./deployments";
import { short, usdc } from "./format";
import { RegisterToken } from "./RegisterToken";
import { TokenPanel } from "./TokenPanel";

export function App() {
  const chainId = useChainId();
  const d = deploymentFor(chainId);
  const [tab, setTab] = useState<"token" | "register">("token");
  const [input, setInput] = useState("");
  const token = isAddress(input) ? (input as Address) : undefined;

  // Prefill the seeded demo token on the local chain.
  useEffect(() => {
    if (d?.demoToken && !input) setInput(d.demoToken);
  }, [d?.demoToken]); // eslint-disable-line react-hooks/exhaustive-deps

  return (
    <>
      <header>
        <div>
          <h1>Nod</h1>
          <p className="muted">Frais créateurs en USDC sur Arc</p>
        </div>
        <Wallet />
      </header>
      <main>
        {!d ? (
          <section className="card">
            <h2>Contrats non déployés sur ce réseau</h2>
            <p className="muted">
              Nod n'est pas encore déployé sur Arc Testnet. En local, lancez
              <code> scripts/dev-local.sh</code> puis connectez un compte anvil.
            </p>
          </section>
        ) : (
          <>
            <nav className="tabs">
              <button className={tab === "token" ? "active" : ""} onClick={() => setTab("token")}>Consulter un token</button>
              <button className={tab === "register" ? "active" : ""} onClick={() => setTab("register")}>Enregistrer un token</button>
            </nav>
            {tab === "token" ? (
              <>
                <label className="lookup">
                  Adresse du token
                  <input value={input} onChange={(e) => setInput(e.target.value.trim())} placeholder="0x…" />
                </label>
                {token ? <TokenPanel key={token} d={d} token={token} /> : input && <p className="muted">Adresse invalide.</p>}
              </>
            ) : (
              <RegisterToken d={d} onRegistered={(t) => { setInput(t); setTab("token"); }} />
            )}
          </>
        )}
      </main>
    </>
  );
}

function Wallet() {
  const { address, connector, chain } = useAccount();
  const { connectors, connect, error } = useConnect();
  const { disconnect } = useDisconnect();
  const { chains, switchChain } = useSwitchChain();
  const d = deploymentFor(chain?.id);
  // One USDC balance, ERC-20 view (6 decimals): never show native + ERC-20 separately.
  const { data: balance } = useReadContract({
    address: d?.usdc, abi: erc20Abi, functionName: "balanceOf",
    args: address ? [address] : undefined, query: { enabled: !!address && !!d },
  });

  if (!address) {
    return (
      <div className="wallet">
        {connectors.map((c) => (
          <button key={c.uid} onClick={() => connect({ connector: c })}>
            {c.id === "injected" ? "Connecter mon wallet" : c.name}
          </button>
        ))}
        {error && <p className="notice err">{error.message}</p>}
      </div>
    );
  }
  return (
    <div className="wallet">
      <select
        aria-label="Réseau"
        value={chain?.id ?? ""}
        onChange={(e) => switchChain({ chainId: Number(e.target.value) as (typeof chains)[number]["id"] })}
      >
        {!chain && <option value="">Réseau non supporté</option>}
        {chains.map((c) => <option key={c.id} value={c.id}>{c.name}</option>)}
      </select>
      <span className="mono" title={address}>{short(address)}</span>
      {d && <span>{usdc(balance)}</span>}
      <button className="secondary" onClick={() => disconnect()} title={connector?.name}>Déconnecter</button>
    </div>
  );
}
