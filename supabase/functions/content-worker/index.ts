const json=(body:unknown,status=200)=>new Response(JSON.stringify(body),{status,headers:{"Content-Type":"application/json"}});
const base=Deno.env.get("SUPABASE_URL")!,service=Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const headers={apikey:service,Authorization:"Bearer "+service,"Content-Type":"application/json"};
const enc=(b:Uint8Array)=>btoa(String.fromCharCode(...b));
const dec=(s:string)=>Uint8Array.from(atob(s),c=>c.charCodeAt(0));
async function decrypt(value:string,keyText:string){const raw=dec(keyText);if(raw.length!==32)throw new Error("Invalid encryption key");const key=await crypto.subtle.importKey("raw",raw,{name:"AES-GCM"},false,["decrypt"]);const all=dec(value),iv=all.slice(0,12),data=all.slice(12);return new TextDecoder().decode(await crypto.subtle.decrypt({name:"AES-GCM",iv},key,data));}
async function rest(path:string,init:RequestInit={}){const r=await fetch(base+"/rest/v1/"+path,{...init,headers:{...headers,...(init.headers||{})}});const t=await r.text();if(!r.ok)throw new Error(t.slice(0,400));return t?JSON.parse(t):null;}
function nextOccurrence(time:string,tz:string,freq:string,after=new Date()){
 const [hh,mm]=time.split(":").map(Number),start=Math.floor(after.getTime()/60000)*60000+60000;
 const fmt=new Intl.DateTimeFormat("en-US",{timeZone:tz,hour:"2-digit",minute:"2-digit",weekday:"short",hourCycle:"h23"});
 for(let t=start;t<=start+8*86400000;t+=60000){const p=Object.fromEntries(fmt.formatToParts(new Date(t)).map(x=>[x.type,x.value]));if(Number(p.hour)===hh&&Number(p.minute)===mm&&(freq!=="weekdays"||!["Sat","Sun"].includes(p.weekday))&&(freq!=="weekly"||p.weekday==="Mon"))return new Date(t).toISOString();}
 return new Date(after.getTime()+86400000).toISOString();
}
async function aiDraft(schedule:any,settings:any,apiKey:string){
 const article=schedule.content_type==="article";
 const shape=article?{title:"string",body:"string (Markdown article 700-1000 words)",excerpt:"string",seo_title:"string",seo_description:"string",hashtags:["string"]}:{title:"string",body:"string (short native social post)",excerpt:"string",seo_title:"string",seo_description:"string",hashtags:["string"]};
 const prompt=["Return valid JSON only matching "+JSON.stringify(shape)+".","Type: "+schedule.content_type+"; platform: "+schedule.platform+".","Topic prompt: "+schedule.topic_prompt,"Brand: "+(settings.brand_name||"Creator")+". Niche: "+(settings.niche||"streaming and gaming")+". Audience: "+(settings.target_audience||"fans and viewers")+". Tone: "+(settings.tone||"energetic")+". Language: "+(settings.language||"English")+".","Do not invent current news, statistics, quotes, sources or factual claims. Avoid plagiarism, keyword stuffing and misleading claims.","For articles use useful headings, an introduction, actionable sections and a conclusion. For social posts write concise platform-native copy with relevant non-spammy hashtags."].join("\n");
 const r=await fetch("https://api.openai.com/v1/chat/completions",{method:"POST",headers:{Authorization:"Bearer "+apiKey,"Content-Type":"application/json"},body:JSON.stringify({model:"gpt-4o-mini",temperature:.7,response_format:{type:"json_object"},messages:[{role:"system",content:"You are CreatorBoost's editorial content assistant. Return valid JSON only."},{role:"user",content:prompt}]})});
 const d=await r.json();if(!r.ok)throw new Error(d?.error?.message||"AI generation failed");const v=JSON.parse(d.choices?.[0]?.message?.content||"{}");if(typeof v.body!=="string"||!v.body.trim())throw new Error("AI returned empty content");return v;
}
async function publish(item:any,keyText:string){
 const rows=await rest("cb_content_connections?user_id=eq."+item.user_id+"&platform=eq."+item.platform+"&status=eq.connected&select=*");
 const c=rows?.[0];if(!c)throw new Error("No connected "+item.platform+" account. Connect it in AI Studio.");
 const secret=await decrypt(c.access_token_ciphertext,keyText);
 if(item.platform==="wordpress"){
  const auth=btoa(c.account_name+":"+secret.replace(/\s+/g,""));
  const r=await fetch(c.site_url.replace(/\/$/,"")+"/wp-json/wp/v2/posts",{method:"POST",headers:{Authorization:"Basic "+auth,"Content-Type":"application/json"},body:JSON.stringify({title:item.title||item.topic,content:item.body,excerpt:item.excerpt,status:"publish"})});
  const d=await r.json();if(!r.ok)throw new Error(d?.message||"WordPress publish failed");return {id:String(d.id),url:d.link||null};
 }
 if(item.platform==="x"){
  const r=await fetch("https://api.x.com/2/tweets",{method:"POST",headers:{Authorization:"Bearer "+secret,"Content-Type":"application/json"},body:JSON.stringify({text:[item.body,(item.hashtags||[]).join(" ")].filter(Boolean).join("\n\n").slice(0,280)})});
  const d=await r.json();if(!r.ok)throw new Error(d?.detail||d?.title||"X publish failed");return {id:d.data?.id||null,url:d.data?.id?"https://x.com/i/status/"+d.data.id:null};
 }
 throw new Error("Publishing adapter is not available for "+item.platform+" yet.");
}
Deno.serve(async(req:Request)=>{
 if(req.method!=="POST")return json({error:"POST required"},405);
 const expected=Deno.env.get("CONTENT_WORKER_SECRET"),given=req.headers.get("x-worker-secret");
 if(!expected||!given||given!==expected)return json({error:"Unauthorized worker"},401);
 const apiKey=Deno.env.get("OPENAI_API_KEY"),keyText=Deno.env.get("CONTENT_ENCRYPTION_KEY");
 if(!apiKey||!keyText)return json({error:"Missing OPENAI_API_KEY or CONTENT_ENCRYPTION_KEY Edge Function secret."},503);
 const now=new Date().toISOString();let generated=0,published=0,failed=0;
 try{
  const due=await rest("cb_content_schedules?enabled=eq.true&next_run_at=lte."+encodeURIComponent(now)+"&select=*&order=next_run_at.asc&limit=25");
  for(const s of due||[]){
   try{
    const settingsRows=await rest("cb_content_settings?user_id=eq."+s.user_id+"&select=*");const settings=settingsRows?.[0]||{};
    if(settings.generation_enabled!==true){await rest("cb_content_schedules?id=eq."+s.id,{method:"PATCH",headers:{Prefer:"return=minimal"},body:JSON.stringify({next_run_at:nextOccurrence(s.publish_time,s.timezone,s.frequency,new Date())})});continue;}
    const dailyLimit=s.content_type==="article"?Number(settings.daily_article_limit??1):Number(settings.daily_social_limit??3);
    const countRows=await rest("cb_content_items?user_id=eq."+s.user_id+"&content_type=eq."+s.content_type+"&created_at=gte."+encodeURIComponent(new Date(Date.now()-86400000).toISOString())+"&select=id");
    if((countRows||[]).length>=dailyLimit){await rest("cb_content_schedules?id=eq."+s.id,{method:"PATCH",headers:{Prefer:"return=minimal"},body:JSON.stringify({next_run_at:nextOccurrence(s.publish_time,s.timezone,s.frequency,new Date())})});continue;}
    const v=await aiDraft(s,settings,apiKey);
    const status=settings.review_before_publish===false?"queued":"review";
    await rest("cb_content_items",{method:"POST",headers:{Prefer:"return=minimal"},body:JSON.stringify({user_id:s.user_id,content_type:s.content_type,platform:s.platform,topic:s.topic_prompt,title:String(v.title||"").slice(0,240),body:v.body,excerpt:String(v.excerpt||"").slice(0,500),hashtags:Array.isArray(v.hashtags)?v.hashtags.filter((x:any)=>typeof x==="string").slice(0,20):[],seo_title:String(v.seo_title||"").slice(0,240),seo_description:String(v.seo_description||"").slice(0,500),status,scheduled_at:status==="queued"?now:null})});
    await rest("cb_content_schedules?id=eq."+s.id,{method:"PATCH",headers:{Prefer:"return=minimal"},body:JSON.stringify({last_run_at:now,next_run_at:nextOccurrence(s.publish_time,s.timezone,s.frequency,new Date())})});generated++;
   }catch(e){failed++;await rest("cb_content_schedules?id=eq."+s.id,{method:"PATCH",headers:{Prefer:"return=minimal"},body:JSON.stringify({last_run_at:now,next_run_at:nextOccurrence(s.publish_time,s.timezone,s.frequency,new Date())})}).catch(()=>{});}
  }
  const queue=await rest("cb_content_items?status=eq.queued&scheduled_at=lte."+encodeURIComponent(now)+"&select=*&order=scheduled_at.asc&limit=20");
  for(const item of queue||[]){
   try{
    const lock=await rest("cb_content_items?id=eq."+item.id+"&status=eq.queued",{method:"PATCH",headers:{Prefer:"return=representation"},body:JSON.stringify({status:"publishing",updated_at:now})});
    if(!lock?.length)continue;
    const result=await publish(item,keyText);
    await rest("cb_content_items?id=eq."+item.id,{method:"PATCH",headers:{Prefer:"return=minimal"},body:JSON.stringify({status:"published",published_at:new Date().toISOString(),provider_post_id:result.id,last_error:null})});
    await rest("cb_content_publications?on_conflict=content_item_id,platform",{method:"POST",headers:{Prefer:"resolution=merge-duplicates,return=minimal"},body:JSON.stringify({content_item_id:item.id,user_id:item.user_id,platform:item.platform,status:"published",provider_post_id:result.id,response_data:result,attempts:1})});published++;
   }catch(e){
    failed++;const msg=e instanceof Error?e.message:"Publishing failed";
    await rest("cb_content_items?id=eq."+item.id,{method:"PATCH",headers:{Prefer:"return=minimal"},body:JSON.stringify({status:"failed",last_error:msg})}).catch(()=>{});
    await rest("cb_content_publications?on_conflict=content_item_id,platform",{method:"POST",headers:{Prefer:"resolution=merge-duplicates,return=minimal"},body:JSON.stringify({content_item_id:item.id,user_id:item.user_id,platform:item.platform,status:"failed",error_message:msg,attempts:1})}).catch(()=>{});
   }
  }
  return json({ok:true,generated,published,failed,checked_at:now});
 }catch(e){return json({error:e instanceof Error?e.message:"Worker failed"},500);}
});