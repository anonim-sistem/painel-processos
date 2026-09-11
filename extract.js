// /api/extract.js
//
// Função de servidor (Vercel Function) que faz a leitura automática de um
// PDF/imagem de processo trabalhista usando a API do Google Gemini. Existe
// como função de servidor — e não como uma chamada direta do navegador para
// o Gemini — por um motivo simples: a chave da API (GEMINI_API_KEY) não
// pode aparecer no código do navegador, onde qualquer pessoa que abrir o
// "ver código-fonte" da página conseguiria vê-la e usá-la por conta própria.
// Aqui, a chave fica só nesta função, lida de uma variável de ambiente da
// Vercel — veja SETUP-GEMINI.md para o passo a passo de configuração.
//
// Além disso, esta função exige um token de sessão válido do Supabase
// (accessToken, enviado pelo painel) antes de chamar o Gemini — sem isso,
// qualquer pessoa que descobrisse o endereço desta função poderia gerar
// chamadas à API (e consumir sua cota gratuita) sem nem estar logada no
// painel.

var SUPABASE_URL = process.env.SUPABASE_URL || "https://xmeenareblcpmltudppd.supabase.co";
var SUPABASE_ANON_KEY = process.env.SUPABASE_ANON_KEY || "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InhtZWVuYXJlYmxjcG1sdHVkcHBkIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODkwNjI4MjYsImV4cCI6MjEwNDYzODgyNn0.VIy3AUTbINk4UsnRkneOaZiFLcqeTT20pNgBMp0M1L8";
// "gemini-2.5-flash" é um modelo estável e já bem estabelecido no momento em
// que este código foi escrito, com boa relação custo/benefício para este
// tipo de tarefa (ler um documento e devolver alguns campos) — e está na
// lista de modelos gratuitos do Gemini. Se quiser usar uma versão mais nova
// (ex.: "gemini-3.8-flash", se já existir uma quando você for configurar
// isso), não precisa mexer neste arquivo: basta definir a variável de
// ambiente GEMINI_MODEL na Vercel com o nome do modelo desejado.
var GEMINI_MODEL = process.env.GEMINI_MODEL || "gemini-2.5-flash";

// Mesmo limite usado no navegador (ver AI_EXTRACT_MAX_BYTES no painel) —
// checado de novo aqui como segunda camada de defesa, para nunca gastar uma
// chamada ao Gemini com um arquivo que já sabemos que é grande demais.
var MAX_FILE_BYTES = 3 * 1024 * 1024;

var EXTRACTION_PROMPT =
"Você está ajudando a preencher um sistema de controle de processos trabalhistas de uma empresa brasileira. " +
"O documento em anexo é uma petição, notificação, decisão ou outro documento de um processo trabalhista. " +
"Extraia as informações pedidas e responda SOMENTE com um objeto JSON válido, sem nenhum texto antes ou depois, no formato exato:\n" +
"{\n" +
'  "funcionario": string ou null,   // nome completo do reclamante/empregado\n' +
'  "empresa": string ou null,       // razão social da empresa reclamada\n' +
'  "cnpj": string ou null,          // CNPJ da empresa reclamada, formatado 00.000.000/0000-00 se encontrado\n' +
'  "numeroProcesso": string ou null,// número do processo no padrão CNJ (0000000-00.0000.0.00.0000)\n' +
'  "dataAudiencia": string ou null, // data da próxima audiência, formato YYYY-MM-DD\n' +
'  "dataAbertura": string ou null,  // data de ajuizamento (protocolo/distribuição) da ação na Justiça, formato YYYY-MM-DD\n' +
'  "valorProcesso": number ou null, // valor da causa em reais, apenas o número (ex: 15000.50)\n' +
'  "advogado": string ou null,      // nome do advogado responsável pela empresa, se identificável\n' +
'  "motivo": string                 // resumo objetivo em até 2 frases do motivo/pedidos principais do processo\n' +
"}\n" +
"Use null quando a informação não estiver presente no documento. Não invente dados.";

// Confirma que o token enviado pelo painel é de uma sessão Supabase real e
// ainda válida — chamando o próprio endpoint de autenticação do Supabase
// (GET /auth/v1/user), em vez de tentar validar o JWT aqui. Mais simples e
// sempre correto mesmo se o Supabase trocar a forma de assinar o token.
async function isValidSupabaseSession(accessToken) {
  if (!accessToken) return false;
  try {
    var res = await fetch(SUPABASE_URL + "/auth/v1/user", {
      headers: {
        apikey: SUPABASE_ANON_KEY,
        Authorization: "Bearer " + accessToken
      }
    });
    return res.ok;
  } catch (e) {
    return false;
  }
}

// Tira eventuais cercas de markdown ("```json ... ```") que o modelo às
// vezes inclui mesmo quando instruído a responder só com JSON — proteção
// extra além de response_mime_type: "application/json" (que já deveria
// impedir isso, mas providenciar os dois é mais robusto).
function parseJsonLoose(text) {
  var trimmed = String(text || "").trim();
  var fenced = trimmed.match(/```(?:json)?\s*([\s\S]*?)\s*```/i);
  if (fenced) trimmed = fenced[1].trim();
  return JSON.parse(trimmed);
}

module.exports = async function handler(req, res) {
  if (req.method !== "POST") {
    res.status(405).json({ error: "Método não permitido." });
    return;
  }

  if (!process.env.GEMINI_API_KEY) {
    console.error("GEMINI_API_KEY não configurada nas variáveis de ambiente da Vercel.");
    res.status(500).json({ error: "Leitura automática por IA não configurada no servidor (faltando GEMINI_API_KEY). Veja SETUP-GEMINI.md." });
    return;
  }

  var body = req.body;
  if (typeof body === "string") {
    try { body = JSON.parse(body); } catch (e) { body = null; }
  }
  if (!body || typeof body !== "object") {
    res.status(400).json({ error: "Requisição inválida." });
    return;
  }

  var fileBase64 = body.fileBase64;
  var mimeType = body.mimeType;
  var accessToken = body.accessToken;

  if (!fileBase64 || typeof fileBase64 !== "string") {
    res.status(400).json({ error: "Nenhum arquivo recebido." });
    return;
  }
  if (mimeType !== "application/pdf" && String(mimeType || "").indexOf("image/") !== 0) {
    res.status(400).json({ error: "Tipo de arquivo não suportado para leitura automática." });
    return;
  }
  // Tamanho aproximado do arquivo original a partir do comprimento da string
  // base64 (cada 4 caracteres codificam 3 bytes).
  var approxBytes = Math.floor(fileBase64.length * 3 / 4);
  if (approxBytes > MAX_FILE_BYTES) {
    res.status(413).json({ error: "Arquivo grande demais para leitura automática por IA." });
    return;
  }

  var authorized = await isValidSupabaseSession(accessToken);
  if (!authorized) {
    res.status(401).json({ error: "Sessão inválida ou expirada. Recarregue a página e entre novamente." });
    return;
  }

  try {
    var geminiUrl =
      "https://generativelanguage.googleapis.com/v1beta/models/" +
      encodeURIComponent(GEMINI_MODEL) +
      ":generateContent?key=" +
      encodeURIComponent(process.env.GEMINI_API_KEY);

    var geminiRes = await fetch(geminiUrl, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        contents: [
          {
            parts: [
              { text: EXTRACTION_PROMPT },
              { inline_data: { mime_type: mimeType, data: fileBase64 } }
            ]
          }
        ],
        generationConfig: {
          response_mime_type: "application/json",
          temperature: 0.1,
          maxOutputTokens: 1024
        }
      })
    });

    var geminiBody = await geminiRes.json().catch(function () { return null; });

    if (!geminiRes.ok) {
      var apiMsg = (geminiBody && geminiBody.error && geminiBody.error.message) || "";
      console.error("Erro da API do Gemini:", geminiRes.status, apiMsg);
      if (geminiRes.status === 429) {
        res.status(429).json({ error: "Muitas leituras automáticas agora (limite gratuito do Gemini atingido) — aguarde um pouco e tente de novo, ou preencha manualmente." });
      } else if (geminiRes.status === 400 || geminiRes.status === 403) {
        res.status(502).json({ error: "A chave do Gemini configurada no servidor parece inválida ou sem permissão. Verifique GEMINI_API_KEY na Vercel." });
      } else {
        res.status(502).json({ error: "Não foi possível ler o documento automaticamente agora. Preencha os campos manualmente." });
      }
      return;
    }

    var blockReason = geminiBody && geminiBody.promptFeedback && geminiBody.promptFeedback.blockReason;
    if (blockReason) {
      res.status(200).json({ error: "O Gemini não processou este documento (" + blockReason + "). Preencha os campos manualmente." });
      return;
    }

    var candidate = geminiBody && geminiBody.candidates && geminiBody.candidates[0];
    var text = candidate && candidate.content && candidate.content.parts && candidate.content.parts[0] && candidate.content.parts[0].text;
    if (!text) {
      res.status(200).json({ error: "A IA não retornou nenhum dado para este documento. Preencha os campos manualmente." });
      return;
    }

    var fields;
    try {
      fields = parseJsonLoose(text);
    } catch (e) {
      console.error("Resposta do Gemini não era um JSON válido:", text);
      res.status(200).json({ error: "A IA não retornou os dados num formato reconhecível. Tente novamente ou preencha manualmente." });
      return;
    }

    res.status(200).json({ fields: fields });
  } catch (e) {
    console.error("Falha ao chamar a API do Gemini:", e);
    res.status(502).json({ error: "Não foi possível contatar o serviço de leitura automática agora. Preencha os campos manualmente." });
  }
};
