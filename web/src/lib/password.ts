/**
 * A regra de senha do NEQST, escrita uma vez só.
 *
 * O pedido foi "mais simples: no mínimo 4, letras e números, podendo
 * ser PIN". Dois terços disso são nossos; o primeiro não é.
 *
 * O mínimo NÃO é escolha do app. O Supabase Auth eleva qualquer valor
 * abaixo de 6 ao chegar no servidor:
 *
 *     if config.Password.MinLength < defaultMinPasswordLength {
 *         config.Password.MinLength = defaultMinPasswordLength  // 6
 *     }
 *     — supabase/auth, internal/conf/configuration.go
 *
 * Então pedir 4 aqui só serviria para o cadastro ser aceito na tela e
 * recusado pelo servidor logo depois, com a mensagem em inglês. Seis é
 * o piso de verdade, e é o que esta regra usa.
 *
 * O resto do pedido vale inteiro: nada de exigir maiúscula, símbolo ou
 * mistura de tipos. "123456" passa — um PIN de seis dígitos é uma senha
 * válida aqui, de propósito, porque quem cadastra está de pé na quadra
 * com o celular na mão.
 */

/** O piso do Supabase Auth. Abaixo disto o servidor recusa. */
export const MIN_PASSWORD = 6;

/**
 * Letras sem acento e dígitos. Sem espaço, sem símbolo, sem acento:
 * no teclado do celular, no sol, é onde o erro de digitação mora — e
 * uma senha que a pessoa não consegue repetir é uma conta perdida.
 */
const ALLOWED = /^[A-Za-z0-9]+$/;

export type PasswordCheck = { ok: true } | { ok: false; message: string };

export function checkPassword(value: string): PasswordCheck {
  if (value.length < MIN_PASSWORD) {
    return {
      ok: false,
      message: `A senha precisa de pelo menos ${MIN_PASSWORD} caracteres. `
        + "Pode ser só números, como um PIN.",
    };
  }
  if (!ALLOWED.test(value)) {
    return {
      ok: false,
      message: "Use apenas letras sem acento e números — sem espaços, acentos ou símbolos.",
    };
  }
  return { ok: true };
}

/** A regra em uma linha, para a dica embaixo do campo. */
export const PASSWORD_HINT =
  `Pelo menos ${MIN_PASSWORD} caracteres, só letras e números. Pode ser um PIN de ${MIN_PASSWORD} dígitos.`;
