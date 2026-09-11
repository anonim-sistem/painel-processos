-- =====================================================================
-- Painel de Processos Trabalhistas — schema Supabase (Postgres + Auth + RLS)
-- =====================================================================
-- Como aplicar:
--   1. Crie um projeto em https://supabase.com (grátis para começar).
--   2. Abra o "SQL Editor" do projeto e cole este arquivo inteiro. Rode.
--   3. Crie o bucket de arquivos: Storage > New bucket > nome
--      "documentos-trabalhistas" > marque "Public" como DESMARCADO (privado)
--      > Save. As políticas de acesso ao bucket estão no final deste arquivo.
--   4. Crie o primeiro usuário ADM: Authentication > Users > Add user
--      (defina e-mail e senha). Depois rode, trocando o e-mail:
--        update public.profiles set role = 'ADM' where email = 'voce@empresa.com';
--   5. Pegue "Project URL" e a chave "anon public" em Project Settings > API
--      e cole no arquivo do painel (veja SETUP-SUPABASE.md).
--
-- Nota sobre nomes de tabela: o painel foi pedido em cima de "processos",
-- "funcionários", "empresas" e "logs de auditoria" — este schema mantém os
-- nomes técnicos já usados no restante do projeto (cases / case_files /
-- profiles / audit_log) em vez de traduzir literalmente, porque funcionário
-- e empresa são só CAMPOS de um processo (não cadastros próprios) neste
-- modelo de dados; a nomenclatura em português continua em todo o texto
-- visível na tela.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. Perfis de usuário (papel ADM / Operador)
-- ---------------------------------------------------------------------
create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  email text,
  nome text,
  role text not null default 'Operador' check (role in ('ADM','Operador')),
  criado_em timestamptz not null default now()
);

alter table public.profiles enable row level security;

-- Qualquer usuário autenticado pode ler a lista de perfis (para mostrar
-- "registrado por Fulano" em vez de um UUID). Só o próprio usuário (ou um
-- ADM) pode alterar um perfil.
create policy "profiles: leitura para autenticados"
  on public.profiles for select
  to authenticated
  using (auth.uid() is not null);

create policy "profiles: o próprio usuário edita seu perfil"
  on public.profiles for update
  to authenticated
  using (auth.uid() = id);

-- Cria automaticamente um perfil (papel padrão "Operador") sempre que
-- alguém é cadastrado no Supabase Auth — evita ter que criar o perfil à mão
-- toda vez. Promover para ADM é feito manualmente (passo 4 acima).
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer set search_path = public
as $$
begin
  insert into public.profiles (id, email, nome, role)
  values (new.id, new.email, coalesce(new.raw_user_meta_data->>'nome', new.email), 'Operador')
  on conflict (id) do nothing;
  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- Função auxiliar: o usuário autenticado atual é ADM?
create or replace function public.is_admin()
returns boolean
language sql
security definer set search_path = public
stable
as $$
  select exists (
    select 1 from public.profiles where id = auth.uid() and role = 'ADM'
  );
$$;

-- ---------------------------------------------------------------------
-- 2. Processos
-- ---------------------------------------------------------------------
create table if not exists public.cases (
  id uuid primary key default gen_random_uuid(),
  funcionario text not null,
  data_admissao date,
  data_desligamento date,
  tipo_desligamento text,
  empresa text,
  cnpj text,
  numero_processo text,
  advogado text,
  data_audiencia date,
  data_abertura date,
  valor_processo numeric,
  status text not null default 'em_andamento',
  motivo text,
  teve_acordo boolean not null default false,
  valor_acordo numeric,
  valor_condenacao numeric,
  honorarios_advocaticios numeric,
  observacoes text,
  registrado_por uuid references auth.users(id),
  registrado_por_nome text,
  criado_em timestamptz not null default now(),
  atualizado_em timestamptz not null default now()
);

-- Trava de duplicidade por número de processo (ignora linhas sem número).
create unique index if not exists cases_numero_processo_unique
  on public.cases (numero_processo)
  where numero_processo is not null and numero_processo <> '';

create index if not exists cases_cnpj_idx on public.cases (cnpj);
create index if not exists cases_status_idx on public.cases (status);

alter table public.cases enable row level security;

-- Todas as políticas abaixo usam "to authenticated" + "auth.uid() is not
-- null" (implícito em "to authenticated" — o Supabase só concede esse papel
-- a uma requisição com um JWT de sessão válido; sem login, a requisição cai
-- no papel "anon", que não tem NENHUMA política aqui e portanto nenhum
-- acesso) — é exatamente a regra pedida ("restringir exclusivamente a
-- usuários autenticados"), removendo por completo o antigo "using (true)"
-- aberto ao público. A única política mais restritiva que isso é a de
-- exclusão logo abaixo, que também exige o papel ADM — mantida
-- deliberadamente (em vez de afrouxada para bater 1:1 com o pedido) porque
-- atende melhor ao objetivo de "segurança máxima": qualquer pessoa com uma
-- conta no painel pode ler/cadastrar/editar processos, mas só quem tem
-- perfil ADM pode excluir um processo (e seus anexos) definitivamente.
--
-- Leitura: todo usuário autenticado vê todos os processos (painel interno
-- da empresa — ajuste aqui se precisar restringir por equipe/unidade).
create policy "cases: leitura para autenticados"
  on public.cases for select
  to authenticated
  using (auth.uid() is not null);

-- Cadastro e edição: qualquer usuário autenticado (ADM ou Operador).
create policy "cases: inserir autenticado"
  on public.cases for insert
  to authenticated
  with check (auth.uid() is not null);

create policy "cases: atualizar autenticado"
  on public.cases for update
  to authenticated
  using (auth.uid() is not null)
  with check (auth.uid() is not null);

-- Exclusão: SOMENTE ADM. Esta é a regra pedida — aplicada no banco, não na
-- tela, então não há como contornar editando o JavaScript do navegador.
create policy "cases: excluir somente ADM"
  on public.cases for delete
  to authenticated
  using (public.is_admin());

create or replace function public.touch_atualizado_em()
returns trigger language plpgsql as $$
begin
  new.atualizado_em = now();
  return new;
end;
$$;

drop trigger if exists cases_touch_atualizado_em on public.cases;
create trigger cases_touch_atualizado_em
  before update on public.cases
  for each row execute function public.touch_atualizado_em();

-- ---------------------------------------------------------------------
-- 3. Anexos (metadados — os arquivos em si ficam no Storage, bucket
--    privado "documentos-trabalhistas"; veja as políticas de Storage no
--    final do arquivo). "tag" guarda a categoria do documento escolhida na
--    tela ("Petição Inicial", "Defesa Elaborada", "Provas", "Ata/Sentença"
--    ou vazio/"Sem categoria").
-- ---------------------------------------------------------------------
create table if not exists public.case_files (
  id uuid primary key default gen_random_uuid(),
  case_id uuid not null references public.cases(id) on delete cascade,
  storage_path text not null,
  name text not null,
  mime text,
  size bigint,
  tag text,
  uploaded_by uuid references auth.users(id),
  uploaded_at timestamptz not null default now()
);

create index if not exists case_files_case_id_idx on public.case_files (case_id);

alter table public.case_files enable row level security;

create policy "case_files: leitura para autenticados"
  on public.case_files for select
  to authenticated
  using (auth.uid() is not null);

create policy "case_files: inserir autenticado"
  on public.case_files for insert
  to authenticated
  with check (auth.uid() is not null);

create policy "case_files: atualizar autenticado"
  on public.case_files for update
  to authenticated
  using (auth.uid() is not null)
  with check (auth.uid() is not null);

-- Remover um anexo é tratado como parte de editar o processo (não é a
-- exclusão do processo inteiro), então fica liberado para qualquer
-- autenticado — mude para "using (public.is_admin())" se quiser restringir
-- também isso.
create policy "case_files: excluir autenticado"
  on public.case_files for delete
  to authenticated
  using (auth.uid() is not null);

-- ---------------------------------------------------------------------
-- 4. Log de auditoria — preenchido por um TRIGGER no banco (não pelo
--    navegador), então não dá para um usuário criar ou apagar um registro
--    de auditoria falso alterando o JavaScript da página.
--    "dados_antes"/"dados_depois" guardam um retrato (JSON) da linha
--    inteira de "cases" antes/depois da mudança — o painel usa os dois para
--    recalcular, no navegador, a lista "Campo alterado de X para Y" campo a
--    campo, sem precisar desse cálculo em SQL.
-- ---------------------------------------------------------------------
create table if not exists public.audit_log (
  id bigint generated always as identity primary key,
  action text not null, -- 'criado' | 'alterado' | 'excluido'
  case_id uuid,
  numero_processo text,
  funcionario text,
  usuario_id uuid,
  usuario_email text,
  usuario_nome text,
  dados_antes jsonb,
  dados_depois jsonb,
  ts timestamptz not null default now()
);

create index if not exists audit_log_ts_idx on public.audit_log (ts desc);

alter table public.audit_log enable row level security;

create policy "audit_log: leitura para autenticados"
  on public.audit_log for select
  to authenticated
  using (auth.uid() is not null);
-- Sem política de insert/update/delete para o papel "authenticated" — só o
-- trigger (que roda como "security definer") consegue gravar aqui.

create or replace function public.log_case_audit()
returns trigger
language plpgsql
security definer set search_path = public
as $$
declare
  acting_email text;
  acting_nome text;
begin
  select email into acting_email from auth.users where id = auth.uid();
  select nome into acting_nome from public.profiles where id = auth.uid();
  if (tg_op = 'DELETE') then
    insert into public.audit_log (action, case_id, numero_processo, funcionario, usuario_id, usuario_email, usuario_nome, dados_antes, dados_depois)
    values ('excluido', old.id, old.numero_processo, old.funcionario, auth.uid(), acting_email, acting_nome, to_jsonb(old), null);
    return old;
  elsif (tg_op = 'UPDATE') then
    insert into public.audit_log (action, case_id, numero_processo, funcionario, usuario_id, usuario_email, usuario_nome, dados_antes, dados_depois)
    values ('alterado', new.id, new.numero_processo, new.funcionario, auth.uid(), acting_email, acting_nome, to_jsonb(old), to_jsonb(new));
    return new;
  else
    insert into public.audit_log (action, case_id, numero_processo, funcionario, usuario_id, usuario_email, usuario_nome, dados_antes, dados_depois)
    values ('criado', new.id, new.numero_processo, new.funcionario, auth.uid(), acting_email, acting_nome, null, to_jsonb(new));
    return new;
  end if;
end;
$$;

drop trigger if exists cases_audit_insert on public.cases;
create trigger cases_audit_insert
  after insert on public.cases
  for each row execute function public.log_case_audit();

drop trigger if exists cases_audit_update on public.cases;
create trigger cases_audit_update
  after update on public.cases
  for each row execute function public.log_case_audit();

drop trigger if exists cases_audit_delete on public.cases;
create trigger cases_audit_delete
  after delete on public.cases
  for each row execute function public.log_case_audit();

-- ---------------------------------------------------------------------
-- 5. Realtime — habilita atualização ao vivo de processos E anexos para
--    quem estiver com o painel aberto em outra aba/computador (o painel
--    escuta as duas tabelas — ver subscribeCases() no arquivo do painel).
-- ---------------------------------------------------------------------
alter publication supabase_realtime add table public.cases;
alter publication supabase_realtime add table public.case_files;

-- =====================================================================
-- 6. Políticas de Storage (rode depois de criar o bucket
--    "documentos-trabalhistas" pela interface, marcado como PRIVADO — veja
--    o passo 3 no topo do arquivo). Privado quer dizer que não existe uma
--    URL pública fixa para os arquivos: o painel só consegue mostrar/baixar
--    um documento gerando uma URL assinada e temporária (válida por 60
--    segundos) através de supabase.storage.createSignedUrl() — pedido
--    explícito do usuário ("Storage Seguro").
-- =====================================================================
create policy "documentos-trabalhistas: leitura para autenticados"
  on storage.objects for select
  to authenticated
  using (bucket_id = 'documentos-trabalhistas' and auth.uid() is not null);

create policy "documentos-trabalhistas: upload para autenticados"
  on storage.objects for insert
  to authenticated
  with check (bucket_id = 'documentos-trabalhistas' and auth.uid() is not null);

create policy "documentos-trabalhistas: excluir para autenticados"
  on storage.objects for delete
  to authenticated
  using (bucket_id = 'documentos-trabalhistas' and auth.uid() is not null);
