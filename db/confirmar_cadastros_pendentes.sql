-- Confirma à mão os cadastros que ficaram presos esperando um e-mail
-- que não chegou.
--
-- QUANDO USAR
--   Você desligou "Confirm email" no painel (Authentication ›
--   Sign In / Providers › Email) e as contas criadas ANTES disso
--   continuam sem conseguir entrar, com "Sua conta ainda não foi
--   confirmada". Desligar a confirmação vale para cadastro novo; não
--   volta atrás nos que já existem. É o caso típico depois de estourar
--   o limite do e-mail nativo: a conta foi criada, o e-mail não saiu.
--
-- O QUE ISSO SIGNIFICA
--   Você está declarando que esses endereços estão bons sem que
--   ninguém tenha clicado no link. Com a confirmação desligada, é a
--   mesma garantia que o cadastro novo passa a ter — nenhuma. Em troca,
--   ninguém fica trancado fora. Se um dia religar a confirmação,
--   configure o SMTP próprio antes (docs/auth.md § 2).
--
-- COMO RODAR
--   SQL Editor do Supabase. Os dois passos são separados de propósito:
--   olhe a lista antes de confirmar.

-- ---------------------------------------------------------------
-- Passo 1 — quem está pendente
-- ---------------------------------------------------------------
select
  u.email,
  u.created_at,
  -- Quem entrou pelo Google nunca aparece aqui: o provedor já garantiu
  -- o endereço e a conta nasce confirmada.
  coalesce(u.raw_user_meta_data ->> 'full_name', '(sem nome)') as nome
from auth.users u
where u.email_confirmed_at is null
order by u.created_at;

-- ---------------------------------------------------------------
-- Passo 2 — confirmar
-- ---------------------------------------------------------------
-- `confirmed_at` é coluna gerada pelo próprio Supabase: não se escreve
-- nela, ela acompanha o `email_confirmed_at`.
update auth.users
   set email_confirmed_at = now()
 where email_confirmed_at is null;

-- Para confirmar uma pessoa só, troque o passo 2 por:
--
--   update auth.users
--      set email_confirmed_at = now()
--    where email = 'pessoa@exemplo.com'
--      and email_confirmed_at is null;
