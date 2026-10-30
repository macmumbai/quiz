# LiveQuiz Pro

LiveQuiz Pro is a responsive quiz management app built with React, TypeScript, Vite and Supabase. The dashboard, quiz list, quiz creation, authentication wiring, QR join panel and database schema are included. Supabase is the persistence and authorization layer; the app does not silently substitute browser-only demo records when it is unconfigured.

## Current implementation

- Supabase email/password administrator sign-in.
- Unified quiz workspace for editing quiz details, managing questions, opening sessions, reviewing runs, and exporting results.
- Replayable quiz sessions with separately preserved leaderboards and an explicit choice to create a fresh board or merge a new audience into the previous board.
- Controller-gated participant answer review with per-question explanations; submitted participants see points, marks, correct/wrong/attempted counts, elapsed time, and a rank that refreshes as others submit.
- Quiz makers can allow repeat attempts; otherwise, the same username plus supplied phone number is blocked within a quiz run. Returning participants explicitly choose to resume a saved device session rather than being sent directly to a prior score.
- Mode-aware host tools: question reveal and progression controls appear only for live-controlled quizzes, while live leaderboard data refreshes automatically.
- Quiz creation and listing backed by PostgreSQL.
- Responsive admin dashboard with database-backed participant and answer counts.
- Live controlled and self-paced quiz records, join codes, QR generation, question creation/editing/deletion, and JSON question import/export.
- Public participant join flow with optional phone field, random session tokens, same-device session recovery after logout or refresh, local recovery of unsent answer selections, polling for host state, and explicit session revocation when a participant forgets the device.
- Optional per-quiz reattempts. When disabled, the same trimmed username and supplied phone number cannot join the same run twice; phone formatting and username letter case are ignored. A returning device must explicitly choose to resume its saved session.
- Participants can join the active run until the host ends it. Each participant's time limit starts when they begin a live run; late joiners get their own full time window and share the same run leaderboard.
- Self-paced per-participant question navigation, with an individual time limit and state recovery after refresh.
- Pausing a run also pauses each active participant's personal timer; resuming adds the pause duration back to their remaining time.
- In self-paced quizzes, moving forward saves the selected answer, and the final question offers a single **Submit quiz** action.
- Host controls for waiting room, start/pause/resume, question reveal, previous/next, answer reveal, leaderboard visibility, and ending a quiz.
- Participant leaderboard standings are withheld during a quiz and can appear after the quiz is completed when enabled.
- Database-owned answer acceptance, overall quiz deadlines, paused timer remainder, hidden correct answers, and leaderboard output that never includes phone numbers (leaderboard display is enabled by default).
- Participant roster, score summary, CSV export, and per-question accuracy analytics.
- Full-screen projector route with Join QR and live leaderboard tabs, rank/points for every participant in the active leaderboard group, and animated score changes.
- SQL schema with RLS and narrowly scoped participant RPCs.
- Vitest tests for question import validation and the documented score formulas.

Scoring stores earned marks, speed multiplier, and total points separately. By default a correct answer earns the question's marks, and an incorrect or unanswered response earns zero. Optional speed points apply only when a question timer is enabled. With partial marking enabled, multiple select answers use the matched correct fraction minus the wrong selection fraction, clamped at zero; this rule takes precedence over the incorrect-answer penalty. Otherwise, negative marking subtracts the configured percentage of question marks for an incorrect answer. The RPC computes and stores the total points in the database. The configured duration applies separately to each participant; a question timer runs only when that question explicitly has a `time_limit_seconds` value.

This is still an incremental implementation of the full brief. Remaining major work includes autosaving unsent answer selections, scheduled starts, editable workspace settings, stronger participant abuse protection/rate limiting, and end-to-end Supabase policy tests. Analytics currently covers core answer accuracy and awarded-points totals. UI styling uses responsive CSS rather than Tailwind utilities.

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

If the initial schema was already applied, run `supabase db push` again to apply all later migrations. In particular, `202610290011_quiz_runs_review.sql` adds replayable sessions, separate/mergeable leaderboard groups, question explanations, and gated answer review. A participant can resume from the same browser and device; recovery credentials are not shared across devices.

If the app reports that `quizzes.active_run_id` or `quiz_runs` is missing, the migration has not been applied to the Supabase project configured in `.env.local`. Link the CLI to that exact project and run `supabase db push`, or run the migration files in order in that project's SQL Editor. Refresh the app after the migration completes successfully.

If the database schema or migration history was cleared and you want to rebuild it from scratch, authenticate the Supabase CLI locally and reset the linked project:

```sh
npx supabase login
npx supabase link --project-ref YOUR_PROJECT_REF
npx supabase db reset --linked
```

`db reset --linked` deletes existing database objects/data before replaying all checked-in migrations. It does not delete Supabase Auth users. Afterward, provision your existing administrator profile in the Supabase SQL Editor (replace the email with the administrator account):

```sql
insert into public.profiles (id, display_name, role)
select id, coalesce(raw_user_meta_data->>'name', split_part(email, '@', 1)), 'admin'
from auth.users
where email = 'YOUR_ADMIN_EMAIL'
on conflict (id) do nothing;
```

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

Database migrations and auth redirect settings must be applied to the intended Supabase project before these flows are available. Participant and leaderboard updates use short polling intervals; production end-to-end behavior should be verified against a staging Supabase project before rollout.
