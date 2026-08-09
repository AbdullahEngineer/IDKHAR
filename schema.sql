-- =========================================================================
-- مسار — Supabase schema
-- شغّل هذا الملف كاملاً مرة واحدة من: Supabase Dashboard → SQL Editor → New query
-- =========================================================================

-- =========================================================================
-- إعادة ضبط كاملة (اختياري) — فعّل الأسطر الأربعة التالية (احذف "-- " من
-- أولها) فقط إذا كانت جداولك الحالية بأسماء أعمدة مختلفة عن هذا الملف (مثال
-- حقيقي واجهناه: عمود اسمه "title" بدل "name" من محاولة أقدم). بدون هذا،
-- إضافة أعمدة جديدة بجانب أعمدة قديمة إلزامية بلا قيمة افتراضية تبقي
-- الجدول عالقاً بخطأ "null value ... violates not-null constraint".
-- تحذير: هذا يحذف كل بيانات هذه الجداول نهائياً — استخدمه فقط أثناء
-- التطوير/الاختبار، أبداً على بيانات مستخدمين حقيقيين.
-- drop table if exists public.expenses cascade;
-- drop table if exists public.income cascade;
-- drop table if exists public.goals cascade;
-- drop table if exists public.profiles cascade;

-- ملف تعريف المستخدم (لا نضع أبداً كلمة المرور هنا — تلك مسؤولية auth.users
-- الداخلي في Supabase، ومُشفّرة هناك بخوارزمية bcrypt، ولا يصل إليها أي كود
-- عميل على الإطلاق).
create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  name text not null,
  currency text not null default 'ر.س',
  onboarded boolean not null default false,
  created_at timestamptz not null default now()
);
-- في حال كان الجدول أُنشئ مسبقاً بنسخة أقدم من هذا الملف (create table if
-- not exists يتجاهل الجدول بالكامل إذا كان موجوداً، حتى لو ناقص أعمدة) —
-- هذه الأوامر تضيف أي عمود ناقص بأمان دون التأثير على البيانات الموجودة.
alter table public.profiles add column if not exists name text not null default 'مستخدم';
alter table public.profiles add column if not exists currency text not null default 'ر.س';
alter table public.profiles add column if not exists onboarded boolean not null default false;
alter table public.profiles add column if not exists created_at timestamptz not null default now();

-- =========================================================================
-- إنشاء صف profiles تلقائياً عند تسجيل مستخدم جديد — من طرف قاعدة البيانات
-- نفسها، وليس من كود الواجهة الأمامية.
-- لماذا؟ لأنه عند signUp() قد لا توجد جلسة مصادقة فورية بعد (مثلاً إذا
-- "Confirm email" مفعّل)، وبالتالي auth.uid() = null في تلك اللحظة، فيفشل
-- أي INSERT من العميل يحاول تحقيق سياسة RLS (auth.uid() = id). الـ Trigger
-- هنا يعمل بصلاحيات SECURITY DEFINER كجزء من عملية إنشاء المستخدم في
-- auth.users مباشرة، فيتجاوز هذه المعضلة تماماً ويعمل بغض النظر عن حالة
-- تأكيد البريد. الاسم والعملة يُقرآن من بيانات وصفية (metadata) تُمرَّر مع
-- signUp() من طرف العميل.
--
-- ملاحظة مهمة: عملية إنشاء المستخدم داخل Supabase تُنفَّذ فعلياً بواسطة دور
-- (role) داخلي اسمه supabase_auth_admin، وليس postgres. حتى مع
-- SECURITY DEFINER، هذا الدور يحتاج صلاحية صريحة للوصول لجدول profiles
-- وإلا فشل التسجيل بالكامل برسالة "Database error saving new user".
grant usage on schema public to supabase_auth_admin;
grant all on table public.profiles to supabase_auth_admin;

create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer set search_path = public
as $$
begin
  insert into public.profiles (id, name, currency, onboarded)
  values (
    new.id,
    coalesce(new.raw_user_meta_data->>'name', 'مستخدم جديد'),
    coalesce(new.raw_user_meta_data->>'currency', 'ر.س'),
    false
  )
  on conflict (id) do nothing;
  return new;
exception when others then
  -- لا نسمح لأي عطل غير متوقع هنا بإفشال تسجيل المستخدم بالكامل. إذا صار
  -- خطأ، يبقى صف profiles مفقوداً مؤقتاً — وواجهة تسجيل الدخول في index.html
  -- تكتشف هذه الحالة وتنشئ الصف تلقائياً عند أول دخول ناجح (self-heal).
  raise warning 'handle_new_user failed for %: %', new.id, sqlerrm;
  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

create table if not exists public.income (
  id bigint generated always as identity primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  name text not null,
  amount numeric not null check (amount > 0),
  recurrence text not null check (recurrence in ('monthly','limited','irregular')),
  months integer,
  day integer,
  created_month_idx integer not null,
  revisions jsonb not null default '[]'::jsonb,
  created_at timestamptz not null default now()
);
-- كل هذه الأوامر آمنة للتكرار وتغطي كل عمود بالجدول، مو فقط الأحدث — بعض
-- الجداول عند الاختبار تبيّن أنها أُنشئت من محاولة أقدم بأعمدة مختلفة تماماً
-- عن هذا الملف، فلا نفترض أن أي عمود "أساسي" موجود بالضرورة.
alter table public.income add column if not exists user_id uuid references auth.users(id) on delete cascade;
alter table public.income add column if not exists name text not null default 'دخل';
alter table public.income add column if not exists amount numeric not null default 1;
alter table public.income add column if not exists recurrence text not null default 'monthly';
alter table public.income add column if not exists months integer;
alter table public.income add column if not exists day integer;
alter table public.income add column if not exists created_month_idx integer not null default 0;
alter table public.income add column if not exists revisions jsonb not null default '[]'::jsonb;
alter table public.income add column if not exists created_at timestamptz not null default now();

create table if not exists public.expenses (
  id bigint generated always as identity primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  name text not null,
  amount numeric not null check (amount > 0),
  category text not null,
  type text not null check (type in ('fixed','variable')),
  duration integer not null default 1,
  start_month_idx integer not null,
  revisions jsonb not null default '[]'::jsonb,
  created_at timestamptz not null default now()
);
alter table public.expenses add column if not exists user_id uuid references auth.users(id) on delete cascade;
alter table public.expenses add column if not exists name text not null default 'مصروف';
alter table public.expenses add column if not exists amount numeric not null default 1;
alter table public.expenses add column if not exists category text not null default 'أخرى';
alter table public.expenses add column if not exists type text not null default 'fixed';
alter table public.expenses add column if not exists duration integer not null default 1;
alter table public.expenses add column if not exists start_month_idx integer not null default 0;
alter table public.expenses add column if not exists revisions jsonb not null default '[]'::jsonb;
alter table public.expenses add column if not exists created_at timestamptz not null default now();

create table if not exists public.goals (
  id bigint generated always as identity primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  name text not null,
  target numeric not null check (target > 0),
  current numeric not null default 0,
  months integer not null,
  start_month_idx integer not null,
  deposits jsonb not null default '[]'::jsonb,
  created_at timestamptz not null default now()
);
alter table public.goals add column if not exists user_id uuid references auth.users(id) on delete cascade;
alter table public.goals add column if not exists name text not null default 'هدف';
alter table public.goals add column if not exists target numeric not null default 1;
alter table public.goals add column if not exists current numeric not null default 0;
alter table public.goals add column if not exists months integer not null default 12;
alter table public.goals add column if not exists start_month_idx integer not null default 0;
alter table public.goals add column if not exists deposits jsonb not null default '[]'::jsonb;
alter table public.goals add column if not exists created_at timestamptz not null default now();

-- كل جدول يعبّئ user_id تلقائياً بالمستخدم المسجّل دخوله حالياً، ويمنع أي
-- قيمة أخرى — بهذا لا يقدر أي مستخدم (حتى لو عدّل الطلب من المتصفح) يكتب
-- بيانات باسم مستخدم آخر.
create or replace function public.set_user_id()
returns trigger language plpgsql as $$
begin
  new.user_id := auth.uid();
  return new;
end;
$$;

drop trigger if exists trg_income_user_id on public.income;
create trigger trg_income_user_id before insert on public.income
  for each row execute function public.set_user_id();

drop trigger if exists trg_expenses_user_id on public.expenses;
create trigger trg_expenses_user_id before insert on public.expenses
  for each row execute function public.set_user_id();

drop trigger if exists trg_goals_user_id on public.goals;
create trigger trg_goals_user_id before insert on public.goals
  for each row execute function public.set_user_id();

-- =========================================================================
-- ROW LEVEL SECURITY — هذا هو الحارس الحقيقي: حتى لو أخطأ الكود في الواجهة
-- الأمامية، Postgres نفسه يرفض أي قراءة أو كتابة لا تخص صاحب الـ JWT الحالي.
-- =========================================================================
alter table public.profiles enable row level security;
alter table public.income   enable row level security;
alter table public.expenses enable row level security;
alter table public.goals    enable row level security;

drop policy if exists "profiles: own row only" on public.profiles;
create policy "profiles: own row only" on public.profiles
  for all using (auth.uid() = id) with check (auth.uid() = id);

drop policy if exists "income: own rows only" on public.income;
create policy "income: own rows only" on public.income
  for all using (auth.uid() = user_id) with check (auth.uid() = user_id);

drop policy if exists "expenses: own rows only" on public.expenses;
create policy "expenses: own rows only" on public.expenses
  for all using (auth.uid() = user_id) with check (auth.uid() = user_id);

drop policy if exists "goals: own rows only" on public.goals;
create policy "goals: own rows only" on public.goals
  for all using (auth.uid() = user_id) with check (auth.uid() = user_id);

-- =========================================================================
-- يجبر PostgREST (الطبقة اللي تولّد REST API تلقائياً من هذا الـ schema) على
-- تحديث ذاكرته المخبّئة للأعمدة فوراً، بدل انتظار تحديثه التلقائي (اللي
-- أحياناً يتأخر). شغّل هذا الأمر مرة أخرى وحده متى ما عدّلت أعمدة الجداول
-- ولاحظت خطأ مثل "Could not find the 'x' column ... in the schema cache".
notify pgrst, 'reload schema';
