// =====================================================================
//  PILE POIL — envoi des notifications (appelé chaque heure par Supabase)
//  Les règles (1 par jour, jamais la nuit, joueur parti…) sont dans push_due().
//  Les clés de sécurité sont créées ici la première fois et restent dans Supabase.
// =====================================================================
import webpush from "npm:web-push@3.6.7";
import { createClient } from "npm:@supabase/supabase-js@2.45.4";
// heure de Paris (0-23)

const sb = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } });
const json = (o: unknown, status = 200) => new Response(JSON.stringify(o), { status, headers: { "Content-Type": "application/json" } });

Deno.serve(async (req) => {
  const { data: keys, error: ke } = await sb.rpc("push_keys_get");
  if (ke || !keys) return json({ error: "clés indisponibles" }, 500);
  if (req.headers.get("x-cron-key") !== keys.cron_key) return json({ error: "non autorisé" }, 401);

  // première fois : création des clés (la clé privée ne quitte jamais Supabase)
  let pub = keys.public_key as string | null, priv = keys.private_key as string | null;
  if (!pub || !priv) {
    const k = webpush.generateVAPIDKeys();
    await sb.rpc("push_keys_set", { p_public: k.publicKey, p_private: k.privateKey });
    const { data: again } = await sb.rpc("push_keys_get");
    pub = again.public_key; priv = again.private_key;
  }
  webpush.setVapidDetails("mailto:pilepoil.jeu@gmail.com", pub!, priv!);

  const body = await req.json().catch(() => ({}));
  const hour = typeof body.hour === "number" ? body.hour
    : parseInt(new Intl.DateTimeFormat("en-GB", { timeZone: "Europe/Paris", hour: "2-digit", hour12: false }).format(new Date()), 10) % 24;
  const test = typeof body.test_pid === "string" ? body.test_pid : null;   // essai : n'entre pas dans le compte « 1 par jour »
  const { data: due, error } = test ? await sb.rpc("push_test", { p_pid: test }) : await sb.rpc("push_due", { p_hour: hour });
  if (error) return json({ error: error.message }, 500);

  let sent = 0, gone = 0, failed = 0;
  for (const m of (due || []) as Record<string, any>[]) {
    const sub = { endpoint: m.endpoint, keys: { p256dh: m.p256dh, auth: m.auth } };
    const payload = JSON.stringify({ title: m.title, body: m.body, url: m.url, tag: m.tag });
    try {
      await webpush.sendNotification(sub, payload, { TTL: 6 * 3600, urgency: "normal" });
      if (!test) await sb.rpc("push_mark", { p_pid: m.pid, p_ok: true, p_state: m.state || {}, p_gone: false });
      sent++;
    } catch (e: any) {
      const code = e?.statusCode;
      if (code === 404 || code === 410) { await sb.rpc("push_mark", { p_pid: m.pid, p_ok: false, p_state: {}, p_gone: true }); gone++; }
      else failed++;
    }
  }
  return json({ hour, candidates: (due || []).length, sent, gone, failed });
});
