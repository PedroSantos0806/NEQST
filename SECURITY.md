# Segurança

## Como avisar de um problema

Mande um e-mail para **ai.auroratech@gmail.com** com o assunto
`[NEQST] segurança`. Descreva o que dá para fazer e como reproduzir.

Não abra issue pública para falha de segurança: o NEQST roda num piloto
com usuários reais, e uma issue aberta é um aviso para quem quiser usar
a falha antes de ela ser corrigida.

Resposta em até 72 horas.

## O que é falha de segurança aqui

O que vale um aviso privado:

- ler, escrever ou apagar dados de outra pessoa;
- virar administrador, ou agir como a operação do parque sem ser;
- entrar numa fila, ocupar quadra ou passar a vez de alguém sem estar na
  quadra (a prova de presença é o QR mais o GPS);
- fazer o backend chamar um destino escolhido por você, ou vazar
  credencial do servidor;
- tirar o serviço do ar com uma requisição que qualquer pessoa consegue
  repetir.

O que **não** é, e pode ir em issue normal: a chave `anon` do Supabase
estar no bundle (é publicável por desenho, e o RLS é que protege os
dados), e o QR impresso ser legível por qualquer câmera (o que protege a
quadra é a conferência de distância, não o segredo do código).

## O que já se sabe

- O endereço e as coordenadas das quadras são públicos de propósito: é
  um app de quadra pública.
- Quem está logado vê o nome de exibição de quem está na fila. Quem
  **não** está logado vê só o primeiro nome e a inicial.
- A conta de administrador é única e criada pelo SQL Editor do Supabase,
  nunca pelo app.
