import { Firestore } from "@google-cloud/firestore";

const db = new Firestore();
const col = db.collection("payment_orders");

const snap = await col.limit(20).get();
console.log("docs:", snap.size);

for (const d of snap.docs) {
  const x = d.data() || {};
  console.log("id:", d.id, "invoiceId:", x.invoiceId || "", "keys:", Object.keys(x).slice(0, 20).join(","));
}
