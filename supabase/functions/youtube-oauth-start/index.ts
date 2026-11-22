const cors = {
  "Access-Control-Allow-Origin": "https://theraees4hmad-debug.github.io",
  "Access-Control-Allow-Headers": "authorization, apikey, content-type, x-client-info",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Content-Type": "application/json"
};
const json = (body: unknown, status = 200) => new Response(JSON.stringify(body), { status, headers: cors });
const b64url = (bytes: Uint8Array) => btoa(String.fromCharCode(...bytes)).replace(/\+/g,"-").replace(/\//g,"_").replace(/=+$/,"");
Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", {headers:cors});
  if (req.method !== "POST") return json({error:"Method not allowed"},405);
  const auth = req.headers.get("Authorization") || "";
  if (!auth.startsWith("Bearer ")) return json({error:"Please sign in first."},401);
  const base = Deno.env.get("SUPABASE_URL")!;
  const anon = Deno.env.get("SUPABASE_ANON_KEY")!;
  const verify = await fetch(base + "/auth/v1/user", {headers:{apikey:anon,Authorization:auth}});
  if (!verify.ok) return json({error:"Your session expired. Please sign in again."},401);
  const user = await verify.json();
  const clientId = Deno.env.get("YOUTUBE_CLIENT_ID");
  const secret = Deno.env.get("YOUTUBE_OAUTH_STATE_SECRET");
  if (!clientId || !secret) return json({error:"YouTube connection is not configured on the server yet."},500);
  const payload = b64url(new TextEncoder().encode(JSON.stringify({sub:user.id,exp:Date.now()+10*60*1000,nonce:crypto.randomUUID()})));
  const key = await crypto.subtle.importKey("raw",new TextEncoder().encode(secret),{name:"HMAC",hash:"SHA-256"},false,["sign"]);
  const sig = new Uint8Array(await crypto.subtle.sign("HMAC",key,new TextEncoder().encode(payload)));
  const state = payload + "." + b64url(sig);
  const redirect = base + "/functions/v1/youtube-oauth-callback";
  const url = new URL("https://accounts.google.com/o/oauth2/v2/auth");
  url.searchParams.set("client_id",clientId);
  url.searchParams.set("redirect_uri",redirect);
  url.searchParams.set("response_type","code");
  url.searchParams.set("scope","https://www.googleapis.com/auth/youtube.readonly");
  url.searchParams.set("access_type","offline");
  url.searchParams.set("prompt","consent");
  url.searchParams.set("include_granted_scopes","true");
  url.searchParams.set("state",state);
  return json({url:url.toString()});
});
