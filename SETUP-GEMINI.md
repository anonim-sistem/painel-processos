# Leitura automática de PDFs/imagens com Google Gemini

Este guia explica como ativar a leitura automática dos campos do formulário
ao anexar um PDF ou imagem de um processo. A extração é feita pela API
gratuita do Google Gemini (modelo Flash), chamada a partir de uma função de
servidor — nunca diretamente do navegador, para a chave da API nunca ficar
exposta.

## O que mudou no projeto

Antes, o painel era um único arquivo HTML, hospedável em qualquer lugar
(Netlify Drop incluído). Agora, para a leitura por IA funcionar, o projeto
passa a ter dois arquivos que precisam ficar juntos, na mesma pasta:

```
/painel-processos-supabase.html
/api/extract.js
```

O arquivo `api/extract.js` é uma função de servidor (não roda no navegador).
Isso exige um host que suporte funções de servidor — a Vercel é o mais
simples para esse formato, e é o que este guia cobre. Não dá mais para
simplesmente arrastar um único HTML para o Netlify Drop como antes.

## Passo 1: pegue uma chave gratuita do Gemini

Acesse o Google AI Studio em https://aistudio.google.com/apikey, entre com
uma conta Google, e clique em "Create API key". Copie a chave gerada — ela
começa com algo como `AIza...`. Guarde-a por enquanto, você vai colá-la na
Vercel no passo 3.

O nível gratuito do Gemini tem um limite de chamadas por minuto e por dia
(a Google ajusta esses números de tempos em tempos, então vale conferir a
página de limites do modelo escolhido se a leitura começar a falhar com
muita frequência). Para o volume de um painel interno de processos, isso
costuma ser mais do que suficiente.

## Passo 2: publique o projeto na Vercel

Se seu painel ainda não está na Vercel, a forma mais direta é pelo site:
entre em https://vercel.com, clique em "Add New" → "Project", e importe a
pasta do projeto (a Vercel aceita um repositório do GitHub/GitLab, ou você
pode instalar a Vercel CLI e rodar `vercel` dentro da pasta do projeto pelo
terminal, que também funciona sem precisar de um repositório Git). O
importante é que a pasta enviada contenha tanto o `painel-processos-supabase.html`
quanto a subpasta `api/` com o `extract.js` dentro — a Vercel detecta
automaticamente qualquer arquivo dentro de `api/` e o publica como uma
função de servidor, sem configuração extra.

Se o painel já está publicado na Vercel como projeto estático, é só enviar
de novo (novo deploy) já com a pasta `api/extract.js` incluída — a próxima
publicação passa a criar a função automaticamente.

## Passo 3: configure a chave na Vercel

Dentro do projeto na Vercel, vá em **Settings** → **Environment Variables**.
Adicione uma variável nova com o nome exatamente `GEMINI_API_KEY` e cole no
valor a chave copiada no passo 1. Marque os três ambientes (Production,
Preview, Development) para não ter surpresa depois. Clique em **Save**.

Depois de salvar a variável, é preciso fazer um novo deploy para ela
entrar em vigor — a Vercel não aplica variáveis de ambiente em deploys já
feitos. Vá em **Deployments**, abra os três pontinhos do último deploy, e
clique em **Redeploy** (ou simplesmente publique de novo).

## Variáveis opcionais

Por padrão o código usa o modelo `gemini-2.5-flash`. Se quiser trocar para
outra versão do Gemini no futuro, não precisa editar o código: crie também
uma variável `GEMINI_MODEL` com o nome do modelo desejado (por exemplo
`gemini-3.8-flash`, se essa versão já existir quando você for configurar
isso) e redeploy.

As variáveis `SUPABASE_URL` e `SUPABASE_ANON_KEY` também podem ser
configuradas na Vercel, mas isso é opcional — a função já tem as mesmas
credenciais do seu projeto Supabase como valor padrão dentro do código,
então funciona mesmo sem configurá-las à parte.

## Como testar se funcionou

Entre no painel publicado, abra um processo novo ou existente, e anexe um
PDF ou imagem de até 3 MB. Em poucos segundos os campos que a IA conseguir
identificar no documento devem se preencher sozinhos, com um destaque
visual indicando que foram preenchidos automaticamente. Campos que a IA não
encontrar continuam em branco para preenchimento manual — isso é esperado,
não é uma falha.

Se aparecer uma mensagem de erro em vez do preenchimento automático, o
texto da mensagem já indica a causa mais provável: chave não configurada,
chave inválida, arquivo grande demais, ou limite gratuito do Gemini
atingido no momento. Nesses casos o restante do painel continua funcionando
normalmente — só a leitura automática fica indisponível, e o formulário
pode sempre ser preenchido à mão.

## Por que o arquivo tem um limite de 3 MB

A função de servidor da Vercel tem um limite rígido de 4,5 MB por
requisição, que não muda entre planos. Como o arquivo é enviado codificado
em base64 (o que aumenta o tamanho em cerca de 33%), o painel limita a
leitura automática a arquivos de até 3 MB brutos, para sobrar margem
segura dentro desse teto. Esse limite vale só para a leitura automática —
o anexo do arquivo ao processo (que vai direto do navegador para o
Supabase Storage, sem passar por essa função) continua aceitando arquivos
maiores, do mesmo jeito de antes.

## Segurança

A chave `GEMINI_API_KEY` nunca aparece em nenhum código que roda no
navegador — ela existe só dentro da função de servidor, lida de uma
variável de ambiente. Além disso, a função exige que quem está chamando
tenha uma sessão válida e logada no painel (confere isso com o próprio
Supabase antes de acionar o Gemini), então mesmo que alguém descubra o
endereço da função, não consegue usá-la sem estar autenticado no sistema.
