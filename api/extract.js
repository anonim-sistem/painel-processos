import { GoogleGenAI } from '@google/genai';

export default async function handler(req, res) {
  if (req.method !== 'POST') {
    return res.status(405).json({ error: 'Método não permitido. Use POST.' });
  }

  try {
    const { pdfBase64, prompt } = req.body;

    if (!pdfBase64) {
      return res.status(400).json({ error: 'Nenhum arquivo PDF em formato base64 foi enviado.' });
    }

    const apiKey = process.env.GEMINI_API_KEY;
    if (!apiKey) {
      return res.status(500).json({ error: 'Chave GEMINI_API_KEY não configurada nas variáveis de ambiente da Vercel.' });
    }

    const ai = new GoogleGenAI({ apiKey });

    // Prepara o payload do PDF para o Gemini
    const pdfPart = {
      inlineData: {
        data: pdfBase64,
        mimeType: 'application/pdf',
      },
    };

    const defaultPrompt = prompt || "Extraia os principais dados deste processo jurídico em formato JSON estruturado (número do processo, partes envolvidas, tribunal, resumo e movimentações).";

    const response = await ai.models.generateContent({
      model: 'gemini-2.5-flash',
      contents: [pdfPart, defaultPrompt],
    });

    return res.status(200).json({ 
      success: true, 
      result: response.text 
    });

  } catch (error) {
    console.error('Erro na extração com Gemini:', error);
    return res.status(500).json({ 
      error: 'Erro interno ao processar o PDF com a API do Gemini.',
      details: error.message 
    });
  }
}
