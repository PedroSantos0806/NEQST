# Arquitetura

## Por que Supabase

O documento da Sprint 1 recomenda Supabase ou Firebase. A escolha foi
Supabase por três razões ligadas aos critérios de aceite:

1. **Realtime sobre Postgres** entrega a fila via WebSocket sem worker
   extra — o critério "atualiza em tempo real (WebSocket ou polling a
   cada 10s)" sai na opção boa, e não na de contingência.
2. **Regras no banco.** Ordem da fila, unicidade e presença validada são
   restrições relacionais. Em Postgres isso vira índice único e função
   transacional; em Firestore viraria código de aplicação com corrida.
3. **Auth pronto** com Google e Apple SSO (US-01), exigidos pelas lojas.

## Camadas

```
App Expo (React Native)
   │
   ├── supabase-js ──► PostgREST / RPC          leitura e operações simples
   ├── supabase-js ──► Realtime (WebSocket)     fila ao vivo
   └── fetch ────────► Edge Functions (Deno)    tudo que precisa de segredo
                            │
                            ▼
                    Postgres + RLS + triggers
                            │
                            ▼
              notification_outbox ──► Expo Push ──► FCM / APNs
```

O que passa por Edge Function é o que **não pode** rodar no cliente:
verificar a assinatura do QR Code (exige o segredo), decidir se a
distância é aceitável, emitir o scan token e falar com a Expo Push API.
Todo o resto é RPC direto, com menos round-trips — importante no 3G
instável que a sprint chama atenção.

## O fluxo de entrar na fila

```
 App                    scan-court              Postgres            join-queue
  │  QR + GPS (one-shot)     │                      │                    │
  ├─────────────────────────►│                      │                    │
  │                          │ verifica HMAC        │                    │
  │                          │ Haversine ≤ raio     │                    │
  │                          ├─ insere scan_token ─►│                    │
  │◄── scanToken (30s) ──────┤                      │                    │
  │                                                                      │
  │  scanToken + modo + parceiro                                         │
  ├─────────────────────────────────────────────────────────────────────►│
  │                                                  ┌── join_queue() ◄──┤
  │                                                  │  token válido?    │
  │                                                  │  já está na fila? │
  │                                                  │  cria time        │
  │                                                  │  consome token    │
  │◄──────────── posição, times na frente, espera ───┴───────────────────┤
  │                                                                      │
  │◄═══ Realtime: todos na quadra recebem o novo estado ═════════════════╡
```

## Decisões e trade-offs

**Scan token em vez de QR rotativo.** Um QR dinâmico exigiria tela na
quadra. O código impresso é estático; a janela de 30s fica no token
emitido após validar a presença. Mesmo efeito prático, custo zero de
hardware.

**Escrita da fila só por RPC.** O cliente tem `SELECT` nas tabelas da fila
e nada mais. Assim o app pode ler direto (rápido, e o Realtime funciona),
mas não tem como furar fila nem forjar presença.

**Outbox de notificações.** O push não é enviado dentro da transação: o
gatilho grava na `notification_outbox` e um worker entrega. Se a Expo cair,
a transação da fila não falha e a notificação sai depois.

**Tempo estimado simples.** `times_na_frente × duração_média_da_quadra`,
somado ao tempo restante da partida em andamento. Sem histórico (Sprint 2),
essa é a melhor estimativa disponível — e `average_match_minutes` é
configurável por quadra.

**Posição por `joined_at`.** Ordem de chegada pura, sem prioridades. É o
que o critério de aceite descreve.

## Resiliência em sinal fraco

- Fila via WebSocket com reconexão automática do `supabase-js`; ao
  reconectar, chame `court_queue` para ressincronizar.
- `queue-status` como fallback HTTP cacheável (10s) se o WebSocket não
  subir.
- `my_active_entries()` devolve os times ativos do usuário — é o que o app
  chama ao abrir para se recuperar de uma queda no meio do fluxo.
- Dados da quadra podem ser cacheados 60s no device (US-04); a fila, não.

## O que fica para a Sprint 2

Histórico de partidas, avaliação da quadra, fotos e mapa de calor. O
schema já ajuda: `queue_entries` guarda `started_at`/`ended_at` de cada
partida, então o histórico é uma consulta sobre dados que já estarão lá.
