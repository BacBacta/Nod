import type { TxStatus } from "./useTx";

export function TxNotice({ status }: { status: TxStatus }) {
  if (status.kind === "idle") return null;
  if (status.kind === "pending") return <p className="notice" role="status">{status.label} : transaction en cours…</p>;
  if (status.kind === "done") return <p className="notice ok" role="status">{status.label} : confirmé.</p>;
  return <p className="notice err" role="alert">{status.label} : {status.message}</p>;
}
