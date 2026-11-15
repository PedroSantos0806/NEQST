export type Json =
  | string
  | number
  | boolean
  | null
  | { [key: string]: Json | undefined }
  | Json[]

export type Database = {
  // Allows to automatically instantiate createClient with right options
  // instead of createClient<Database, { PostgrestVersion: 'XX' }>(URL, KEY)
  __InternalSupabase: {
    PostgrestVersion: "14.18"
  }
  public: {
    Tables: {
      activities: {
        Row: {
          company_id: string | null
          contact_id: string | null
          created_at: string
          deal_id: string | null
          description: string | null
          done_at: string | null
          due_at: string | null
          id: string
          owner_id: string | null
          title: string
          type: Database["public"]["Enums"]["activity_type"]
          updated_at: string
        }
        Insert: {
          company_id?: string | null
          contact_id?: string | null
          created_at?: string
          deal_id?: string | null
          description?: string | null
          done_at?: string | null
          due_at?: string | null
          id?: string
          owner_id?: string | null
          title: string
          type?: Database["public"]["Enums"]["activity_type"]
          updated_at?: string
        }
        Update: {
          company_id?: string | null
          contact_id?: string | null
          created_at?: string
          deal_id?: string | null
          description?: string | null
          done_at?: string | null
          due_at?: string | null
          id?: string
          owner_id?: string | null
          title?: string
          type?: Database["public"]["Enums"]["activity_type"]
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "activities_company_id_fkey"
            columns: ["company_id"]
            isOneToOne: false
            referencedRelation: "companies"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "activities_contact_id_fkey"
            columns: ["contact_id"]
            isOneToOne: false
            referencedRelation: "contacts"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "activities_deal_id_fkey"
            columns: ["deal_id"]
            isOneToOne: false
            referencedRelation: "deals"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "activities_owner_id_fkey"
            columns: ["owner_id"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
        ]
      }
      companies: {
        Row: {
          cnpj: string | null
          created_at: string
          custom: Json
          id: string
          name: string
          owner_id: string | null
          type: Database["public"]["Enums"]["company_type"]
          updated_at: string
          website: string | null
        }
        Insert: {
          cnpj?: string | null
          created_at?: string
          custom?: Json
          id?: string
          name: string
          owner_id?: string | null
          type: Database["public"]["Enums"]["company_type"]
          updated_at?: string
          website?: string | null
        }
        Update: {
          cnpj?: string | null
          created_at?: string
          custom?: Json
          id?: string
          name?: string
          owner_id?: string | null
          type?: Database["public"]["Enums"]["company_type"]
          updated_at?: string
          website?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "companies_owner_id_fkey"
            columns: ["owner_id"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
        ]
      }
      contacts: {
        Row: {
          company_id: string | null
          created_at: string
          custom: Json
          email: string | null
          id: string
          job_title: string | null
          legal_basis: string | null
          lifecycle_stage: Database["public"]["Enums"]["lifecycle_stage"]
          meta_lead_id: string | null
          name: string
          owner_id: string | null
          phone: string | null
          source: string | null
          updated_at: string
          utm_campaign: string | null
          utm_content: string | null
          utm_medium: string | null
          utm_source: string | null
          utm_term: string | null
        }
        Insert: {
          company_id?: string | null
          created_at?: string
          custom?: Json
          email?: string | null
          id?: string
          job_title?: string | null
          legal_basis?: string | null
          lifecycle_stage?: Database["public"]["Enums"]["lifecycle_stage"]
          meta_lead_id?: string | null
          name: string
          owner_id?: string | null
          phone?: string | null
          source?: string | null
          updated_at?: string
          utm_campaign?: string | null
          utm_content?: string | null
          utm_medium?: string | null
          utm_source?: string | null
          utm_term?: string | null
        }
        Update: {
          company_id?: string | null
          created_at?: string
          custom?: Json
          email?: string | null
          id?: string
          job_title?: string | null
          legal_basis?: string | null
          lifecycle_stage?: Database["public"]["Enums"]["lifecycle_stage"]
          meta_lead_id?: string | null
          name?: string
          owner_id?: string | null
          phone?: string | null
          source?: string | null
          updated_at?: string
          utm_campaign?: string | null
          utm_content?: string | null
          utm_medium?: string | null
          utm_source?: string | null
          utm_term?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "contacts_company_id_fkey"
            columns: ["company_id"]
            isOneToOne: false
            referencedRelation: "companies"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "contacts_owner_id_fkey"
            columns: ["owner_id"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
        ]
      }
      custom_fields: {
        Row: {
          created_at: string
          entity: Database["public"]["Enums"]["timeline_entity"]
          field_type: Database["public"]["Enums"]["custom_field_type"]
          group_name: string | null
          id: string
          key: string
          label: string
          options: Json
          sort_order: number
          updated_at: string
        }
        Insert: {
          created_at?: string
          entity: Database["public"]["Enums"]["timeline_entity"]
          field_type?: Database["public"]["Enums"]["custom_field_type"]
          group_name?: string | null
          id?: string
          key: string
          label: string
          options?: Json
          sort_order?: number
          updated_at?: string
        }
        Update: {
          created_at?: string
          entity?: Database["public"]["Enums"]["timeline_entity"]
          field_type?: Database["public"]["Enums"]["custom_field_type"]
          group_name?: string | null
          id?: string
          key?: string
          label?: string
          options?: Json
          sort_order?: number
          updated_at?: string
        }
        Relationships: []
      }
      deal_contacts: {
        Row: {
          contact_id: string
          created_at: string
          deal_id: string
          id: string
          role: Database["public"]["Enums"]["deal_contact_role"] | null
          updated_at: string
        }
        Insert: {
          contact_id: string
          created_at?: string
          deal_id: string
          id?: string
          role?: Database["public"]["Enums"]["deal_contact_role"] | null
          updated_at?: string
        }
        Update: {
          contact_id?: string
          created_at?: string
          deal_id?: string
          id?: string
          role?: Database["public"]["Enums"]["deal_contact_role"] | null
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "deal_contacts_contact_id_fkey"
            columns: ["contact_id"]
            isOneToOne: false
            referencedRelation: "contacts"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "deal_contacts_deal_id_fkey"
            columns: ["deal_id"]
            isOneToOne: false
            referencedRelation: "deals"
            referencedColumns: ["id"]
          },
        ]
      }
      deal_locations: {
        Row: {
          created_at: string
          deal_id: string
          id: string
          location_id: string
          updated_at: string
        }
        Insert: {
          created_at?: string
          deal_id: string
          id?: string
          location_id: string
          updated_at?: string
        }
        Update: {
          created_at?: string
          deal_id?: string
          id?: string
          location_id?: string
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "deal_locations_deal_id_fkey"
            columns: ["deal_id"]
            isOneToOne: false
            referencedRelation: "deals"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "deal_locations_location_id_fkey"
            columns: ["location_id"]
            isOneToOne: false
            referencedRelation: "locations"
            referencedColumns: ["id"]
          },
        ]
      }
      deals: {
        Row: {
          closed_at: string | null
          company_id: string | null
          court_count: number | null
          created_at: string
          custom: Json
          expected_close_date: string | null
          id: string
          lost_note: string | null
          lost_reason_id: string | null
          owner_id: string | null
          pipeline_id: string
          position: number
          price_per_court: number | null
          source_deal_id: string | null
          stage_entered_at: string
          stage_id: string
          status: Database["public"]["Enums"]["deal_status"]
          title: string
          updated_at: string
          value: number | null
        }
        Insert: {
          closed_at?: string | null
          company_id?: string | null
          court_count?: number | null
          created_at?: string
          custom?: Json
          expected_close_date?: string | null
          id?: string
          lost_note?: string | null
          lost_reason_id?: string | null
          owner_id?: string | null
          pipeline_id: string
          position?: number
          price_per_court?: number | null
          source_deal_id?: string | null
          stage_entered_at?: string
          stage_id: string
          status?: Database["public"]["Enums"]["deal_status"]
          title: string
          updated_at?: string
          value?: number | null
        }
        Update: {
          closed_at?: string | null
          company_id?: string | null
          court_count?: number | null
          created_at?: string
          custom?: Json
          expected_close_date?: string | null
          id?: string
          lost_note?: string | null
          lost_reason_id?: string | null
          owner_id?: string | null
          pipeline_id?: string
          position?: number
          price_per_court?: number | null
          source_deal_id?: string | null
          stage_entered_at?: string
          stage_id?: string
          status?: Database["public"]["Enums"]["deal_status"]
          title?: string
          updated_at?: string
          value?: number | null
        }
        Relationships: [
          {
            foreignKeyName: "deals_company_id_fkey"
            columns: ["company_id"]
            isOneToOne: false
            referencedRelation: "companies"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "deals_lost_reason_id_fkey"
            columns: ["lost_reason_id"]
            isOneToOne: false
            referencedRelation: "lost_reasons"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "deals_owner_id_fkey"
            columns: ["owner_id"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "deals_pipeline_id_fkey"
            columns: ["pipeline_id"]
            isOneToOne: false
            referencedRelation: "pipelines"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "deals_source_deal_id_fkey"
            columns: ["source_deal_id"]
            isOneToOne: false
            referencedRelation: "deals"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "deals_stage_id_pipeline_id_fkey"
            columns: ["stage_id", "pipeline_id"]
            isOneToOne: false
            referencedRelation: "stages"
            referencedColumns: ["id", "pipeline_id"]
          },
        ]
      }
      locations: {
        Row: {
          address: string | null
          city: string | null
          company_id: string
          court_count: number | null
          created_at: string
          custom: Json
          has_internet: boolean | null
          id: string
          name: string
          state: string | null
          status: Database["public"]["Enums"]["location_status"]
          surfaces: string[]
          updated_at: string
        }
        Insert: {
          address?: string | null
          city?: string | null
          company_id: string
          court_count?: number | null
          created_at?: string
          custom?: Json
          has_internet?: boolean | null
          id?: string
          name: string
          state?: string | null
          status?: Database["public"]["Enums"]["location_status"]
          surfaces?: string[]
          updated_at?: string
        }
        Update: {
          address?: string | null
          city?: string | null
          company_id?: string
          court_count?: number | null
          created_at?: string
          custom?: Json
          has_internet?: boolean | null
          id?: string
          name?: string
          state?: string | null
          status?: Database["public"]["Enums"]["location_status"]
          surfaces?: string[]
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "locations_company_id_fkey"
            columns: ["company_id"]
            isOneToOne: false
            referencedRelation: "companies"
            referencedColumns: ["id"]
          },
        ]
      }
      lost_reasons: {
        Row: {
          active: boolean
          created_at: string
          id: string
          name: string
          sort_order: number
          updated_at: string
        }
        Insert: {
          active?: boolean
          created_at?: string
          id?: string
          name: string
          sort_order?: number
          updated_at?: string
        }
        Update: {
          active?: boolean
          created_at?: string
          id?: string
          name?: string
          sort_order?: number
          updated_at?: string
        }
        Relationships: []
      }
      notes: {
        Row: {
          attachments: Json
          author_id: string | null
          body: string
          company_id: string | null
          contact_id: string | null
          created_at: string
          deal_id: string | null
          id: string
          updated_at: string
        }
        Insert: {
          attachments?: Json
          author_id?: string | null
          body: string
          company_id?: string | null
          contact_id?: string | null
          created_at?: string
          deal_id?: string | null
          id?: string
          updated_at?: string
        }
        Update: {
          attachments?: Json
          author_id?: string | null
          body?: string
          company_id?: string | null
          contact_id?: string | null
          created_at?: string
          deal_id?: string | null
          id?: string
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "notes_author_id_fkey"
            columns: ["author_id"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "notes_company_id_fkey"
            columns: ["company_id"]
            isOneToOne: false
            referencedRelation: "companies"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "notes_contact_id_fkey"
            columns: ["contact_id"]
            isOneToOne: false
            referencedRelation: "contacts"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "notes_deal_id_fkey"
            columns: ["deal_id"]
            isOneToOne: false
            referencedRelation: "deals"
            referencedColumns: ["id"]
          },
        ]
      }
      pipelines: {
        Row: {
          created_at: string
          id: string
          name: string
          sort_order: number
          type: Database["public"]["Enums"]["pipeline_type"]
          updated_at: string
        }
        Insert: {
          created_at?: string
          id?: string
          name: string
          sort_order: number
          type: Database["public"]["Enums"]["pipeline_type"]
          updated_at?: string
        }
        Update: {
          created_at?: string
          id?: string
          name?: string
          sort_order?: number
          type?: Database["public"]["Enums"]["pipeline_type"]
          updated_at?: string
        }
        Relationships: []
      }
      profiles: {
        Row: {
          avatar_url: string | null
          created_at: string
          email: string | null
          full_name: string | null
          id: string
          role: Database["public"]["Enums"]["app_role"]
          updated_at: string
        }
        Insert: {
          avatar_url?: string | null
          created_at?: string
          email?: string | null
          full_name?: string | null
          id: string
          role?: Database["public"]["Enums"]["app_role"]
          updated_at?: string
        }
        Update: {
          avatar_url?: string | null
          created_at?: string
          email?: string | null
          full_name?: string | null
          id?: string
          role?: Database["public"]["Enums"]["app_role"]
          updated_at?: string
        }
        Relationships: []
      }
      stages: {
        Row: {
          alert_days: number | null
          created_at: string
          exit_criteria: string | null
          id: string
          name: string
          pipeline_id: string
          probability: number | null
          required_fields: Json
          sort_order: number
          updated_at: string
        }
        Insert: {
          alert_days?: number | null
          created_at?: string
          exit_criteria?: string | null
          id?: string
          name: string
          pipeline_id: string
          probability?: number | null
          required_fields?: Json
          sort_order: number
          updated_at?: string
        }
        Update: {
          alert_days?: number | null
          created_at?: string
          exit_criteria?: string | null
          id?: string
          name?: string
          pipeline_id?: string
          probability?: number | null
          required_fields?: Json
          sort_order?: number
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "stages_pipeline_id_fkey"
            columns: ["pipeline_id"]
            isOneToOne: false
            referencedRelation: "pipelines"
            referencedColumns: ["id"]
          },
        ]
      }
      timeline_events: {
        Row: {
          actor_id: string | null
          created_at: string
          entity: Database["public"]["Enums"]["timeline_entity"]
          entity_id: string
          id: string
          occurred_at: string
          payload: Json
          type: Database["public"]["Enums"]["timeline_event_type"]
          updated_at: string
        }
        Insert: {
          actor_id?: string | null
          created_at?: string
          entity: Database["public"]["Enums"]["timeline_entity"]
          entity_id: string
          id?: string
          occurred_at?: string
          payload?: Json
          type: Database["public"]["Enums"]["timeline_event_type"]
          updated_at?: string
        }
        Update: {
          actor_id?: string | null
          created_at?: string
          entity?: Database["public"]["Enums"]["timeline_entity"]
          entity_id?: string
          id?: string
          occurred_at?: string
          payload?: Json
          type?: Database["public"]["Enums"]["timeline_event_type"]
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "timeline_events_actor_id_fkey"
            columns: ["actor_id"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
        ]
      }
    }
    Views: {
      [_ in never]: never
    }
    Functions: {
      create_onboarding_deal: {
        Args: { p_source: Database["public"]["Tables"]["deals"]["Row"] }
        Returns: undefined
      }
      log_timeline: {
        Args: {
          p_entity: Database["public"]["Enums"]["timeline_entity"]
          p_entity_id: string
          p_payload?: Json
          p_type: Database["public"]["Enums"]["timeline_event_type"]
        }
        Returns: undefined
      }
    }
    Enums: {
      activity_type:
        | "task"
        | "call"
        | "meeting"
        | "visit"
        | "whatsapp"
        | "email"
      app_role: "admin" | "member"
      company_type: "public_operator" | "club" | "condo" | "builder" | "brand"
      custom_field_type:
        | "text"
        | "number"
        | "date"
        | "boolean"
        | "select"
        | "multiselect"
      deal_contact_role: "decision_maker" | "influencer" | "operational"
      deal_status: "open" | "won" | "lost"
      lifecycle_stage: "lead" | "qualified_lead" | "opportunity" | "customer"
      location_status: "prospect" | "pilot" | "client"
      pipeline_type: "sales" | "onboarding"
      timeline_entity: "deal" | "contact" | "company" | "location"
      timeline_event_type:
        | "created"
        | "stage_change"
        | "status_change"
        | "note"
        | "activity_done"
        | "conversion"
        | "whatsapp_in"
        | "whatsapp_out"
        | "email_out"
        | "email_in"
    }
    CompositeTypes: {
      [_ in never]: never
    }
  }
}

type DatabaseWithoutInternals = Omit<Database, "__InternalSupabase">

type DefaultSchema = DatabaseWithoutInternals[Extract<keyof Database, "public">]

export type Tables<
  DefaultSchemaTableNameOrOptions extends
    | keyof (DefaultSchema["Tables"] & DefaultSchema["Views"])
    | { schema: keyof DatabaseWithoutInternals },
  TableName extends (DefaultSchemaTableNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof (DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"] &
        DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Views"])
    : never) = never,
> = DefaultSchemaTableNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? (DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"] &
      DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Views"])[TableName] extends {
      Row: infer R
    }
    ? R
    : never
  : DefaultSchemaTableNameOrOptions extends keyof (DefaultSchema["Tables"] &
        DefaultSchema["Views"])
    ? (DefaultSchema["Tables"] &
        DefaultSchema["Views"])[DefaultSchemaTableNameOrOptions] extends {
        Row: infer R
      }
      ? R
      : never
    : never

export type TablesInsert<
  DefaultSchemaTableNameOrOptions extends
    | keyof DefaultSchema["Tables"]
    | { schema: keyof DatabaseWithoutInternals },
  TableName extends (DefaultSchemaTableNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"]
    : never) = never,
> = DefaultSchemaTableNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"][TableName] extends {
      Insert: infer I
    }
    ? I
    : never
  : DefaultSchemaTableNameOrOptions extends keyof DefaultSchema["Tables"]
    ? DefaultSchema["Tables"][DefaultSchemaTableNameOrOptions] extends {
        Insert: infer I
      }
      ? I
      : never
    : never

export type TablesUpdate<
  DefaultSchemaTableNameOrOptions extends
    | keyof DefaultSchema["Tables"]
    | { schema: keyof DatabaseWithoutInternals },
  TableName extends (DefaultSchemaTableNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"]
    : never) = never,
> = DefaultSchemaTableNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"][TableName] extends {
      Update: infer U
    }
    ? U
    : never
  : DefaultSchemaTableNameOrOptions extends keyof DefaultSchema["Tables"]
    ? DefaultSchema["Tables"][DefaultSchemaTableNameOrOptions] extends {
        Update: infer U
      }
      ? U
      : never
    : never

export type Enums<
  DefaultSchemaEnumNameOrOptions extends
    | keyof DefaultSchema["Enums"]
    | { schema: keyof DatabaseWithoutInternals },
  EnumName extends (DefaultSchemaEnumNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[DefaultSchemaEnumNameOrOptions["schema"]]["Enums"]
    : never) = never,
> = DefaultSchemaEnumNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? DatabaseWithoutInternals[DefaultSchemaEnumNameOrOptions["schema"]]["Enums"][EnumName]
  : DefaultSchemaEnumNameOrOptions extends keyof DefaultSchema["Enums"]
    ? DefaultSchema["Enums"][DefaultSchemaEnumNameOrOptions]
    : never

export type CompositeTypes<
  PublicCompositeTypeNameOrOptions extends
    | keyof DefaultSchema["CompositeTypes"]
    | { schema: keyof DatabaseWithoutInternals },
  CompositeTypeName extends (PublicCompositeTypeNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[PublicCompositeTypeNameOrOptions["schema"]]["CompositeTypes"]
    : never) = never,
> = PublicCompositeTypeNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? DatabaseWithoutInternals[PublicCompositeTypeNameOrOptions["schema"]]["CompositeTypes"][CompositeTypeName]
  : PublicCompositeTypeNameOrOptions extends keyof DefaultSchema["CompositeTypes"]
    ? DefaultSchema["CompositeTypes"][PublicCompositeTypeNameOrOptions]
    : never

export const Constants = {
  public: {
    Enums: {
      activity_type: ["task", "call", "meeting", "visit", "whatsapp", "email"],
      app_role: ["admin", "member"],
      company_type: ["public_operator", "club", "condo", "builder", "brand"],
      custom_field_type: [
        "text",
        "number",
        "date",
        "boolean",
        "select",
        "multiselect",
      ],
      deal_contact_role: ["decision_maker", "influencer", "operational"],
      deal_status: ["open", "won", "lost"],
      lifecycle_stage: ["lead", "qualified_lead", "opportunity", "customer"],
      location_status: ["prospect", "pilot", "client"],
      pipeline_type: ["sales", "onboarding"],
      timeline_entity: ["deal", "contact", "company", "location"],
      timeline_event_type: [
        "created",
        "stage_change",
        "status_change",
        "note",
        "activity_done",
        "conversion",
        "whatsapp_in",
        "whatsapp_out",
        "email_out",
        "email_in",
      ],
    },
  },
} as const
