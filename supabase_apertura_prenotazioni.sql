-- =====================================================================
--  Apertura prenotazioni il venerdì alle 13:00 (ora italiana)
--  + notifica Telegram il venerdì alle 13:00
--
--  Da eseguire UNA volta nel SQL Editor di Supabase.
--  Il token del bot NON va scritto qui (il repo è pubblico): sta nel Vault,
--  vedi il passo 0.
-- =====================================================================

-- 0) Segreti Telegram nel Vault (eseguire a mano, una volta sola, con i valori veri):
--    select vault.create_secret('<TOKEN DEL BOT>', 'telegram_bot_token');
--    select vault.create_secret('<CHAT ID>',       'telegram_chat_id');
--    Per cambiarli: select vault.update_secret(id, '<nuovo valore>')
--                   from vault.secrets where name = 'telegram_bot_token';

create extension if not exists pg_cron;
create extension if not exists pg_net;

-- 1) Quando aprono le prenotazioni di una partita: il venerdì precedente
--    (o lo stesso giorno, se la partita è di venerdì) alle 13:00 ora italiana.
--    Stessa regola di bookingOpensAt() in index.html.
create or replace function public.booking_opens_at(p_date date)
returns timestamptz language sql stable as $$
  select ((p_date - ((extract(isodow from p_date)::int - 5 + 7) % 7))::timestamp + time '13:00')
         at time zone 'Europe/Rome'
$$;

-- 2) Blocco lato server: prima dell'apertura un giocatore non può prenotarsi.
--    L'admin sì: book_player gli fa inserire la prenotazione senza telefono (device null).
create or replace function public.bookings_check_open()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  v_date date;
  v_opens timestamptz;
begin
  if new.device is null then return new; end if;
  select m.date into v_date from matches m where not m.played order by m.date limit 1;
  if v_date is null then return new; end if;
  v_opens := booking_opens_at(v_date);
  if now() < v_opens then
    raise exception 'Le prenotazioni aprono venerdì % alle 13:00',
      to_char(v_opens at time zone 'Europe/Rome', 'DD/MM');
  end if;
  return new;
end $$;

drop trigger if exists bookings_check_open on public.bookings;
create trigger bookings_check_open
  before insert on public.bookings
  for each row execute function public.bookings_check_open();

-- 3) Invio di un messaggio Telegram (token e chat dal Vault)
create or replace function public.tg_send(p_text text)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_token text;
  v_chat  text;
begin
  select decrypted_secret into v_token from vault.decrypted_secrets where name = 'telegram_bot_token';
  select decrypted_secret into v_chat  from vault.decrypted_secrets where name = 'telegram_chat_id';
  if v_token is null or v_chat is null then
    raise warning 'tg_send: segreti telegram_bot_token / telegram_chat_id mancanti nel Vault';
    return;
  end if;
  perform net.http_post(
    url     := 'https://api.telegram.org/bot' || v_token || '/sendMessage',
    body    := jsonb_build_object('chat_id', v_chat, 'text', p_text, 'parse_mode', 'HTML'),
    headers := '{"Content-Type": "application/json"}'::jsonb
  );
end $$;

-- 4) Messaggio del venerdì: prenotazioni aperte, oppure promemoria di creare la partita
create or replace function public.notify_booking_opening(p_force boolean default false)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_now   timestamp := now() at time zone 'Europe/Rome';
  v_today date := v_now::date;
  v_days  text[] := array['lunedì','martedì','mercoledì','giovedì','venerdì','sabato','domenica'];
  v_months text[] := array['gennaio','febbraio','marzo','aprile','maggio','giugno','luglio',
                           'agosto','settembre','ottobre','novembre','dicembre'];
  m      record;
  v_old  date;
  v_n    int;
  v_when text;
  v_msg  text;
begin
  -- il cron parte alle 11 e alle 12 UTC: si procede solo quando in Italia sono le 13
  -- (così funziona sia con l'ora legale che con quella solare)
  if not p_force and extract(hour from v_now) <> 13 then return; end if;

  select * into m from matches where not played and date >= v_today order by date limit 1;

  if found then
    v_when := v_days[extract(isodow from m.date)::int] || ' ' || extract(day from m.date)::int
              || ' ' || v_months[extract(month from m.date)::int]
              || coalesce(', ore ' || left(m.time::text, 5), '');
    if booking_opens_at(m.date) > now() + interval '5 minutes' then
      -- partita creata con largo anticipo: le prenotazioni apriranno un venerdì successivo
      v_msg := format(E'ℹ️ Prossima partita: <b>%s</b>\nLe prenotazioni apriranno venerdì %s alle 13:00.',
                      v_when, to_char(booking_opens_at(m.date) at time zone 'Europe/Rome', 'DD/MM'));
    else
      select count(*) into v_n from bookings;
      v_msg := format(E'✅ <b>Prenotazioni aperte!</b>\n⚽ %s', v_when);
      if coalesce(m.field, '') <> '' then
        v_msg := v_msg || E'\n📍 ' || replace(replace(replace(m.field, '&', '&amp;'), '<', '&lt;'), '>', '&gt;');
      end if;
      v_msg := v_msg || format(E'\n👥 In lista: %s/16', v_n);
    end if;
  else
    select date into v_old from matches where not played and date < v_today order by date limit 1;
    v_msg := E'⚠️ <b>Nessuna partita creata!</b>\nLe prenotazioni non possono aprire: crea la partita di martedì.';
    if v_old is not null then
      v_msg := v_msg || format(E'\n(La partita del %s non ha ancora il risultato registrato.)',
                               to_char(v_old, 'DD/MM'));
    end if;
  end if;

  perform tg_send(v_msg);
end $$;

-- Queste funzioni non devono essere chiamabili dal sito con la chiave anon
-- (altrimenti chiunque potrebbe mandare messaggi col bot)
revoke all on function public.tg_send(text)                  from public, anon, authenticated;
revoke all on function public.notify_booking_opening(boolean) from public, anon, authenticated;
revoke all on function public.bookings_check_open()           from public, anon, authenticated;

-- 5) Pianificazione: ogni venerdì alle 11:00 e 12:00 UTC (= 13:00 in Italia, con ora legale o solare)
select cron.schedule('apertura-prenotazioni', '0 11,12 * * 5', 'select public.notify_booking_opening()');

-- Prova immediata del messaggio (ignora l'orario):
--   select public.notify_booking_opening(true);
-- Esecuzioni del cron:
--   select * from cron.job_run_details order by start_time desc limit 10;
