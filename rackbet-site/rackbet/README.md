# RackBet – pool league

RackBet on avoin biljardiliiga kavereille. Se sisältää käyttäjätilit, julkisen ottelulistan, virtuaalipisteet, vedot, tulosten vahvistuksen ja rankingin.

## Tärkeä rajaus

Tämä toteutus käyttää vain **virtuaalisia pelipisteitä**. Pisteitä ei voi ostaa oikealla rahalla, siirtää käyttäjältä toiselle eikä vaihtaa rahaksi tai palkinnoiksi. Älä lisää talletuksia, maksupalvelua tai kotiutuksia. Tarkista paikalliset lait ja palveluehdot ennen kuin muutat toimintamallia.

## Tarvitset

- Node.js 20 tai uudempi
- Supabase-projekti (Auth + Postgres)
- Julkaisupaikka, esim. Vercel tai Netlify

## 1. Luo tietokanta

1. Luo projekti osoitteessa https://supabase.com.
2. Avaa projektissa **SQL Editor → New query**.
3. Liitä koko `supabase/schema.sql` ja paina Run.
4. Avaa **Authentication → Providers → Email**. Ota sähköpostivahvistus käyttöön tai pois käytöstä oman testaus-/käyttötarpeesi mukaan. Tuotannossa suosittelemme vahvistusta.
5. Avaa **Project Settings → API** ja kopioi Project URL sekä `anon` / publishable key.

## 2. Käynnistä paikallisesti

```bash
npm install
cp .env.example .env
```

Täytä `.env`:

```env
VITE_SUPABASE_URL=https://YOUR_PROJECT.supabase.co
VITE_SUPABASE_ANON_KEY=YOUR_SUPABASE_ANON_KEY
```

Käynnistä:

```bash
npm run dev
```

Avaa Viten ilmoittama osoite, tavallisesti http://localhost:5173.

## 3. Tee itsestäsi ylläpitäjä

Rekisteröidy ensin sivustolla. Etsi sen jälkeen oma käyttäjäsi Supabasen SQL Editorissa ja suorita:

```sql
update public.profiles
set is_admin = true
where username = 'OMA_KAYTTAJANIMI';
```

Ylläpitäjä voi käyttöliittymässä vahvistaa tuloksia ja perua otteluita. Ottelun luoja voi tehdä saman omille otteluilleen.

## 4. Julkaise verkkoon

1. Lataa projektikansio omaan GitHub-repoon.
2. Tuo repo Verceliin (https://vercel.com) tai Netlifyyn.
3. Lisää palvelun Environment Variables -asetuksiin:
   - `VITE_SUPABASE_URL`
   - `VITE_SUPABASE_ANON_KEY`
4. Build command: `npm run build`
5. Output directory: `dist`
6. Julkaisun jälkeen lisää domain Supabasen Authentication → URL Configuration → Site URL / Redirect URLs -kohtiin.

## Sovelluksen toimintalogiikka

- Rekisteröityminen luo profiilin ja antaa 1 000 pistettä.
- Käyttäjä voi kerätä 100 pistettä kerran päivässä.
- Käyttäjä voi asettaa yhden vedon per ottelu (minimi 10, maksimi 5 000 pistettä).
- Ottelun pelaajat eivät voi veikata omaa otteluaan.
- Veto lukitaan, kun ottelun tila ei ole enää `open`.
- Voittajan vahvistus maksaa voittavat vedot ja kirjaa pelaajien voitot/tappiot.
- Ottelun peruutus palauttaa panokset.
- Kaikki pisteisiin vaikuttavat operaatiot suoritetaan tietokannassa atomisesti RPC-funktioilla.

## Ennen julkista käyttöä – tarkistuslista

- Testaa kahdella erillisellä käyttäjätilillä.
- Ota Supabasen sähköpostivahvistus ja roskapostisuojaus käyttöön.
- Lisää CAPTCHA / rate limiting rekisteröitymiseen, jos rekisteröitymisroskapostia ilmenee.
- Päätä, haluatko sallia otteluiden luonnin kaikille. Tässä versiossa kaikki kirjautuneet käyttäjät voivat luoda otteluita.
- Tarkista Supabasen RLS-politiikat ja testaa niitä erillisillä käyttäjillä.
- Lisää tietosuojaseloste ja yhteystiedot ennen julkista jakelua.
- Älä koskaan julkaise `service_role`-avainta selaimessa.

## Nykyisen version rajat

- Ottelun luoja tai ylläpitäjä aloittaa ottelun käyttöliittymästä. Tämän jälkeen vedonlyönti sulkeutuu. Tulos vahvistetaan erikseen.
- Kertoimet ovat ottelun luojan asettamat kiinteät kertoimet, eivät automaattisesti markkinan mukaan muuttuvat.
- Yksi veto per käyttäjä per ottelu.
- Pisteet ovat pelillisiä, eivät talletettavaa tai nostettavaa saldoa.
