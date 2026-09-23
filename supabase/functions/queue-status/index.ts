/**
 * GET /functions/v1/queue-status?courtId=<uuid>   (US-03 / US-04)
 * GET /functions/v1/queue-status?slug=<slug>
 *
 * Fallback de polling para quando o WebSocket do Realtime cair.
 * Resposta cacheável por 10s (o app também cacheia a quadra por 60s).
 */
import {
  ApiError,
  corsHeaders,
  errorResponse,
  handlePreflight,
  postgrestError,
  requireMethod,
} from "../_shared/http.ts";
import { serviceClient } from "../_shared/supabase.ts";

Deno.serve(async (req) => {
  const preflight = handlePreflight(req);
  if (preflight) return preflight;

  try {
    requireMethod(req, "GET");

    const url = new URL(req.url);
    const courtIdParam = url.searchParams.get("courtId");
    const slug = url.searchParams.get("slug");

    if (!courtIdParam && !slug) {
      throw new ApiError("COURT_REQUIRED", "Informe courtId ou slug.", 400);
    }

    const admin = serviceClient();
    let courtId = courtIdParam;

    if (!courtId && slug) {
      const { data, error } = await admin
        .from("courts")
        .select("id")
        .eq("slug", slug)
        .maybeSingle();

      if (error) throw new ApiError("DATABASE_ERROR", error.message, 500);
      if (!data) throw new ApiError("COURT_NOT_FOUND", "Quadra não encontrada.", 404);
      courtId = data.id;
    }

    const { data, error } = await admin.rpc("court_queue", { p_court_id: courtId });
    if (error) postgrestError(error);

    return new Response(JSON.stringify(data), {
      status: 200,
      headers: {
        ...corsHeaders,
        "Content-Type": "application/json",
        "Cache-Control": "public, max-age=10",
      },
    });
  } catch (error) {
    return errorResponse(error);
  }
});
