# Painel de Processos Trabalhistas — configuração com Supabase

Este pacote contém a versão do painel com backend real (banco de dados +
autenticação) via [Supabase](https://supabase.com). Diferente do link
publicado como Artifact no Claude, este é um arquivo HTML autônomo: você
mesmo hospeda (Netlify, Vercel, GitHub Pages, servidor interno da empresa
etc.) e ele fala diretamente com o seu projeto Supabase.

Arquivos deste pacote:

- `painel-processos-supabase.html` — o painel em si (abra num navegador ou publique num host estático).
- `api/extract.js` — função de servidor para a leitura automática de documentos por IA (Gemini); veja `SETUP-GEMINI.md`.
- `supabase_schema.sql` — o esquema completo do banco (tabelas, RLS, gatilhos de auditoria).
- `SETUP-SUPABASE.md` — este guia.
- `SETUP-GEMINI.md` — guia específico da leitura automática por IA e da publicação na Vercel.

## Por que isto é um arquivo separado, e não uma atualização do link publicado no Claude?

Uma página publicada como Artifact no Claude roda dentro de um ambiente
isolado (sandbox) que **bloqueia chamadas de rede para qualquer servidor
externo**, exceto o carregamento de bibliotecas JavaScript de alguns
provedores específicos. Um backend real como o Supabase precisa fazer
chamadas de rede constantes ao seu próprio servidor — login,
leitura/gravação no banco, upload de arquivos — e essas chamadas são
bloqueadas nesse ambiente. Por isso, autenticação e banco de dados reais só
funcionam num arquivo hospedado por você mesmo, fora do Claude.

## O painel já vem configurado com o seu projeto

As credenciais que você enviou já estão preenchidas no arquivo
`painel-processos-supabase.html` (procure por `SUPABASE_URL` e
`SUPABASE_ANON_KEY` perto do início do bloco `<script>`, logo abaixo do
comentário "configuração do Supabase"):

```js
var SUPABASE_URL = "https://xmeenareblcpmltudppd.supabase.co";
var SUPABASE_ANON_KEY = "eyJhbGciOiJIUzI1NiIs...";
var SUPABASE_STORAGE_BUCKET = "documentos-trabalhistas";
```

> A chave "anon" não é secreta no sentido de senha — ela é feita para ficar
> visível no navegador de quem usa o painel. Quem realmente impede acessos
> indevidos são as regras de segurança (RLS) criadas em `supabase_schema.sql`,
> não o sigilo desta chave. Ainda assim, evite publicar este arquivo num
> repositório público (GitHub, etc.) sem necessidade — prefira um host
> privado ou um repositório privado.

Se um dia precisar apontar o painel para outro projeto Supabase, basta
trocar esses três valores e salvar o arquivo de novo.

## Passo a passo para colocar no ar

### 1. Rode o esquema do banco

No painel do seu projeto Supabase (o mesmo cujo Project URL está acima),
abra **SQL Editor** → **New query**, cole todo o conteúdo do arquivo
`supabase_schema.sql` deste pacote, e clique em **Run**. Isso cria:

- a tabela `cases` (os processos) e `case_files` (metadados dos anexos, com a categoria/"tag" de cada documento);
- a tabela `profiles`, com o papel de cada usuário (`ADM` ou `Operador`);
- as regras de segurança (Row Level Security), que restringem **todo** o
  acesso — leitura, cadastro, edição e exclusão — a usuários autenticados
  (`auth.uid() is not null`), e além disso impedem, **no próprio banco de
  dados**, que qualquer usuário sem o papel `ADM` consiga excluir um
  processo — mesmo que alguém tente contornar a tela;
- o log de auditoria (`audit_log`), preenchido automaticamente por
  gatilhos do banco a cada processo cadastrado, alterado ou excluído,
  guardando um retrato completo do processo antes/depois da mudança — não
  existe nenhum código no navegador que grave esse log, então não há como
  forjar ou apagar um registro alterando o JavaScript da página.

Se você já rodou uma versão anterior deste schema neste projeto (por
exemplo, sem a coluna `tag` ou sem os retratos de auditoria), pode rodar o
arquivo de novo sem problema — todos os comandos usam
`create table if not exists`, `create or replace function` etc., então é
seguro reaplicar.

### 2. Crie o bucket de arquivos

No menu lateral, vá a **Storage** → **New bucket**. Nome:
**`documentos-trabalhistas`** (exatamente assim — é o nome que o painel usa
para se conectar ao bucket). Deixe **Public bucket** DESMARCADO — o bucket
precisa ser privado: o painel usa links assinados e temporários (válidos
por 60 segundos) para cada visualização/download, em vez de expor os
documentos com uma URL pública fixa. As políticas de acesso a esse bucket
já foram criadas pelo script SQL do passo 1.

### 3. Crie o primeiro usuário administrador (ADM)

Vá a **Authentication** → **Users** → **Add user** → **Create new user**, e
cadastre o e-mail e a senha da primeira pessoa que vai administrar o painel
(normalmente você mesmo). **Não existe cadastro aberto pelo próprio
painel** — a tela de login só permite entrar com uma conta já criada; só um
administrador cria contas, pela mesma tela do Supabase.

Por padrão, todo novo usuário entra com o papel `Operador` (pode ver,
cadastrar, editar e anexar arquivos, mas não excluir processos). Para
tornar esta primeira conta administradora, volte ao **SQL Editor** e rode
(trocando o e-mail pelo que você acabou de cadastrar):

```sql
update public.profiles set role = 'ADM' where email = 'voce@empresa.com';
```

Repita esse mesmo comando sempre que quiser promover outra conta a
administradora. Para cadastrar mais pessoas da equipe, repita o passo
"Add user" — cada uma entra por padrão como Operador, e só quem for
promovido por este comando SQL pode excluir processos.

### 4. Publique o painel

Se você quiser usar a leitura automática de documentos por IA (Gemini),
publique com a Vercel seguindo o `SETUP-GEMINI.md` deste pacote — esse
recurso depende de uma função de servidor que só funciona nesse formato de
publicação. Sem esse recurso, `painel-processos-supabase.html` continua
sendo um arquivo autônomo comum, publicável em qualquer serviço de site
estático ([Netlify Drop](https://app.netlify.com/drop), GitHub Pages, o
servidor da empresa etc.) — nesse caso os campos são só preenchidos
manualmente.

Depois de publicado, compartilhe o link só com quem deve ter acesso — o
controle de quem pode ver/editar/excluir continua sendo feito pelas contas
criadas no passo 3, não pelo link em si, e o arquivo já inclui `<meta
name="robots" content="noindex, nofollow">` no cabeçalho para que
buscadores (Google, Bing etc.) não indexem nem listem a página em
resultados de busca.

## O que este painel garante em termos de segurança

- **Login obrigatório**: o painel inteiro — inclusive qualquer dado de
  processo — fica bloqueado atrás de uma tela de e-mail/senha (Supabase
  Auth). Nenhum dado é buscado do banco antes de uma sessão válida existir.
- **RLS restrita a autenticados**: todas as políticas de acesso às tabelas
  `cases`, `case_files` e `profiles` exigem `auth.uid() is not null` — sem
  login, a requisição não tem nenhum acesso, nem de leitura.
- **Exclusão restrita a ADM, aplicada no banco**: a regra "só ADM exclui"
  não é só uma checagem de tela (fácil de contornar editando o JavaScript)
  — é uma política RLS na própria tabela; o Postgres recusa a tentativa de
  qualquer outro usuário, mesmo que ela chegue diretamente pela API.
- **Log de auditoria à prova de adulteração**: escrito por um gatilho do
  banco de dados, não por uma chamada feita pelo navegador — não há como um
  usuário criar ou apagar um registro falso. O painel só *lê* esse log e
  recalcula a exibição "campo alterado de X para Y" a partir dos retratos
  gravados pelo gatilho.
- **Arquivos em bucket privado com link temporário**: os anexos ficam no
  Supabase Storage (bucket `documentos-trabalhistas`, privado), e cada
  visualização/download usa uma URL assinada, válida por 60 segundos.
- **Sem indexação por buscadores**: meta tag `noindex, nofollow` no
  cabeçalho do HTML.
- **Sem cache local de dados sensíveis**: diferente de versões anteriores
  deste painel, nenhuma cópia dos processos fica salva no navegador
  (localStorage) entre sessões — os dados só existem em memória enquanto há
  uma sessão autenticada aberta, e são descartados ao sair (Sair) ou fechar
  a aba. Isso é deliberado: dados jurídicos sensíveis não deveriam
  sobreviver ao logout num computador compartilhado.

## Dúvidas comuns

**"O pedido original falava em `auth.uid() IS NOT NULL`, mas a exclusão
ficou restrita só a ADM — por que não deixei igual para todo mundo
autenticado?"** Leitura, cadastro e edição seguem exatamente essa regra
(`auth.uid() is not null`, sem exigir nenhum papel específico). Só a
exclusão de processos manteve a restrição adicional a usuários com perfil
`ADM` — essa regra já existia no desenho anterior do banco, e mantê-la
serve melhor ao objetivo de "segurança máxima" que você descreveu (nem todo
usuário autenticado deveria poder apagar processos definitivamente). Se
preferir que qualquer pessoa autenticada possa excluir, é só trocar
`using (public.is_admin())` por `using (auth.uid() is not null)` na
política `"cases: excluir somente ADM"` em `supabase_schema.sql` e rodar de
novo.

**"Só administradores podem excluir, mas todo mundo autenticado pode
cadastrar/editar/ver todos os processos — está certo?"** Sim. Se quiser
também restringir quem pode ver ou editar (por exemplo, cada usuário só
vê os processos que registrou), isso é uma mudança nas políticas RLS de
`public.cases` em `supabase_schema.sql` — posso ajustar se quiser algo mais
granular.

**"Leitura automática de documentos por IA sumiu?"** Ela voltou, agora
usando a API gratuita do Google Gemini, chamada por uma função de servidor
(`api/extract.js`) em vez de um recurso do Claude Artifact. Veja o arquivo
`SETUP-GEMINI.md` deste pacote para o passo a passo completo — inclui uma
mudança na forma de publicar o projeto na Vercel, já que agora existe essa
função de servidor além do HTML.

**"Posso usar Firebase em vez de Supabase?"** Dava para adaptar, mas o
Supabase foi escolhido porque o modelo (papéis ADM/Operador + Row Level
Security) mapeia diretamente para os recursos nativos do Postgres/Supabase;
no Firebase, a mesma regra exigiria escrever Firestore Security Rules
equivalentes, com sintaxe diferente.
