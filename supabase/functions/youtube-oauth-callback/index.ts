const base = Deno.env.get("SUPABASE_URL")!;
const site = "https://theraees4hmad-debug.github.io/CreatorBoost/";
const go = (q:string) => Response.redirect(site + "?page=profile&" + q,303);
const b64decode = (s:string) => Uint8Array.from(atob(s.replace(/-/g,"+").replace(/_/g,"/") + "=".repeat((4-s.length%4)%4)),c=>c.charCodeAt(0));
Deno.serve(async (req) => {
  const u = new URL(req.url);
  const code = u.searchParams.get("code");
  const state = u.searchParams.get("state") || "";
  const [payload,signature] = state.split(".");
  const secret = Deno.env.get("YOUTUBE_OAUTH_STATE_SECRET");
  const clientId = Deno.env.get("YOUTUBE_CLIENT_ID");
  const clientSecret = Deno.env.get("YOUTUBE_CLIENT_SECRET");
  if (u.searchParams.has("error")) return go("youtube_error=consent_cancelled");
  if (!code || !payload || !signature || !secret || !clientId || !clientSecret) return go("youtube_error=oauth_setup");
  try {
    const key = await crypto.subtle.importKey("raw",new TextEncoder().encode(secret),{name:"HMAC",hash:"SHA-256"},false,["verify"]);
    const valid = await crypto.subtle.verify("HMAC",key,b64decode(signature),new TextEncoder().encode(payload));
    if (!valid) return go("youtube_error=invalid_state");
    const stateData = JSON.parse(new TextDecoder().decode(b64decode(payload)));
    if (!stateData.sub || stateData.exp < Date.now()) return go("youtube_error=expired_state");
    const redirect = base + "/functions/v1/youtube-oauth-callback";
    const form = new URLSearchParams({code,client_id:clientId,client_secret:clientSecret,redirect_uri:redirect,grant_type:"authorization_code"});
    const tokenRes = await fetch("https://oauth2.googleapis.com/token",{method:"POST",headers:{"Content-Type":"application/x-www-form-urlencoded"},body:form});
    const token = await tokenRes.json();
    if (!tokenRes.ok || !token.access_token) return go("youtube_error=token_exchange");
    const channelRes = await fetch("https://www.googleapis.com/youtube/v3/channels?part=snippet&mine=true",{headers:{Authorization:"Bearer "+token.access_token}});
    const channelData = await channelRes.json();
    const channel = channelData.items?.[0];
    const service = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
    const headers = {apikey:service,Authorization:"Bearer "+service,"Content-Type":"application/json",Prefer:"resolution=merge-duplicates,return=minimal"};
    const existingRes = await fetch(base+"/rest/v1/cb_youtube_connections?user_id=eq."+encodeURIComponent(stateData.sub)+"&select=refresh_token",{headers:{apikey:service,Authorization:"Bearer "+service}});
    const existing = await existingRes.json();
    const refresh = token.refresh_token || existing?.[0]?.refresh_token;
    if (!refresh) return go("youtube_error=missing_refresh_token");
    const save = await fetch(base+"/rest/v1/cb_youtube_connections",{method:"POST",headers,body:JSON.stringify({user_id:stateData.sub,refresh_token:refresh,channel_id:channel?.id||null,channel_title:channel?.snippet?.title||null,connected_at:new Date().toISOString()})});
    if (!save.ok) return go("youtube_error=save_failed");
    return go("youtube=connected");
  } catch (_) {
    return go("youtube_error=callback_failed");
  }
});
