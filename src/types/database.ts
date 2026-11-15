// Gerado por `npm run db:types` (supabase gen types). Não editar à mão.
// Placeholder até a primeira migration (S1): ainda não há tabelas no schema public.
export type Json = string | number | boolean | null | { [key: string]: Json | undefined } | Json[]

export type Database = {
  public: {
    Tables: Record<never, never>
    Views: Record<never, never>
    Functions: Record<never, never>
    Enums: Record<never, never>
    CompositeTypes: Record<never, never>
  }
}
