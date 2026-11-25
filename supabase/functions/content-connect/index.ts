const cors={"Access-Control-Allow-Origin":"https://theraees4hmad-debug.github.io","Access-Control-Allow-Headers":"authorization, apikey, content-type, x-client-info","Access-Control-Allow-Methods":"POST, OPTIONS","Content-Type":"application/json"};
const json=(body,status=200)=>new Response(JSON.stringify(body),{status,headers:cors});
const enc=(b)=>btoa(String.fromCharCode(...b));
async function crypt(value,keyText){const raw=Uint8Array.from(atob(keyText),c=>c.charCodeAt(0));if(raw.length!==32)throw new Error("CONTENT_ENCRYPTION_KEY must be a base64-encoded 32-byte key.");const key=await crypto.subtle.importKey("raw",raw,{name:"AES-GCM"},false,["encrypt"]);const iv=crypto.getRandomValues(new Uint8Array(12));const data=await crypto.subtle.encrypt({name:"AES-GCM",iv},key,new TextEncoder().encode(value));const all=new Uint8Array(iv.length+data.byteLength);all.set(iv);all.set(new Uint8Array(data),iv.length);return enc(all);}
Deno.serve(async(req)=>{
 if(req.method==="OPTIONS")return new Response("ok",{headers:cors});
 if(req.method!=="POST")return json({error:"Method not allowed"},405);
 const auth=req.headers.get("Authorization")||"";if(!auth.startsWith("Bearer "))return json({error:"Sign in required"},401);
 const base=Deno.env.get("SUPABASE_URL")!,anon=Deno.env.get("SUPABASE_ANON_KEY")!,service=Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,key=Deno.env.get("CONTENT_ENCRYPTION_KEY");
 if(!key)return json({error:"Account connection is not configured. Add CONTENT_ENCRYPTION_KEY to Supabase Edge Function secrets."},503);
 const u=await fetch(base+"/auth/v1/user",{headers:{apikey:anon,Authorization:auth}});if(!u.ok)return json({error:"Session expired"},401);const user=await u.json();
 let b:any;try{b=await req.json()}catch{return json({error:"Invalid request"},400)}
 const platform=b.platform;
 if(!["wordpress","x"].includes(platform))return json({error:"Currently supported publishing connections are WordPress and X."},400);
 let accountId="",accountName="",siteUrl=null,secret="";
 if(platform==="wordpress"){
  try{const url=new URL(String(b.site_url||""));if(url.protocol!=="https:")throw new Error();siteUrl=url.toString();if(siteUrl.endsWith("/"))siteUrl=siteUrl.slice(0,-1);}catch{return json({error:"Enter a valid HTTPS WordPress site URL."},400)}
  accountName=String(b.username||"").trim().slice(0,120);secret=String(b.application_password||"").trim();
  if(!accountName||!secret)return json({error:"WordPress username and application password are required."},400);
  accountId=siteUrl+"|"+accountName;
 }else{
  accountName=String(b.account_name||"").trim().slice(0,120);secret=String(b.access_token||"").trim();accountId=String(b.account_id||accountName).trim().replace(/^@/,"");
  if(!accountName||!accountId||!secret)return json({error:"X account name and OAuth 2.0 user access token are required."},400);
 }
 let ciphertext:string;try{ciphertext=await crypt(secret,key)}catch(e){return json({error:e instanceof Error?e.message:"Could not secure credentials"},500)}
 const row={user_id:user.id,platform,account_id:accountId,account_name:accountName,site_url:siteUrl,access_token_ciphertext:ciphertext,status:"connected",updated_at:new Date().toISOString()};
 const save=await fetch(base+"/rest/v1/cb_content_connections?on_conflict=user_id,platform,account_id",{method:"POST",headers:{apikey:service,Authorization:"Bearer "+service,"Content-Type":"application/json",Prefer:"resolution=merge-duplicates,return=minimal"},body:JSON.stringify(row)});
 if(!save.ok)return json({error:"Could not save the publishing connection."},500);
 return json({success:true,platform,account_name:accountName});
});