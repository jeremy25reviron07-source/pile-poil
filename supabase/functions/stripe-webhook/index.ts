// PILE POIL — webhook Stripe : enregistre chaque paiement réussi dans la table "purchases"
// Secrets à créer dans Supabase (Edge Functions → Secrets) : STRIPE_SECRET_KEY, STRIPE_WEBHOOK_SECRET
import Stripe from "npm:stripe@14.25.0";
import { createClient } from "npm:@supabase/supabase-js@2.45.4";

const stripe = new Stripe(Deno.env.get("STRIPE_SECRET_KEY")!, { apiVersion: "2024-06-20" });
const db = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);

// montant en centimes (avant réduction) → contenu du pack
const PACKS: Record<number, { coins: number; item?: string }> = {
  299: { coins: 2500, item: "chrome" }, // Pack Démarrage
  199: { coins: 1000 },                 // Poignée de pièces
  499: { coins: 3000 },                 // Sac de pièces
  999: { coins: 6500 },                 // Coffre de chantier
  1999: { coins: 14000 },               // Benne de pièces
};
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

Deno.serve(async (req) => {
  const sig = req.headers.get("stripe-signature");
  if (!sig) return new Response("Signature manquante", { status: 400 });
  const body = await req.text();
  let event: Stripe.Event;
  try {
    event = await stripe.webhooks.constructEventAsync(body, sig, Deno.env.get("STRIPE_WEBHOOK_SECRET")!, undefined, Stripe.createSubtleCryptoProvider());
  } catch (e) {
    console.error("Signature invalide", e?.message);
    return new Response("Signature invalide", { status: 400 });
  }
  if (event.type === "checkout.session.completed" || event.type === "checkout.session.async_payment_succeeded") {
    const s = event.data.object as Stripe.Checkout.Session;
    if (s.payment_status !== "paid") return new Response("en attente");
    const cents = s.amount_subtotal ?? s.amount_total ?? 0;
    const pack = PACKS[cents];
    const pid = s.client_reference_id ?? "";
    if (!pack || !UUID.test(pid)) {
      console.error("Achat non reconnu", s.id, cents, pid);
      return new Response("ignoré");
    }
    const { error } = await db.from("purchases").upsert(
      { session_id: s.id, pid, coins: pack.coins, item: pack.item ?? null, amount: s.amount_total },
      { onConflict: "session_id", ignoreDuplicates: true },
    );
    if (error) { console.error(error); return new Response("Erreur base", { status: 500 }); }
    console.log("Achat enregistré", s.id, pack.coins);
  }
  return new Response("ok");
});
