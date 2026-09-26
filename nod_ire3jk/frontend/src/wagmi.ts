import { http, createConfig, createConnector } from "wagmi";
import { anvil, arcTestnet } from "wagmi/chains";
import { injected, mock } from "wagmi/connectors";
import { hasLocalDeployment } from "./deployments";

// Anvil default accounts #1 (demo creator, split 0) and #2 (split 1). Their keys are
// public and only unlocked on a local anvil node; these connectors never exist on Arc.
const ANVIL_ACCOUNTS = [
  "0x70997970C51812dc3A010C7d01b50e0d17dc79C8",
  "0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC",
] as const;

// Remembers the connected anvil account so it reconnects after a full-page redirect
// (identity OAuth); the mock connector itself forgets on reload.
const DEV_ACCOUNT_KEY = "nod.anvilAccount";
const devStore = {
  get: () => { try { return localStorage.getItem(DEV_ACCOUNT_KEY); } catch { return null; } },
  set: (v: string | null) => {
    try { if (v) localStorage.setItem(DEV_ACCOUNT_KEY, v); else localStorage.removeItem(DEV_ACCOUNT_KEY); } catch { /* ignore */ }
  },
};

function anvilAccount(account: (typeof ANVIL_ACCOUNTS)[number], n: number) {
  const base = mock({ accounts: [account], features: { reconnect: true } });
  const id = `anvil-${n}`;
  return createConnector((config) => {
    const c = base(config);
    return {
      ...c,
      id,
      name: `Compte anvil #${n} (local)`,
      async connect(params) {
        const result = await c.connect.call(this, params);
        devStore.set(id);
        return result;
      },
      async disconnect() {
        if (devStore.get() === id) devStore.set(null);
        return c.disconnect.call(this);
      },
      async isAuthorized() {
        return devStore.get() === id;
      },
    } as typeof c;
  });
}

export const config = createConfig({
  // The mock connectors start on the first chain, so anvil leads when it is available.
  chains: hasLocalDeployment ? [anvil, arcTestnet] : [arcTestnet],
  connectors: [
    injected(),
    ...(hasLocalDeployment ? ANVIL_ACCOUNTS.map((a, i) => anvilAccount(a, i + 1)) : []),
  ],
  transports: {
    [arcTestnet.id]: http("https://rpc.testnet.arc.io"),
    [anvil.id]: http("http://127.0.0.1:8545"),
  },
});

declare module "wagmi" {
  interface Register {
    config: typeof config;
  }
}
