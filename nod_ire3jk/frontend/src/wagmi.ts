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

function anvilAccount(account: (typeof ANVIL_ACCOUNTS)[number], n: number) {
  const base = mock({ accounts: [account], features: { reconnect: true } });
  return createConnector((config) => ({
    ...base(config),
    id: `anvil-${n}`,
    name: `Compte anvil #${n} (local)`,
  }));
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
