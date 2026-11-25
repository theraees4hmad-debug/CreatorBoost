const cors = {
  "Access-Control-Allow-Origin": "https://theraees4hmad-debug.github.io",
  "Access-Control-Allow-Headers": "authorization, apikey, content-type, x-client-info",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Content-Type": "application/json"
};
const json = (body: unknown, status = 200) => new Response(JSON.stringify(body), { status, headers: cors });
const allowedPlatforms = new Set(["website","wordpress","x","facebook","instagram","tiktok","youtube"]);

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ error: "Method not allowed" }, 405);

  const authorization = req.headers.get("Authorization") || "";
  if (!authorization.startsWith("Bearer ")) return json({ error: "Please sign in first." }, 401);

  const base = Deno.env.get("SUPABASE_URL");
  const anon = Deno.env.get("SUPABASE_ANON_KEY");
  const service = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  const openai = Deno.env.get("OPENAI_API_KEY");
  if (!base || !anon || !service) return json({ error: "Content service is not configured." }, 503);
  if (!openai) return json({ error: "AI generation is not enabled yet. Add OPENAI_API_KEY to Supabase Edge Function secrets." }, 503);

  const userResponse = await fetch(base + "/auth/v1/user", {
    headers: { apikey: anon, Authorization: authorization }
  });
  if (!userResponse.ok) return json({ error: "Your session expired. Please sign in again." }, 401);
  const user = await userResponse.json();

  let input: Record<string, unknown>;
  try { input = await req.json(); } catch { return json({ error: "Invalid JSON body." }, 400); }

  const contentType = input.content_type === "article" ? "article" : input.content_type === "social" ? "social" : null;
  const platform = typeof input.platform === "string" ? input.platform : "website";
  const topic = typeof input.topic === "string" ? input.topic.trim() : "";
  if (!contentType || !allowedPlatforms.has(platform) || topic.length < 4 || topic.length > 240) {
    return json({ error: "Choose an article or social post, a supported platform, and a topic between 4 and 240 characters." }, 400);
  }

  const niche = typeof input.niche === "string" ? input.niche.slice(0, 120) : "";
  const audience = typeof input.audience === "string" ? input.audience.slice(0, 160) : "";
  const tone = typeof input.tone === "string" ? input.tone.slice(0, 60) : "energetic";
  const language = typeof input.language === "string" ? input.language.slice(0, 40) : "English";
  const keywords = Array.isArray(input.keywords) ? input.keywords.filter(x => typeof x === "string").slice(0, 10).join(", ") : "";
  const cta = typeof input.cta === "string" ? input.cta.slice(0, 180) : "";

  const format = contentType === "article"
    ? { title: "string", body: "string (Markdown, 700-1000 words)", excerpt: "string", seo_title: "string", seo_description: "string", hashtags: ["string"] }
    : { title: "string", body: "string (platform-appropriate post copy)", excerpt: "string", seo_title: "string", seo_description: "string", hashtags: ["string"] };

  const prompt = [
    "Create original creator-focused marketing content. Return only valid JSON matching this shape: " + JSON.stringify(format) + ".",
    "Content type: " + contentType + ". Target platform: " + platform + ".",
    "Topic: " + topic + ". Creator niche: " + (niche || "streaming and gaming") + ".",
    "Audience: " + (audience || "fans and potential viewers") + ". Tone: " + tone + ". Language: " + language + ".",
    "SEO keywords: " + keywords + ". Call to action: " + cta + ".",
    "Do not invent statistics, quotes, news, sources, game updates, or factual claims. If a fact needs current verification, phrase it cautiously or flag it for editorial review.",
    "Avoid keyword stuffing, fake engagement claims, misleading headlines, copied text, and platform policy violations.",
    contentType === "article"
      ? "Write a useful, structured article with H2/H3 headings, practical detail, a concise intro and conclusion. Do not claim it is researched or fact-checked."
      : "Write a native-feeling post, not an article. Keep it concise and include relevant hashtags without spam."
  ].join("\n");

  const aiResponse = await fetch("https://api.openai.com/v1/chat/completions", {
    method: "POST",
    headers: { Authorization: "Bearer " + openai, "Content-Type": "application/json" },
    body: JSON.stringify({
      model: "gpt-4o-mini",
      temperature: 0.7,
      response_format: { type: "json_object" },
      messages: [
        { role: "system", content: "You are CreatorBoost's careful content editor. Return valid JSON only." },
        { role: "user", content: prompt }
      ]
    })
  });
  const aiData = await aiResponse.json();
  if (!aiResponse.ok) return json({ error: aiData?.error?.message || "AI provider request failed." }, 502);

  let generated: Record<string, unknown>;
  try {
    generated = JSON.parse(aiData.choices?.[0]?.message?.content || "{}");
  } catch {
    return json({ error: "AI returned an invalid content format. Please retry." }, 502);
  }
  const title = typeof generated.title === "string" ? generated.title.slice(0, 240) : "";
  const body = typeof generated.body === "string" ? generated.body : "";
  if (!body.trim()) return json({ error: "AI did not return usable content. Please retry." }, 502);

  const hashtags = Array.isArray(generated.hashtags)
    ? generated.hashtags.filter(x => typeof x === "string").slice(0, 20)
    : [];
  const row = {
    user_id: user.id,
    content_type: contentType,
    platform,
    topic,
    title,
    body,
    excerpt: typeof generated.excerpt === "string" ? generated.excerpt.slice(0, 500) : "",
    hashtags,
    seo_title: typeof generated.seo_title === "string" ? generated.seo_title.slice(0, 240) : "",
    seo_description: typeof generated.seo_description === "string" ? generated.seo_description.slice(0, 500) : "",
    status: "draft"
  };
  const save = await fetch(base + "/rest/v1/cb_content_items?select=id,content_type,platform,topic,title,body,excerpt,hashtags,seo_title,seo_description,status,created_at", {
    method: "POST",
    headers: {
      apikey: service,
      Authorization: "Bearer " + service,
      "Content-Type": "application/json",
      Prefer: "return=representation"
    },
    body: JSON.stringify(row)
  });
  if (!save.ok) return json({ error: "Content was generated but could not be saved." }, 500);
  const saved = await save.json();
  return json({ item: saved[0] });
});
