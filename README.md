# LiveQuiz Pro

LiveQuiz Pro is a responsive quiz management app built with React, TypeScript, Vite and Supabase. The dashboard, quiz list, quiz creation, authentication wiring, QR join panel and database schema are included. Supabase is the persistence and authorization layer; the app does not silently substitute browser-only demo records when it is unconfigured.

## Current implementation

- Supabase email/password administrator sign-in.
- Quiz creation and listing backed by PostgreSQL.
- Responsive admin dashboard with database-backed participant and answer counts.
- Live controlled and self-paced quiz records, join codes, QR generation, question creation/editing/deletion, and JSON question import/export.
- Public participant join flow with optional phone field, random session tokens, same-device session recovery after logout or refresh, local recovery of unsent answer selections, polling for host state, and explicit session revocation when a participant forgets the device.
- Self-paced per-participant question navigation, with a quiz-wide deadline and state recovery after refresh.
- In self-paced quizzes, moving forward saves the selected answer, and the final question offers a single **Submit quiz** action.
- Host controls for waiting room, start/pause/resume, question reveal, previous/next, answer reveal, leaderboard visibility, and ending a quiz.
- Participant leaderboard standings are withheld during a quiz and can appear after the quiz is completed when enabled.
- Database-owned answer acceptance, overall quiz deadlines, paused timer remainder, hidden correct answers, and leaderboard output that never includes phone numbers (leaderboard display is enabled by default).
- Participant roster, score summary, CSV export, and per-question accuracy analytics.
- Projector route with a readable join QR/code, current question, and participant-safe leaderboard.
- SQL schema with RLS and narrowly scoped participant RPCs.
- Vitest tests for question import validation and the documented score formulas.

Scoring stores earned marks, speed multiplier, and total points separately. By default a correct answer earns the question's marks, and an incorrect or unanswered response earns zero. Optional speed points apply only when a question timer is enabled. With partial marking enabled, multiple select answers use the matched correct fraction minus the wrong selection fraction, clamped at zero; this rule takes precedence over the incorrect-answer penalty. Otherwise, negative marking subtracts the configured percentage of question marks for an incorrect answer. The RPC computes and stores the total points in the database. Each quiz has an overall duration; a question timer runs only when that question explicitly has a `time_limit_seconds` value.

This is still an incremental implementation of the full brief. Remaining major work includes autosaving unsent answer selections, detailed answer review after completion, scheduled starts, editable workspace settings, stronger participant abuse protection/rate limiting, and end-to-end browser and Supabase policy tests. Analytics currently covers core answer accuracy and awarded-points totals. UI styling uses responsive CSS rather than Tailwind utilities.

## Requirements

- Node.js 20 or newer and npm.
- A Supabase project for authentication and persistence.

## Local setup

```sh
npm install
cp .env.example .env.local
```

Set `VITE_SUPABASE_URL` and `VITE_SUPABASE_ANON_KEY` in `.env.local` using the Supabase project URL and publishable/anon key. These are public client configuration values; never put a service-role key or database password in Vite variables.

Apply the migration from the Supabase SQL editor or with the Supabase CLI:

```sh
supabase link --project-ref YOUR_PROJECT_REF
supabase db push
```

If the initial schema was already applied, run `supabase db push` again to apply the participant session recovery migration (`202610290002_resume_participant_sessions.sql`). A participant can resume from the same browser and device; recovery credentials are not shared across devices.

Create an administrator in Supabase Authentication, copy the Auth user's UUID, then insert its profile using the documented final SQL comment in `supabase/migrations/202610290001_initial_schema.sql`. Then run:

```sh
npm run dev
```

Set `VITE_PUBLIC_APP_URL` to the externally reachable app origin before generating production QR codes. For local device testing, use a LAN-accessible dev server address and ensure the phone can reach that computer.

## Build and hosting

```sh
npm test
npm run build
npm run preview
```

Question import accepts a JSON array of objects with `prompt`, `options`, `correct_answer`, and optional `type`, `points`, and `time_limit_seconds`. Supported types are `single_select`, `multiple_select`, and `true_false`. Use the **JSON template** button in the question bank for a ready-to-fill example. JSON export downloads the current quiz's questions.

### Deploy to Netlify

This repository includes `netlify.toml`, which configures the production build as `npm run build`, publishes `dist`, and rewrites app routes to `index.html` for React Router.

1. Push this project to a Git provider and import that repository in Netlify, or use Netlify CLI from the project directory with `netlify deploy --prod` after linking the site.
2. In Netlify, set the build command to `npm run build` and publish directory to `dist` (the checked-in `netlify.toml` already supplies these values).
3. In **Site configuration → Environment variables**, add:
   - `VITE_SUPABASE_URL` — your Supabase project URL.
   - `VITE_SUPABASE_ANON_KEY` — your Supabase publishable/anon key. This is intended for browser use with the project's RLS policies.
   - `VITE_PUBLIC_APP_URL` — optional. Leave it unset to use the current site origin automatically, or set it to the canonical public origin such as `https://your-site.netlify.app` (no trailing slash). Do not use a localhost or LAN address for a deployed site.
4. Trigger a new deploy after setting the variables. Vite embeds `VITE_` values at build time.
5. In Supabase **Authentication → URL Configuration**, set the deployed site URL and add the deployed origin (for example `https://your-site.netlify.app/**`) to the allowed redirect URLs. Keep the local development URL there too if you still use it.
6. Apply all SQL files in `supabase/migrations` to the Supabase project in filename order, or use the Supabase CLI (`supabase link --project-ref YOUR_PROJECT_REF` then `supabase db push`). Create the first admin and grant its profile as described in the initial migration.

Never add a Supabase secret/service-role key or database password to Netlify `VITE_` variables. Keep privileged keys on trusted server-side infrastructure only. Netlify hosts the frontend; authentication, database access, and public participant operations are provided by Supabase.

## Security notes

- RLS is enabled on all application tables. Admins only see quizzes they own.
- Public participant operations are mediated by RPCs. Join returns a high entropy session token once; clients should store it only for session recovery and must not put it in public quiz data or URLs.
- The migration does not provision an admin automatically. Manually grant the first admin after creating the Auth user.
- Review RLS and RPC behavior in a Supabase staging project before opening public participation. Participant rate limits and privacy/retention controls remain deployment work.

## Limitations

This repository was initialized without Node.js/npm in the available environment, so packages could not be installed and the TypeScript build could not be run here. Question bank editing, the participant experience, full scoring policy, live subscriptions, final results, exports and analytics remain to be completed. The database migration is an initial foundation and should be reviewed/applied in a test Supabase project before production use.
