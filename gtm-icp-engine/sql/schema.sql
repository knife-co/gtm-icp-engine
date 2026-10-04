-- GTM ICP Engine (P1) — Supabase / Postgres schema
-- Raw job posts -> company rollup (view) -> enriched + scored companies -> Salesforce

-- 1. Raw job posts from job-board APIs (one row per post)
create table public.job_posts (
  source text not null,
  source_job_id text not null,
  title text,
  company_name text,
  company_slug text,
  company_domain text,
  url text,
  apply_url text,
  published_at timestamptz,
  location_restrictions text[],
  seniority text[],
  tags text[],
  description text,
  raw jsonb,
  created_at timestamptz default now(),
  primary key (source, source_job_id)          -- re-runs can't save the same post twice
);

-- 2. One row per company: domain, score, reasoning, Salesforce sync status
create table public.icp_companies (
  company_key text primary key,                 -- Himalayas slug or normalised name
  company_name text,
  company_slug text,
  domain text unique,                           -- Salesforce upsert key (Domain__c)
  domain_confidence text,                       -- 'high' = synced; 'review' = human check
  employee_range text,
  employee_count int,
  hq text,
  enriched_at timestamptz,
  enrich_error text,
  gate_passed boolean,
  open_to_lagos text,                           -- 'yes' | 'maybe' | 'no'
  icp_score int,
  icp_reasoning text,
  scored_at timestamptz,
  sf_synced boolean default false,
  sf_account_id text,
  created_at timestamptz default now()
);

-- 3. Run log and dead-letter queue
create table public.runs (
  id bigint generated always as identity primary key,
  started_at timestamptz default now(),
  finished_at timestamptz,
  sourced int,
  new_companies int,
  qualified int,
  upserted int,
  errors int
);

create table public.dead_letter (
  id bigint generated always as identity primary key,
  run_id bigint references public.runs(id),
  node text,
  error text,
  payload jsonb,
  created_at timestamptz default now()
);

alter table public.job_posts enable row level security;
alter table public.icp_companies enable row level security;
alter table public.runs enable row level security;
alter table public.dead_letter enable row level security;

-- 4. Company rollup: posts grouped into one row per company with ICP signals
create view public.company_rollup with (security_invoker = true) as
with p as (
  select *,
    coalesce(company_slug, regexp_replace(lower(trim(company_name)), '[^a-z0-9]+', '-', 'g')) as company_key,
    description ~* '\mhubspot\M' as t_hubspot,
    description ~* '\msalesforce\M' as t_salesforce,
    description ~* '\mclay\M' as t_clay,
    description ~* '\mapollo\M' as t_apollo,
    description ~* '\moutreach\.io\M|\moutreach\M' as t_outreach
  from public.job_posts
)
select
  company_key,
  max(company_name) as company_name,
  max(company_slug) as company_slug,
  count(distinct source_job_id) as post_count,
  array_agg(distinct title) as hiring_titles,
  max(published_at) as latest_post_at,
  array_remove(array_agg(distinct loc), null) as countries,
  bool_or(cardinality(location_restrictions) = 0) as open_worldwide,
  bool_or('Nigeria' = any(location_restrictions)) as includes_nigeria,
  bool_or(location_restrictions && array['Nigeria','Ghana','Kenya','South Africa','Egypt','Morocco','Rwanda','Uganda','Tanzania','Ethiopia','Senegal','Cameroon','Zambia','Zimbabwe','Botswana','Namibia','Mauritius','Tunisia','Algeria','Ivory Coast','Benin','Togo']) as includes_africa,
  bool_or(title ~* '(gtm|go[- ]to[- ]market|rev ?ops|revenue operations|marketing operations|marketing ops|sales operations|sales ops|growth operations|growth ops|crm|salesforce admin|hubspot|marketing automation)'
          and title !~* '(director|\mvp\M|vice president|head of|chief|principal)') as role_fit,
  array_remove(array[
    case when bool_or(t_hubspot) then 'HubSpot' end,
    case when bool_or(t_salesforce) then 'Salesforce' end,
    case when bool_or(t_clay) then 'Clay' end,
    case when bool_or(t_apollo) then 'Apollo' end,
    case when bool_or(t_outreach) then 'Outreach' end], null) as tech_hits
from p
left join lateral unnest(case when cardinality(p.location_restrictions) = 0 then null else p.location_restrictions end) loc on true
group by company_key;

-- 5. Work queues: only unfinished companies are processed, so re-runs are safe
create view public.companies_to_enrich with (security_invoker = true) as
select r.company_key, r.company_name, r.company_slug
from public.company_rollup r
left join public.icp_companies c using (company_key)
where c.enriched_at is null and r.company_slug is not null;

create view public.companies_to_score with (security_invoker = true) as
select r.company_key, c.company_name, c.domain, c.employee_count,
       r.post_count, r.hiring_titles, r.latest_post_at, r.countries,
       r.open_worldwide, r.includes_nigeria, r.includes_africa, r.role_fit, r.tech_hits,
       c.domain_confidence
from public.company_rollup r
join public.icp_companies c using (company_key)
where c.enriched_at is not null;
