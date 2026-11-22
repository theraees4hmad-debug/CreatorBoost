const cors={"Access-Control-Allow-Origin":"https://theraees4hmad-debug.github.io","Access-Control-Allow-Headers":"authorization, apikey, content-type, x-client-info","Access-Control-Allow-Methods":"POST, OPTIONS","Content-Type":"application/json"};
const json=(body:unknown,status=200)=>new Response(JSON.stringify(body),{status,headers:cors});
Deno.serve(async(req)=>{
 if(req.method==="OPTIONS")return new Response("ok",{headers:cors});
 const auth=req.headers.get("Authorization")||"";
 if(!auth.startsWith("Bearer "))return json({error:"Sign in required"},401);
 const base=Deno.env.get("SUPABASE_URL")!, anon=Deno.env.get("SUPABASE_ANON_KEY")!, service=Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
 const userRes=await fetch(base+"/auth/v1/user",{headers:{apikey:anon,Authorization:auth}});
 if(!userRes.ok)return json({error:"Session expired"},401);
 const user=await userRes.json();
 const r=await fetch(base+"/rest/v1/cb_youtube_connections?user_id=eq."+encodeURIComponent(user.id)+"&select=channel_id,channel_title,connected_at",{headers:{apikey:service,Authorization:"Bearer "+service}});
 if(!r.ok)return json({error:"Could not read connection"},500);
 const rows=await r.json();
 return json({connected:!!rows.length,channel:rows[0]||null});
});
