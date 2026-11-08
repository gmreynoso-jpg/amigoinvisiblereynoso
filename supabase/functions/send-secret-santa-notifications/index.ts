import { createClient } from "npm:@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

function esc(v: unknown) {
  return String(v ?? "")
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;");
}

function line(label: string, value: unknown) {
  const v = String(value ?? "").trim();
  return v ? `<p style="margin:6px 0"><b>${esc(label)}:</b> ${esc(v)}</p>` : "";
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  try {
    const { exchange_id } = await req.json();
    if (!exchange_id) throw new Error("Falta exchange_id");

    const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
    const secretKeys = JSON.parse(Deno.env.get("SUPABASE_SECRET_KEYS") || "{}");
    const serviceRole = secretKeys.default || Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
    const resendKey = Deno.env.get("RESEND_API_KEY")!;
    const fromEmail = Deno.env.get("SECRET_SANTA_FROM_EMAIL")!;

    if (!resendKey || !fromEmail) {
      throw new Error("Faltan RESEND_API_KEY o SECRET_SANTA_FROM_EMAIL");
    }

    if (!serviceRole) throw new Error("No hay una secret key de Supabase disponible en la Edge Function");

    const db = createClient(supabaseUrl, serviceRole, {
      auth: { persistSession: false },
    });

    const { data: exchange, error: exErr } = await db
      .from("secret_santa_exchanges")
      .select("id,name,event_date,max_amount,draw_mode,draw_finalized")
      .eq("id", exchange_id)
      .single();

    if (exErr) throw exErr;

    if (action === "draw_results") {
      if (!exchange.draw_finalized) throw new Error("El sorteo todavía no está realizado");
      if (!["classic", "blind"].includes(exchange.draw_mode)) {
        return new Response(
          JSON.stringify({ ok: true, skipped: true, reason: "mode_without_email_notifications" }),
          { headers: { ...corsHeaders, "Content-Type": "application/json" } },
        );
      }
    }

    const { data: people, error: pErr } = await db
      .from("secret_santa_people")
      .select("id,name,email,is_active,assigned_person_id,clothing_size,shoe_size,likes,dislikes,wishlist,profile_notes,notification_sent_at")
      .eq("exchange_id", exchange_id)
      .eq("is_active", true);

    if (pErr) throw pErr;

    const byId = new Map((people ?? []).map((p) => [p.id, p]));
    const pending = (people ?? []).filter((p) => !p.notification_sent_at);

    let sent = 0;
    const errors: Array<{ person_id: string; error: string }> = [];

    for (const giver of pending) {
      try {
        if (!giver.email) throw new Error("Correo electrónico vacío");
        if (!giver.assigned_person_id) throw new Error("Asignación inexistente");

        const recipient = byId.get(giver.assigned_person_id);
        if (!recipient) throw new Error("Destinatario no encontrado");

        let subject = "";
        let html = "";

        if (exchange.draw_mode === "classic") {
          subject = `🎁 Tu Amigo invisible: ${exchange.name}`;
          html = `
            <div style="font-family:Arial,sans-serif;max-width:620px;margin:auto;line-height:1.5">
              <h2>🎁 ${esc(exchange.name)}</h2>
              <p>Hola <b>${esc(giver.name)}</b>,</p>
              <p>Ya se ha realizado el sorteo.</p>
              <div style="padding:18px;border:1px solid #ddd;border-radius:14px;margin:18px 0">
                <div style="font-size:14px;color:#666">Te toca regalar a</div>
                <div style="font-size:30px;font-weight:800;margin-top:5px">${esc(recipient.name)}</div>
              </div>
              ${Number(exchange.max_amount || 0) > 0 ? `<p>Importe máximo orientativo: <b>${Number(exchange.max_amount).toLocaleString("es-ES",{style:"currency",currency:"EUR"})}</b></p>` : ""}
              <p style="color:#666;font-size:13px">Este correo es personal. No compartas el resultado si quieres mantener el secreto.</p>
            </div>`;
        } else {
          subject = `🔐 Tu ficha anónima de regalo: ${exchange.name}`;
          html = `
            <div style="font-family:Arial,sans-serif;max-width:620px;margin:auto;line-height:1.5">
              <h2>🔐 ${esc(exchange.name)}</h2>
              <p>Hola <b>${esc(giver.name)}</b>,</p>
              <p>Ya se ha realizado el sorteo secreto. No vas a conocer la identidad de la persona para la que compras el regalo. Esta es únicamente su ficha anónima:</p>
              <div style="padding:18px;border:1px solid #ddd;border-radius:14px;margin:18px 0">
                ${line("Talla de ropa", recipient.clothing_size)}
                ${line("Talla de calzado", recipient.shoe_size)}
                ${line("Gustos / aficiones", recipient.likes)}
                ${line("Evitar / no le gusta", recipient.dislikes)}
                ${line("Lista de deseos", recipient.wishlist)}
                ${line("Notas", recipient.profile_notes)}
              </div>
              ${Number(exchange.max_amount || 0) > 0 ? `<p>Importe máximo orientativo: <b>${Number(exchange.max_amount).toLocaleString("es-ES",{style:"currency",currency:"EUR"})}</b></p>` : ""}
              <p><b>No intentes identificar a la persona.</b> El objetivo de esta modalidad es que comprador, receptor y organizador desconozcan las parejas.</p>
            </div>`;
        }

        const resend = await fetch("https://api.resend.com/emails", {
          method: "POST",
          headers: {
            "Authorization": `Bearer ${resendKey}`,
            "Content-Type": "application/json",
          },
          body: JSON.stringify({
            from: fromEmail,
            to: [giver.email],
            subject,
            html,
          }),
        });

        if (!resend.ok) {
          const body = await resend.text();
          throw new Error(`Resend ${resend.status}: ${body}`);
        }

        await db
          .from("secret_santa_people")
          .update({
            notification_sent_at: new Date().toISOString(),
            notification_error: null,
          })
          .eq("id", giver.id);

        sent++;
      } catch (e) {
        const message = e instanceof Error ? e.message : String(e);
        errors.push({ person_id: giver.id, error: message });

        await db
          .from("secret_santa_people")
          .update({ notification_error: message })
          .eq("id", giver.id);
      }
    }

    if (errors.length === 0) {
      await db
        .from("secret_santa_exchanges")
        .update({ notifications_sent_at: new Date().toISOString() })
        .eq("id", exchange_id);
    }

    return new Response(
      JSON.stringify({
        ok: errors.length === 0,
        sent,
        failed: errors.length,
      }),
      { headers: { ...corsHeaders, "Content-Type": "application/json" } },
    );
  } catch (e) {
    return new Response(
      JSON.stringify({ ok: false, error: e instanceof Error ? e.message : String(e) }),
      { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } },
    );
  }
});
