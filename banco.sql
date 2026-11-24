-- ============================================================
-- MV MODS — BANCO DE DADOS (sem login, sem configuração extra)
-- Supabase > SQL Editor > New query > cole TUDO > Run.
-- Pode rodar quantas vezes quiser.
-- SENHA DO ADM inicial: 360  (troque com a linha no fim deste arquivo)
-- NAO suba este arquivo no GitHub/Vercel (a senha está nele).
-- ============================================================
create extension if not exists pgcrypto with schema extensions;
do $$ begin create type public.content_category as enum ('jogo','skin','xite'); exception when duplicate_object then null; end $$;

create table if not exists public.contents (
  id uuid primary key default gen_random_uuid(),
  slug text unique not null, name text not null, category content_category not null,
  description text not null default '', cover_url text, banner_url text,
  gallery text[] not null default '{}', current_version text not null default '1.0',
  status text not null default 'atualizado', published boolean not null default false,
  featured boolean not null default false, featured_title text, featured_description text,
  created_at timestamptz not null default now(), updated_at timestamptz not null default now());
create table if not exists public.versions (
  id uuid primary key default gen_random_uuid(),
  content_id uuid not null references public.contents(id) on delete cascade,
  version text not null, description text not null default '',
  features text[] not null default '{}', images text[] not null default '{}',
  is_current boolean not null default false, archived boolean not null default false,
  created_at timestamptz not null default now());
create table if not exists public.downloads (
  version_id uuid primary key references public.versions(id) on delete cascade, url text not null);
create table if not exists public.site_settings (
  id int primary key default 1 check (id=1),
  theme text not null default 'dark', primary_color text not null default 'roxo',
  button_style text not null default 'arredondado', card_size text not null default 'grande',
  hero_banner_url text, background_url text, sort_order text not null default 'recentes',
  hero_title text not null default 'SEU CATÁLOGO GAMER',
  hero_subtitle text not null default 'Encontre jogos, skins e conteúdos.');
insert into public.site_settings (id) values (1) on conflict do nothing;
create table if not exists public.arquivos (
  code text primary key, name text not null, size bigint not null default 0, path text not null,
  mime text, token text not null, downloads int not null default 0, created_at timestamptz not null default now());
create table if not exists public.app_secret (
  id int primary key default 1 check (id=1), pass_hash text not null,
  fails int not null default 0, window_start timestamptz);
insert into public.app_secret (id, pass_hash) values (1, extensions.crypt('360', extensions.gen_salt('bf'))) on conflict do nothing;

-- Segurança: o público só LÊ conteúdo publicado. Todo o resto passa pelas funções abaixo.
alter table public.contents enable row level security;
alter table public.versions enable row level security;
alter table public.downloads enable row level security;
alter table public.site_settings enable row level security;
alter table public.arquivos enable row level security;
alter table public.app_secret enable row level security;
do $$ declare r record; begin
  for r in select policyname, tablename from pg_policies where schemaname='public' loop
    execute format('drop policy if exists %I on public.%I', r.policyname, r.tablename);
  end loop;
end $$;
revoke all on public.contents, public.versions, public.downloads, public.site_settings, public.arquivos, public.app_secret from anon, authenticated;
grant select on public.contents, public.versions, public.site_settings to anon, authenticated;
create policy "ler publicados" on public.contents for select to anon, authenticated using (published);
create policy "ler versoes" on public.versions for select to anon, authenticated using (exists(select 1 from public.contents c where c.id=content_id and c.published));
create policy "ler visual" on public.site_settings for select to anon, authenticated using (true);

-- ---------- PAINEL ADM: uma função só, confere a senha no servidor ----------
create or replace function public.adm(_pass text, _op text, _arg jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare s public.app_secret%rowtype; cid uuid; vid uuid; sl text;
begin
  select * into s from public.app_secret where id=1 for update;
  if s.window_start is null or s.window_start < now() - interval '1 hour' then
    update public.app_secret set fails=0, window_start=now() where id=1; s.fails := 0;
  end if;
  if s.fails >= 10 then return jsonb_build_object('ok',false,'locked',true); end if;   -- trava 1h após 10 erros
  if s.pass_hash <> extensions.crypt(coalesce(_pass,''), s.pass_hash) then
    update public.app_secret set fails = fails + 1 where id=1;
    return jsonb_build_object('ok',false);
  end if;
  update public.app_secret set fails=0 where id=1;

  case _op
  when 'check' then return jsonb_build_object('ok',true);

  when 'list_contents' then
    return jsonb_build_object('ok',true,'data', coalesce((select jsonb_agg(to_jsonb(c) order by c.created_at desc) from public.contents c),'[]'::jsonb));

  when 'save_content' then
    if coalesce((_arg->>'featured')::boolean,false) then
      update public.contents set featured=false where featured and id is distinct from nullif(_arg->>'id','')::uuid;
    end if;
    if nullif(_arg->>'id','') is not null then
      cid := (_arg->>'id')::uuid;
      update public.contents set name=_arg->>'name', category=(_arg->>'category')::content_category,
        description=coalesce(_arg->>'description',''), cover_url=_arg->>'cover_url', banner_url=_arg->>'banner_url',
        gallery=array(select jsonb_array_elements_text(coalesce(_arg->'gallery','[]'::jsonb))),
        current_version=coalesce(nullif(_arg->>'current_version',''),'1.0'), status=coalesce(_arg->>'status','atualizado'),
        published=coalesce((_arg->>'published')::boolean,false), featured=coalesce((_arg->>'featured')::boolean,false),
        featured_title=nullif(_arg->>'featured_title',''), featured_description=nullif(_arg->>'featured_description',''), updated_at=now()
      where id=cid;
    else
      sl := coalesce(nullif(_arg->>'slug',''),'conteudo');
      if exists(select 1 from public.contents where slug=sl) then sl := sl || '-' || substr(md5(random()::text),1,4); end if;
      insert into public.contents (slug,name,category,description,cover_url,banner_url,gallery,current_version,status,published,featured,featured_title,featured_description)
      values (sl, _arg->>'name', (_arg->>'category')::content_category, coalesce(_arg->>'description',''), _arg->>'cover_url', _arg->>'banner_url',
        array(select jsonb_array_elements_text(coalesce(_arg->'gallery','[]'::jsonb))), coalesce(nullif(_arg->>'current_version',''),'1.0'),
        coalesce(_arg->>'status','atualizado'), coalesce((_arg->>'published')::boolean,false), coalesce((_arg->>'featured')::boolean,false),
        nullif(_arg->>'featured_title',''), nullif(_arg->>'featured_description',''))
      returning id into cid;
      insert into public.versions (content_id,version,description,features,is_current)
      values (cid, coalesce(nullif(_arg->>'current_version',''),'1.0'), 'Lançamento inicial.', '{}', true);
    end if;
    return jsonb_build_object('ok',true,'data',jsonb_build_object('id',cid));

  when 'set_published' then
    update public.contents set published=(_arg->>'published')::boolean, updated_at=now() where id=(_arg->>'id')::uuid;
    return jsonb_build_object('ok',true);
  when 'delete_content' then
    delete from public.contents where id=(_arg->>'id')::uuid;
    return jsonb_build_object('ok',true);

  when 'list_versions' then
    return jsonb_build_object('ok',true,'data', coalesce((select jsonb_agg(jsonb_build_object('id',v.id,'version',v.version,'description',v.description,
      'is_current',v.is_current,'archived',v.archived,'url',coalesce(d.url,'')) order by v.created_at)
      from public.versions v left join public.downloads d on d.version_id=v.id where v.content_id=(_arg->>'content_id')::uuid),'[]'::jsonb));
  when 'add_version' then
    insert into public.versions (content_id,version,description,features)
    values ((_arg->>'content_id')::uuid, _arg->>'version', coalesce(_arg->>'description',''),
      array(select jsonb_array_elements_text(coalesce(_arg->'features','[]'::jsonb)))) returning id into vid;
    if nullif(_arg->>'url','') is not null then
      insert into public.downloads (version_id,url) values (vid,_arg->>'url') on conflict (version_id) do update set url=excluded.url;
    end if;
    return jsonb_build_object('ok',true);
  when 'set_current' then
    vid := (_arg->>'id')::uuid;
    select content_id into cid from public.versions where id=vid;
    update public.versions set is_current=false where content_id=cid;
    update public.versions set is_current=true, archived=false where id=vid;
    update public.contents set current_version=(select version from public.versions where id=vid), status='atualizado', updated_at=now() where id=cid;
    return jsonb_build_object('ok',true,'data',(select version from public.versions where id=vid));
  when 'set_archived' then
    update public.versions set archived=(_arg->>'archived')::boolean where id=(_arg->>'id')::uuid;
    return jsonb_build_object('ok',true);
  when 'delete_version' then
    delete from public.versions where id=(_arg->>'id')::uuid;
    return jsonb_build_object('ok',true);
  when 'set_url' then
    if nullif(_arg->>'url','') is null then delete from public.downloads where version_id=(_arg->>'id')::uuid;
    else insert into public.downloads (version_id,url) values ((_arg->>'id')::uuid,_arg->>'url') on conflict (version_id) do update set url=excluded.url; end if;
    return jsonb_build_object('ok',true);

  when 'save_settings' then
    update public.site_settings set
      hero_title=coalesce(_arg->>'hero_title',hero_title), hero_subtitle=coalesce(_arg->>'hero_subtitle',hero_subtitle),
      theme=coalesce(_arg->>'theme',theme), primary_color=coalesce(_arg->>'primary_color',primary_color),
      button_style=coalesce(_arg->>'button_style',button_style), card_size=coalesce(_arg->>'card_size',card_size),
      sort_order=coalesce(_arg->>'sort_order',sort_order),
      hero_banner_url=case when _arg ? 'hero_banner_url' then _arg->>'hero_banner_url' else hero_banner_url end,
      background_url=case when _arg ? 'background_url' then _arg->>'background_url' else background_url end
    where id=1;
    return jsonb_build_object('ok',true);
  end case;
  return jsonb_build_object('ok',false);
end $$;
revoke execute on function public.adm(text,text,jsonb) from public;
grant execute on function public.adm(text,text,jsonb) to anon, authenticated;

-- ---------- DOWNLOAD DO CATÁLOGO ----------
create or replace function public.get_download(_version_id uuid) returns text
language sql stable security definer set search_path = public as $$
  select d.url from public.downloads d join public.versions v on v.id=d.version_id join public.contents c on c.id=v.content_id
  where d.version_id=_version_id and c.published and not v.archived $$;
grant execute on function public.get_download(uuid) to anon, authenticated;

-- ---------- ENVIAR ARQUIVO COM LINK ----------
create or replace function public.create_arquivo(_code text, _name text, _size bigint, _path text, _mime text, _token text) returns void
language sql security definer set search_path = public as $$
  insert into public.arquivos (code,name,size,path,mime,token) values (_code,_name,_size,_path,_mime,_token) $$;
create or replace function public.get_shared_file(_code text)
returns table(code text, name text, size bigint, path text, downloads int, created_at timestamptz)
language sql stable security definer set search_path = public as $$
  select a.code, a.name, a.size, a.path, a.downloads, a.created_at from public.arquivos a where a.code = _code $$;
create or replace function public.count_download(_code text) returns void
language sql security definer set search_path = public as $$
  update public.arquivos set downloads = downloads + 1 where code = _code $$;
create or replace function public.delete_arquivo(_code text, _token text) returns boolean
language plpgsql security definer set search_path = public as $$
begin delete from public.arquivos where code=_code and token=_token; return found; end $$;
revoke execute on function public.create_arquivo(text,text,bigint,text,text,text), public.get_shared_file(text), public.count_download(text), public.delete_arquivo(text,text) from public;
grant execute on function public.create_arquivo(text,text,bigint,text,text,text), public.get_shared_file(text), public.count_download(text), public.delete_arquivo(text,text) to anon, authenticated;

-- ---------- PASTAS DE ARQUIVOS E FOTOS ----------
insert into storage.buckets (id, name, public) values ('files','files',true) on conflict (id) do update set public = true;
insert into storage.buckets (id, name, public) values ('media','media',true) on conflict (id) do update set public = true;
update storage.buckets set file_size_limit = 5242880, allowed_mime_types = array['image/*'] where id='media';
do $$ declare r record; begin
  for r in select policyname from pg_policies where schemaname='storage' and tablename='objects' and (policyname like 'media%' or policyname like 'files%') loop
    execute format('drop policy if exists %I on storage.objects', r.policyname);
  end loop;
end $$;
create policy "media ler" on storage.objects for select to anon, authenticated using (bucket_id='media');
create policy "media enviar" on storage.objects for insert to anon, authenticated with check (bucket_id='media');
create policy "files enviar" on storage.objects for insert to anon, authenticated with check (bucket_id='files');

-- ============================================================
-- TROCAR A SENHA DO ADM (rode com a sua senha nova):
--   update public.app_secret set pass_hash = extensions.crypt('SUA-SENHA-NOVA', extensions.gen_salt('bf')) where id=1;
-- ============================================================
