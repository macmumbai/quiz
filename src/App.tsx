import { useCallback, useEffect, useMemo, useRef, useState, type FormEvent } from 'react';
import { Navigate, NavLink, Route, Routes, useLocation, useNavigate, useParams } from 'react-router-dom';
import { Activity, ArrowDownToLine, ArrowUpFromLine, BarChart3, Bell, BookOpen, Check, ChevronDown, CircleHelp, Clock3, Copy, ExternalLink, FileQuestion, Gamepad2, LayoutDashboard, LogOut, Maximize2, Menu, Minimize2, Plus, QrCode, Search, Settings, ShieldCheck, Sparkles, Trash2, Trophy, Users, X } from 'lucide-react';
import { QRCodeSVG } from 'qrcode.react';
import { isConfigured, supabase } from './lib/supabase';
import { questionImportSchema } from './lib/validation';

type QuizSettings = { total_time_seconds?: number; allow_navigation?: boolean; allow_answer_changes?: boolean; allow_reattempts?: boolean; show_leaderboard?: boolean; scoring?: { speed_points_enabled?: boolean; partial_marking?: boolean; negative_marking_percent?: number }; [key: string]: unknown };
type Quiz = { id: string; title: string; mode: string; status: string; participants: number; attempts?: number; created_at: string; description?: string; join_code?: string; current_question_id?: string | null; active_run_id?: string; settings?: QuizSettings };
const migrationHint = 'Database setup required. Run `npx supabase login`, then link the project from VITE_SUPABASE_URL and run `npx supabase db reset --linked` to rebuild its schema from the checked-in migrations. This resets app database data; Auth users remain.';
const supabaseProjectRef = import.meta.env.VITE_SUPABASE_URL?.match(/^https:\/\/([^.]+)\.supabase\.co/)?.[1] || '<project-ref>';
const isQuizMigrationError = (message: string) => {
  const normalized = message.toLowerCase();
  return ['active_run_id', 'quiz_runs', 'run_id', 'review_enabled', 'participant_finish', 'admin_quiz_control', 'explanation']
    .some(field => normalized.includes(field))
    && ['does not exist', 'could not find', 'schema cache', 'unknown', 'not found']
      .some(marker => normalized.includes(marker));
};
const sections = [
  { path: '/', label: 'Dashboard', icon: LayoutDashboard },
  { path: '/quizzes', label: 'Quizzes', icon: BookOpen },
  { path: '/participants', label: 'Participants', icon: Users },
  { path: '/results', label: 'Results', icon: BarChart3 },
  { path: '/analytics', label: 'Analytics', icon: Activity },
];

export default function App() {
  const [user, setUser] = useState<string | null>(null), [quizzes, setQuizzes] = useState<Quiz[]>([]), [loading, setLoading] = useState(false), [mobileOpen, setMobileOpen] = useState(false), [modal, setModal] = useState(false), [toast, setToast] = useState(''), [search, setSearch] = useState(''), [schemaNeedsUpdate, setSchemaNeedsUpdate] = useState(false);
  const navigate = useNavigate(), location = useLocation();
  const show = useCallback((msg: string) => { if (isQuizMigrationError(msg)) setSchemaNeedsUpdate(true); setToast(isQuizMigrationError(msg) ? migrationHint : msg); window.setTimeout(() => setToast(''), 6000); }, []);
  const refresh = useCallback(async () => { if (!supabase) return; setLoading(true); const [quizResult, participantResult, answerResult] = await Promise.all([supabase.from('quizzes').select('id,title,mode,status,created_at,description,join_code,current_question_id,active_run_id,settings').order('created_at', { ascending: false }), supabase.from('participants').select('quiz_id,run_id,status'), supabase.from('answers').select('quiz_id')]); if (quizResult.error) show(quizResult.error.message); else if (participantResult.error || answerResult.error) show(participantResult.error?.message || answerResult.error?.message || 'Could not load dashboard counts.'); else { setSchemaNeedsUpdate(false); const attempts = new Map<string, number>(); for (const a of answerResult.data || []) attempts.set(a.quiz_id, (attempts.get(a.quiz_id) || 0) + 1); setQuizzes((quizResult.data || []).map(q => ({ ...q, participants: (participantResult.data || []).filter(p => p.run_id === q.active_run_id && p.status !== 'logged_out').length, attempts: attempts.get(q.id) || 0 }))); } setLoading(false); }, [show]);
  useEffect(() => { if (!supabase) return; supabase.auth.getSession().then(({ data }) => setUser(data.session?.user.email || null)); const { data: { subscription } } = supabase.auth.onAuthStateChange((_e, s) => setUser(s?.user.email || null)); return () => subscription.unsubscribe(); }, []);
  useEffect(() => { if (user) refresh(); }, [user]);
  const logout = async () => { await supabase?.auth.signOut(); setUser(null) };
  const filtered = useMemo(() => quizzes.filter(q => q.title.toLowerCase().includes(search.toLowerCase())), [quizzes, search]);
  if (location.pathname.startsWith('/join/')) return <Routes><Route path="/join/:code" element={<ParticipantJoin />} /></Routes>;
  if (location.pathname.startsWith('/projector/')) return <Routes><Route path="/projector/:code" element={<Projector />} /></Routes>;
  if (!user) return <Login onLogin={setUser} />;
  return <div className="app-shell">
    <aside className={`sidebar ${mobileOpen ? 'open' : ''}`}><div className="brand"><div className="brand-mark"><Sparkles size={23} /></div><div><b>LiveQuiz <span>Pro</span></b><small>QUIZ MANAGEMENT</small></div><button className="mobile-close" onClick={() => setMobileOpen(false)}><X /></button></div>
      <div className="workspace"><div className="workspace-icon">L</div><div><b>Learning workspace</b><small>Administrator</small></div><ChevronDown size={15} /></div>
      <div className="nav-label">WORKSPACE</div><nav>{sections.map(item => <NavLink onClick={() => setMobileOpen(false)} key={item.path} to={item.path} end={item.path === '/'} className={({ isActive }) => `nav-item ${isActive ? 'active' : ''}`}><item.icon size={17} /><span>{item.label}</span></NavLink>)}</nav>
      <div className="nav-label management-label">MANAGE</div><NavLink to="/settings" className={({ isActive }) => `nav-item ${isActive ? 'active' : ''}`}><Settings size={17} />Settings</NavLink>
      <div className="sidebar-bottom"><div className="help-card"><div className="help-icon"><CircleHelp size={17} /></div><b>Need a hand?</b><p>Explore the guide to get started with LiveQuiz.</p><button onClick={() => show('Help center: see the README for setup instructions.')}>Open help center <span>→</span></button></div><div className="profile"><div className="avatar">{user.slice(0, 1).toUpperCase()}</div><div className="profile-info"><b>{user.split('@')[0]}</b><small>Administrator</small></div><button className="icon-button" title="Sign out" onClick={logout}><LogOut size={16} /></button></div></div>
    </aside><div className="mobile-scrim" onClick={() => setMobileOpen(false)}></div>
    <main className="main"><header className="topbar"><button className="menu-toggle icon-button" onClick={() => setMobileOpen(true)}><Menu /></button><div className="crumb">Workspace <span>/</span> <b>Overview</b></div><div className="top-actions"><div className="connection"><i /> Live data</div><button className="icon-button bell" onClick={() => show('You’re all caught up.')}><Bell size={18} /><i /></button><div className="top-user"><div className="avatar small">{user.slice(0, 1).toUpperCase()}</div><ChevronDown size={14} /></div></div></header>
      <div className="page">{schemaNeedsUpdate ? <section className="panel migration-required"><div className="migration-icon"><ShieldCheck size={22} /></div><div className="eyebrow">DATABASE SETUP</div><h1>Rebuild the quiz database</h1><p>The connected database is missing tables or columns required by this app. Apply the checked-in migrations to the Supabase project whose URL is in <code>.env.local</code>.</p><div className="migration-command"><code>npx supabase login</code><span>Sign in using your local terminal</span></div><div className="migration-command"><code>npx supabase link --project-ref {supabaseProjectRef}</code><span>Matches VITE_SUPABASE_URL</span></div><div className="migration-command migration-destructive"><code>npx supabase db reset --linked</code><span>Rebuilds schema and clears app data; Auth users remain</span></div><p className="migration-alternative">You authorized resetting the app database. After reset, re-add your administrator profile in Supabase SQL Editor using the existing Auth user’s UUID, then refresh this page.</p><button className="primary" onClick={refresh} disabled={loading}>{loading ? 'Checking…' : 'Check again'} <Activity size={16} /></button></section> : <Routes><Route path="/" element={<Dashboard quizzes={quizzes} loading={loading} onCreate={() => setModal(true)} onNavigate={navigate} onRefresh={refresh} />} /><Route path="/quizzes" element={<Quizzes quizzes={filtered} search={search} setSearch={setSearch} onCreate={() => setModal(true)} onRefresh={refresh} show={show} />} /><Route path="/quizzes/:quizId" element={<QuizWorkspace quizzes={quizzes} show={show} onRefresh={refresh} />} /><Route path="/questions" element={<Navigate to="/quizzes" replace />} /><Route path="/live" element={<Navigate to="/quizzes" replace />} /><Route path="/join/:code" element={<ParticipantJoin />} /><Route path="/participants" element={<ResultsPage quizzes={quizzes} show={show} participantsOnly />} /><Route path="/results" element={<ResultsPage quizzes={quizzes} show={show} />} /><Route path="/analytics" element={<AnalyticsPage quizzes={quizzes} show={show} />} /><Route path="/history" element={<Navigate to="/quizzes" replace />} /><Route path="/settings" element={<SettingsPage />} /></Routes>}</div>
    </main>{modal && <CreateQuiz onClose={() => setModal(false)} onCreated={() => { setModal(false); refresh(); show('Quiz created.') }} show={show} />} {toast && <div className="toast"><Check size={16} />{toast}</div>}
  </div>
}

function Login({ onLogin }: { onLogin: (e: string | null) => void }) {
  const [email, setEmail] = useState(''), [password, setPassword] = useState(''), [busy, setBusy] = useState(false), [error, setError] = useState('');
  const submit = async (e: FormEvent) => {
    e.preventDefault();
    if (!supabase) { setError('Connect Supabase to sign in. Add your project URL and anon key to .env.local.'); return }
    setBusy(true);
    setError('');
    try {
      const { data, error } = await supabase.auth.signInWithPassword({ email: email.trim(), password });
      if (error) setError(error.message);
      else onLogin(data.user.email || email.trim());
    } catch (cause) {
      setError(cause instanceof Error ? cause.message : 'Unable to sign in. Check your connection and try again.');
    } finally {
      setBusy(false);
    }
  };
  return <div className="login"><div className="login-card"><section className="login-art"><div className="brand-mark large"><Sparkles size={30} /></div><div><b>LiveQuiz <span>Pro</span></b><small>Real-time quizzes. Real connection.</small></div><div className="art-graphic"><div className="orbit o1" /><div className="orbit o2" /><div className="trophy-orb"><Trophy size={42} /></div><div className="float-card fc1"><Users size={15} /> 48 playing</div><div className="float-card fc2"><Activity size={15} /> Live insights</div></div><p>Bring people together through<br />the power of play.</p><div className="art-foot">COMPETE <i /> LEARN <i /> GROW</div></section><section className="login-form"><div className="form-head"><div className="eyebrow">ADMIN PORTAL</div><h1>Welcome back</h1><p>Sign in to manage your quizzes and competitions.</p></div><div className="role-toggle"><button className="selected">Administrator</button><button disabled title="Participant joining is available via a quiz link">Participant</button></div><form onSubmit={submit}><label>Email address</label><input autoComplete="email" type="email" required placeholder="you@example.com" value={email} onChange={e => setEmail(e.target.value)} /><label>Password</label><input autoComplete="current-password" type="password" required placeholder="Enter your password" value={password} onChange={e => setPassword(e.target.value)} /><div className="remember"><label><input type="checkbox" /> Remember me</label><button type="button" onClick={() => setError('Password reset is handled through your Supabase email settings.')}>Forgot password?</button></div>{error && <div className="error">{error}</div>}<button className="primary full" disabled={busy}>{busy ? 'Signing in…' : 'Sign in'} <span>→</span></button></form><div className="login-note"><ShieldCheck size={15} /> Secured with Supabase authentication</div><div className="login-foot">New to LiveQuiz Pro? <button onClick={() => setError('Ask your workspace administrator to create your admin account in Supabase Auth.')}>Contact your administrator</button></div></section></div><div className="login-caption">© 2026 LiveQuiz Pro <span>•</span> Play. Learn. Achieve.</div></div>
}

function Dashboard({ quizzes, loading, onCreate, onNavigate, onRefresh }: { quizzes: Quiz[]; loading: boolean; onCreate: () => void; onNavigate: (p: string) => void; onRefresh: () => void }) {
  const counts = [{ label: 'Total quizzes', value: quizzes.length, icon: <BookOpen />, tone: 'blue' }, { label: 'Participants', value: quizzes.reduce((sum, q) => sum + q.participants, 0), icon: <Users />, tone: 'green' }, { label: 'Completed quizzes', value: quizzes.filter(q => q.status === 'completed').length, icon: <Check />, tone: 'amber' }, { label: 'Total attempts', value: quizzes.reduce((sum, q) => sum + (q.attempts || 0), 0), icon: <Activity />, tone: 'purple' }];
  return <><div className="page-heading"><div><div className="eyebrow">{new Date().toLocaleDateString(undefined, { weekday: 'long', month: 'long', day: 'numeric', year: 'numeric' }).toUpperCase()}</div><h1>Good to see you <span className="wave">✦</span></h1><p>Here’s what’s happening with your quizzes today.</p></div><button className="primary" onClick={onCreate}><Plus size={17} /> Create new quiz</button></div><div className="stats">{counts.map(c => <div className="stat-card" key={c.label}><div className={`stat-icon ${c.tone}`}>{c.icon}</div><div className="stat-label">{c.label}</div><div className="stat-value">{loading ? '—' : c.value.toLocaleString()}</div><div className="stat-foot">{c.label === 'Total quizzes' ? 'Across your workspace' : 'Updates as participants join'}</div></div>)}</div><div className="dashboard-grid"><section className="panel recent"><div className="panel-head"><div><h2>Recent quizzes</h2><p>Your latest quiz activity</p></div><button className="text-button" onClick={() => onNavigate('/quizzes')}>View all <span>→</span></button></div>{quizzes.length === 0 ? <div className="empty-state"><div className="empty-icon"><BookOpen size={21} /></div><b>{loading ? 'Loading your quizzes…' : 'No quizzes yet'}</b><p>Create your first quiz to see it here.</p>{!loading && <button className="secondary" onClick={onCreate}><Plus size={15} /> Create a quiz</button>}</div> : <div className="table-wrap"><table><thead><tr><th>QUIZ NAME</th><th>MODE</th><th>STATUS</th><th>PARTICIPANTS</th><th>CREATED</th></tr></thead><tbody>{quizzes.slice(0, 5).map(q => <tr key={q.id}><td><b>{q.title}</b></td><td>{q.mode === 'self_paced' ? 'Self-Paced' : 'Live Controlled'}</td><td><span className={`badge ${q.status}`}>{q.status.replace('_', ' ')}</span></td><td>{q.participants}</td><td>{new Date(q.created_at).toLocaleDateString()}</td></tr>)}</tbody></table></div>}</section><section className="panel quick"><div className="panel-head"><div><h2>Quick actions</h2><p>Jump back into your workflow</p></div></div><button className="quick-action purple-action" onClick={onCreate}><span><Plus size={16} /></span><div><b>Create new quiz</b><small>Start from a blank quiz</small></div><span className="qa-arrow">→</span></button><button className="quick-action blue-action" onClick={() => onNavigate('/quizzes')}><span><Gamepad2 size={16} /></span><div><b>Manage a quiz</b><small>Edit questions and open its session</small></div><span className="qa-arrow">→</span></button><button className="quick-action green-action" onClick={() => onNavigate('/results')}><span><Trophy size={16} /></span><div><b>View leaderboard</b><small>See quiz performance</small></div><span className="qa-arrow">→</span></button><button className="quick-action cyan-action" onClick={() => onNavigate('/analytics')}><span><BarChart3 size={16} /></span><div><b>View analytics</b><small>Explore quiz insights</small></div><span className="qa-arrow">→</span></button></section></div><div className="connection-banner"><div className="banner-icon"><ShieldCheck size={18} /></div><div><b>{isConfigured ? 'Supabase connected' : 'Connect your Supabase project'}</b><p>{isConfigured ? 'Your quiz data is loaded securely from your database.' : 'Add your Supabase credentials to enable database persistence and sign-in.'}</p></div>{!isConfigured ? <span className="banner-code">.env.local</span> : <button className="icon-button" onClick={onRefresh}><Activity size={16} /></button>}</div></>
}

function Quizzes({ quizzes, search, setSearch, onCreate, onRefresh, show }: { quizzes: Quiz[]; search: string; setSearch: (s: string) => void; onCreate: () => void; onRefresh: () => void; show: (message: string) => void }) {
  const navigate = useNavigate();
  const deleteQuiz = async (quiz: Quiz) => {
    const confirmed = window.confirm(`Permanently delete “${quiz.title}” (${quiz.status})? Its questions, participants, and results will also be deleted.`);
    if (!confirmed) return;
    if (!supabase) { show('Connect Supabase before deleting quizzes.'); return; }
    const { error } = await supabase.from('quizzes').delete().eq('id', quiz.id);
    if (error) show(error.message);
    else { show(`“${quiz.title}” and its saved results were deleted.`); onRefresh(); }
  };
  return <><div className="page-heading"><div><div className="eyebrow">YOUR WORKSPACE</div><h1>Quizzes</h1><p>Create a quiz, manage its questions and run it from one place.</p></div><button className="primary" onClick={onCreate}><Plus size={17} /> Create new quiz</button></div><section className="panel list-panel"><div className="list-toolbar"><div className="searchbox"><Search size={16} /><input placeholder="Search quizzes…" value={search} onChange={e => setSearch(e.target.value)} /></div><button className="secondary" onClick={onRefresh}><Activity size={15} /> Refresh</button><button className="secondary" onClick={() => { const blob = new Blob([JSON.stringify(quizzes, null, 2)], { type: 'application/json' }); const a = document.createElement('a'); a.href = URL.createObjectURL(blob); a.download = 'quizzes.json'; a.click(); URL.revokeObjectURL(a.href) }}><ArrowDownToLine size={15} /> Export list</button></div>{quizzes.length ? <div className="table-wrap"><table><thead><tr><th>QUIZ NAME</th><th>MODE</th><th>STATUS</th><th>PARTICIPANTS</th><th>CREATED</th><th></th></tr></thead><tbody>{quizzes.map(q => <tr key={q.id}><td><button className="quiz-open-link" onClick={() => navigate(`/quizzes/${q.id}`)}><b>{q.title}</b><small className="row-sub">{q.description || 'Open quiz details'}</small></button></td><td>{q.mode === 'self_paced' ? 'Self-paced' : 'Live controlled'}</td><td><span className={`badge ${q.status}`}>{q.status.replace('_', ' ')}</span></td><td>{q.participants}</td><td>{new Date(q.created_at).toLocaleDateString()}</td><td><div className="quiz-actions"><button title="Open quiz" aria-label={`Open ${q.title}`} className="icon-button" onClick={() => navigate(`/quizzes/${q.id}`)}><ExternalLink size={16} /></button><button title="Delete quiz" aria-label={`Delete ${q.title}`} className="icon-button delete-icon" onClick={() => deleteQuiz(q)}><Trash2 size={16} /></button></div></td></tr>)}</tbody></table></div> : <div className="empty-state"><div className="empty-icon"><BookOpen size={21} /></div><b>No quizzes found</b><p>Create a quiz to get started.</p><button className="secondary" onClick={onCreate}><Plus size={15} /> Create a quiz</button></div>}</section></>
}

function QuizWorkspace({ quizzes, show, onRefresh }: { quizzes: Quiz[]; show: (message: string) => void; onRefresh: () => void }) {
  const { quizId = '' } = useParams();
  const navigate = useNavigate();
  const quiz = quizzes.find(item => item.id === quizId);
  const modeLocked = ['waiting_room', 'live', 'paused'].includes(quiz?.status || '');
  const [tab, setTab] = useState<'details' | 'questions' | 'session' | 'results'>('details');
  const [title, setTitle] = useState('');
  const [description, setDescription] = useState('');
  const [mode, setMode] = useState<'live_controlled' | 'self_paced'>('live_controlled');
  const [duration, setDuration] = useState(15);
  const [allowReattempts, setAllowReattempts] = useState(false);
  const [saving, setSaving] = useState(false);

  useEffect(() => {
    if (!quiz) return;
    setTitle(quiz.title);
    setDescription(quiz.description || '');
    setMode(quiz.mode === 'self_paced' ? 'self_paced' : 'live_controlled');
    setDuration(Math.max(1, Math.round((quiz.settings?.total_time_seconds || 900) / 60)));
    setAllowReattempts(quiz.settings?.allow_reattempts === true);
  }, [quiz?.id, quiz?.title, quiz?.description, quiz?.mode, quiz?.settings?.total_time_seconds, quiz?.settings?.allow_reattempts]);

  const saveDetails = async (event: FormEvent) => {
    event.preventDefault();
    if (!supabase || !quiz) return;
    setSaving(true);
    const settings = { ...(quiz.settings || {}), total_time_seconds: duration * 60, allow_reattempts: allowReattempts };
    const { error } = await supabase.from('quizzes').update({
      title: title.trim(),
      description: description.trim(),
      mode,
      settings,
    }).eq('id', quiz.id);
    setSaving(false);
    if (error) { show(error.message); return; }
    show('Quiz details saved.');
    onRefresh();
  };

  if (!quiz) return <div className="panel placeholder"><div className="placeholder-icon"><BookOpen /></div><h2>Quiz not found</h2><p>It may have been deleted, or the link is incorrect.</p><button className="secondary" onClick={() => navigate('/quizzes')}>Back to quizzes</button></div>;

  return <>
    <div className="workspace-heading"><button className="back-link" onClick={() => navigate('/quizzes')}>← All quizzes</button><div className="page-heading"><div><div className="eyebrow">{quiz.mode === 'self_paced' ? 'SELF-PACED QUIZ' : 'LIVE CONTROLLED QUIZ'}</div><h1>{quiz.title}</h1><p>{quiz.description || 'Manage quiz details, questions, participants and session.'}</p></div><span className={`badge ${quiz.status}`}>{quiz.status.replace('_', ' ')}</span></div></div>
    <div className="quiz-workspace-tabs" role="tablist" aria-label="Quiz workspace">
      {([['details', 'Details'], ['questions', 'Questions'], ['session', 'Go live'], ['results', 'Results']] as const).map(([key, label]) => <button key={key} role="tab" aria-selected={tab === key} className={tab === key ? 'selected' : ''} onClick={() => setTab(key)}>{label}</button>)}
    </div>
    {tab === 'details' && <form className="panel quiz-details-form" onSubmit={saveDetails}>
      <div className="panel-head"><div><h2>Quiz details</h2><p>Edit the quiz setup before or after a session.</p></div></div>
      <label>Quiz title</label><input required maxLength={120} value={title} onChange={event => setTitle(event.target.value)} />
      <label>Description</label><textarea rows={3} maxLength={500} value={description} onChange={event => setDescription(event.target.value)} />
      <label>Quiz mode</label><div className="mode-options"><button type="button" disabled={modeLocked} className={mode === 'live_controlled' ? 'mode-selected' : ''} onClick={() => setMode('live_controlled')}><Gamepad2 size={18} /><b>Live controlled</b><small>Host controls question progression.</small></button><button type="button" disabled={modeLocked} className={mode === 'self_paced' ? 'mode-selected' : ''} onClick={() => setMode('self_paced')}><Clock3 size={18} /><b>Self-paced</b><small>Participants move through questions themselves.</small></button></div>
      <label>Time per participant (minutes)</label><input type="number" min="1" max="1440" value={duration} onChange={event => setDuration(Number(event.target.value))} />
      <label className="setting-check reattempt-setting"><input type="checkbox" checked={allowReattempts} onChange={event => setAllowReattempts(event.target.checked)} /><span><b>Allow participant reattempts</b><small>When disabled, a participant can’t join this quiz run again with both the same username and phone number.</small></span></label>
      <div className="question-form-actions"><button className="primary" disabled={saving || !title.trim() || duration < 1}>{saving ? 'Saving…' : 'Save details'} <Check size={16} /></button></div>
    </form>}
    {tab === 'questions' && <QuestionBank quizzes={quizzes} show={show} selectedQuizId={quiz.id} embedded />}
    {tab === 'session' && <Live quizzes={quizzes} show={show} onRefresh={onRefresh} selectedQuizId={quiz.id} embedded />}
    {tab === 'results' && <ResultsPage quizzes={quizzes} show={show} initialQuizId={quiz.id} />}
  </>;
}

type ParticipantRow = { id: string; display_name: string; joined_at: string; status: string; run_id: string };
type AnswerRow = { participant_id: string; question_id: string; is_correct: boolean; marks_awarded: number; speed_points: number; points_awarded: number; submitted_at: string };
type QuizRunRow = { id: string; run_number: number; leaderboard_group_id: string; status: string; review_enabled: boolean; created_at: string };
function ResultsPage({ quizzes, show, participantsOnly = false, initialQuizId }: { quizzes: Quiz[]; show: (s: string) => void; participantsOnly?: boolean; initialQuizId?: string }) {
  const [quizId, setQuizId] = useState(initialQuizId || ''), [runId, setRunId] = useState(''), [runs, setRuns] = useState<QuizRunRow[]>([]), [people, setPeople] = useState<ParticipantRow[]>([]), [answers, setAnswers] = useState<AnswerRow[]>([]), [search, setSearch] = useState(''), [loading, setLoading] = useState(false);
  useEffect(() => { if (initialQuizId) setQuizId(initialQuizId); else if (!quizId && quizzes.length) setQuizId(quizzes[0].id) }, [initialQuizId, quizId, quizzes]);
  const activeRunId = quizzes.find(item => item.id === quizId)?.active_run_id;
  useEffect(() => {
    if (!supabase || !quizId) return;
    let mounted = true;
    supabase.from('quiz_runs').select('id,run_number,leaderboard_group_id,status,review_enabled,created_at').eq('quiz_id', quizId).order('run_number', { ascending: false }).then(({ data, error }) => {
      if (!mounted) return;
      if (error) { show(error.message); return }
      const loaded = (data || []) as QuizRunRow[];
      setRuns(loaded);
      setRunId(activeRunId || loaded[0]?.id || '');
    });
    return () => { mounted = false };
  }, [quizId, activeRunId, show]);
  useEffect(() => {
    if (!supabase || !quizId || !runId) { setPeople([]); setAnswers([]); return }
    const client = supabase;
    let mounted = true;
    const loadResults = async () => {
      const selectedRun = runs.find(run => run.id === runId);
      const groupRunIds = runs.filter(run => run.leaderboard_group_id === selectedRun?.leaderboard_group_id).map(run => run.id);
      if (!groupRunIds.length) return;
      setLoading(true);
      const participantResult = await client.from('participants').select('id,display_name,joined_at,status,run_id').eq('quiz_id', quizId).in('run_id', groupRunIds);
      if (!mounted) return;
      if (participantResult.error) { setLoading(false); show(participantResult.error.message); return }
      const participantRows = (participantResult.data || []) as ParticipantRow[];
      const answerResult = participantRows.length
        ? await client.from('answers').select('participant_id,question_id,is_correct,marks_awarded,speed_points,points_awarded,submitted_at').eq('quiz_id', quizId).in('participant_id', participantRows.map(person => person.id))
        : { data: [], error: null };
      if (!mounted) return;
      setLoading(false);
      if (answerResult.error) { show(answerResult.error.message); return }
      setPeople(participantRows);
      setAnswers((answerResult.data || []) as AnswerRow[]);
    };
    void loadResults();
    const timer = window.setInterval(() => { void loadResults(); }, 1500);
    return () => { mounted = false; window.clearInterval(timer) };
  }, [quizId, runId, runs, show]);
  const rows = useMemo(() => people.map(p => { const own = answers.filter(a => a.participant_id === p.id); return { ...p, score: own.reduce((sum, a) => sum + Number(a.points_awarded || 0), 0), marks: own.reduce((sum, a) => sum + Number(a.marks_awarded || 0), 0), avgSpeed: own.length ? own.reduce((sum, a) => sum + Number(a.speed_points || 1), 0) / own.length : 1, answered: own.length, correct: own.filter(a => a.is_correct).length } }).filter(p => p.display_name.toLowerCase().includes(search.toLowerCase())).sort((a, b) => b.score - a.score || a.joined_at.localeCompare(b.joined_at)), [people, answers, search]);
  const quiz = quizzes.find(q => q.id === quizId), selectedRun = runs.find(run => run.id === runId);
  const exportCsv = () => { const csv = [['Rank', 'Participant', 'Score', 'Marks', 'Average speed multiplier', 'Answered', 'Correct', 'Status', 'Joined'], ...rows.map((r, i) => [String(i + 1), r.display_name, String(r.score), String(r.marks), `${r.avgSpeed.toFixed(1)}x`, String(r.answered), String(r.correct), r.status, r.joined_at])].map(row => row.map(v => `"${v.replace(/"/g, '""')}"`).join(',')).join('\r\n'); const url = URL.createObjectURL(new Blob([csv], { type: 'text/csv' })); const a = document.createElement('a'); a.href = url; a.download = `${quiz?.title || 'quiz'}-results.csv`; a.click(); URL.revokeObjectURL(url) };
  return <><div className="page-heading"><div><div className="eyebrow">{participantsOnly ? 'LIVE ROSTER' : 'PERFORMANCE'}</div><h1>{participantsOnly ? 'Participants' : 'Quiz results'}</h1><p>{participantsOnly ? 'See who has joined and their current activity.' : 'Review participant scores and export results.'}</p></div><button className="secondary" onClick={exportCsv} disabled={!rows.length}><ArrowDownToLine size={15} /> Export CSV</button></div><div className="question-quiz-select"><label>QUIZ</label><select value={quizId} onChange={e => setQuizId(e.target.value)}><option value="">Select a quiz…</option>{quizzes.map(q => <option key={q.id} value={q.id}>{q.title}</option>)}</select>{quiz && <span className={`badge ${quiz.status}`}>{quiz.status.replace('_', ' ')}</span>}</div>{quizId && runs.length > 0 && <div className="question-quiz-select"><label>LEADERBOARD SESSION</label><select value={runId} onChange={e => setRunId(e.target.value)}>{runs.map(run => <option key={run.id} value={run.id}>Session {run.run_number}{runs.filter(item => item.leaderboard_group_id === run.leaderboard_group_id).length > 1 ? ' · merged leaderboard' : ''}</option>)}</select>{selectedRun?.review_enabled && <span className="badge completed">Review enabled</span>}</div>}{quizId ? <><div className="stats results-stats"><div className="stat-card"><div className="stat-icon blue"><Users /></div><div className="stat-label">Participants joined</div><div className="stat-value">{loading ? '—' : people.length}</div><div className="stat-foot">In this quiz</div></div><div className="stat-card"><div className="stat-icon green"><Check /></div><div className="stat-label">Answers submitted</div><div className="stat-value">{loading ? '—' : answers.length}</div><div className="stat-foot">Across questions</div></div><div className="stat-card"><div className="stat-icon amber"><Trophy /></div><div className="stat-label">Average score</div><div className="stat-value">{loading ? '—' : rows.length ? (rows.reduce((s, r) => s + r.score, 0) / rows.length).toFixed(1) : '0'}</div><div className="stat-foot">Points per participant</div></div><div className="stat-card"><div className="stat-icon purple"><Activity /></div><div className="stat-label">Completed entries</div><div className="stat-value">{loading ? '—' : people.filter(p => p.status === 'completed').length}</div><div className="stat-foot">Marked complete</div></div></div><section className="panel list-panel"><div className="list-toolbar"><div className="searchbox"><Search size={15} /><input placeholder="Search participants…" value={search} onChange={e => setSearch(e.target.value)} /></div><span className="list-count">{rows.length} participant{rows.length === 1 ? '' : 's'}</span></div>{rows.length ? <div className="table-wrap"><table><thead><tr><th>RANK</th><th>PARTICIPANT</th><th>TOTAL SCORE</th><th>ANSWERED</th><th>CORRECT</th><th>STATUS</th><th>JOINED</th></tr></thead><tbody>{rows.map((r, i) => <tr key={`${r.id}-${i}-${r.score}`}><td><span className={`rank rank-${i + 1}`}>{i + 1}</span></td><td><b>{r.display_name}</b></td><td><b>{r.score.toLocaleString()} pts</b><small className="row-sub">{r.marks.toLocaleString()} marks · {r.avgSpeed.toFixed(1)}× avg speed</small></td><td>{r.answered}</td><td>{r.correct}</td><td><span className={`badge ${r.status === 'active' ? 'live' : r.status === 'completed' ? 'completed' : 'draft'}`}>{r.status.replace('_', ' ')}</span></td><td>{new Date(r.joined_at).toLocaleString()}</td></tr>)}</tbody></table></div> : <div className="empty-state"><div className="empty-icon"><Users /></div><b>{loading ? 'Loading participants…' : 'No participants yet'}</b><p>Participants will appear after joining by quiz code or QR.</p></div>}</section></> : <div className="panel placeholder"><div className="placeholder-icon"><Trophy /></div><h2>Select a quiz to review</h2><p>Choose a quiz above to see its participants and scores.</p></div>}</>;
}
function AnalyticsPage({ quizzes, show }: { quizzes: Quiz[]; show: (s: string) => void }) {
  const [quizId, setQuizId] = useState(''), [questions, setQuestions] = useState<QuestionRow[]>([]), [answers, setAnswers] = useState<AnswerRow[]>([]), [loading, setLoading] = useState(false);
  useEffect(() => { if (!quizId && quizzes.length) setQuizId(quizzes[0].id) }, [quizId, quizzes]);
  useEffect(() => { if (!supabase || !quizId) return; let mounted = true; setLoading(true); Promise.all([supabase.from('questions').select('*').eq('quiz_id', quizId).order('position'), supabase.from('answers').select('participant_id,question_id,is_correct,points_awarded,submitted_at').eq('quiz_id', quizId)]).then(([q, a]) => { if (!mounted) return; setLoading(false); if (q.error || a.error) { show(q.error?.message || a.error?.message || 'Could not load analytics.'); return } setQuestions((q.data || []) as QuestionRow[]); setAnswers((a.data || []) as AnswerRow[]) }); return () => { mounted = false } }, [quizId]);
  const quiz = quizzes.find(q => q.id === quizId), participants = new Set(answers.map(a => a.participant_id)).size, accuracy = answers.length ? Math.round(answers.filter(a => a.is_correct).length / answers.length * 100) : 0;
  return <><div className="page-heading"><div><div className="eyebrow">INSIGHTS</div><h1>Analytics</h1><p>Question performance and scoring summary.</p></div></div><div className="question-quiz-select"><label>QUIZ</label><select value={quizId} onChange={e => setQuizId(e.target.value)}><option value="">Select a quiz…</option>{quizzes.map(q => <option key={q.id} value={q.id}>{q.title}</option>)}</select>{quiz && <span className={`badge ${quiz.status}`}>{quiz.status.replace('_', ' ')}</span>}</div>{quizId ? <><div className="stats results-stats"><div className="stat-card"><div className="stat-icon blue"><Users /></div><div className="stat-label">Participants answered</div><div className="stat-value">{loading ? '—' : participants}</div><div className="stat-foot">At least one answer</div></div><div className="stat-card"><div className="stat-icon green"><FileQuestion /></div><div className="stat-label">Questions</div><div className="stat-value">{loading ? '—' : questions.length}</div><div className="stat-foot">In this quiz</div></div><div className="stat-card"><div className="stat-icon amber"><Check /></div><div className="stat-label">Answer accuracy</div><div className="stat-value">{loading ? '—' : answers.length ? `${accuracy}%` : '—'}</div><div className="stat-foot">Correct / submitted</div></div><div className="stat-card"><div className="stat-icon purple"><Trophy /></div><div className="stat-label">Points awarded</div><div className="stat-value">{loading ? '—' : answers.reduce((sum, a) => sum + Number(a.points_awarded || 0), 0).toLocaleString()}</div><div className="stat-foot">Across all submissions</div></div></div><section className="panel performance-panel"><div className="panel-head"><div><h2>Question performance</h2><p>Correct response rate for each question</p></div></div>{questions.length ? <div className="performance-list">{questions.map(q => { const submitted = answers.filter(a => a.question_id === q.id), correct = submitted.filter(a => a.is_correct).length, rate = submitted.length ? Math.round(correct / submitted.length * 100) : 0; return <div className="performance-row" key={q.id}><div className="performance-copy"><span>Q{q.position}</span><b>{q.prompt}</b></div><div className="performance-bar"><i style={{ width: `${rate}%` }} /></div><div className="performance-value">{submitted.length ? `${rate}%` : '—'}<small>{correct}/{submitted.length} correct</small></div></div> })}</div> : <div className="empty-state"><div className="empty-icon"><FileQuestion /></div><b>{loading ? 'Loading analytics…' : 'No questions yet'}</b><p>Add quiz questions to collect performance data.</p></div>}</section></> : <div className="panel placeholder"><div className="placeholder-icon"><BarChart3 /></div><h2>Select a quiz to analyze</h2><p>Choose a quiz above to view question performance.</p></div>}</>;
}

type QuestionRow = { id: string; quiz_id: string; position: number; prompt: string; type: 'single_select' | 'multiple_select' | 'true_false'; options: string[]; correct_answer: string | string[]; explanation?: string; points: number; time_limit_seconds: number | null };
function QuestionBank({ quizzes, show, selectedQuizId, embedded = false }: { quizzes: Quiz[]; show: (s: string) => void; selectedQuizId?: string; embedded?: boolean }) {
  const [localQuizId, setLocalQuizId] = useState(selectedQuizId || ''), [items, setItems] = useState<QuestionRow[]>([]), [editing, setEditing] = useState<QuestionRow | null>(null), [prompt, setPrompt] = useState(''), [kind, setKind] = useState<QuestionRow['type']>('single_select'), [options, setOptions] = useState(['', '']), [correct, setCorrect] = useState<string | string[]>(''), [explanation, setExplanation] = useState(''), [points, setPoints] = useState(1), [time, setTime] = useState(''), [busy, setBusy] = useState(false), [search, setSearch] = useState('');
  const quizId = selectedQuizId || localQuizId;
  const currentQuiz = quizzes.find(q => q.id === quizId);
  const contentLocked = ['waiting_room', 'live', 'paused'].includes(currentQuiz?.status || '');
  useEffect(() => { if (selectedQuizId) setLocalQuizId(selectedQuizId); else if (!quizId && quizzes[0]) setLocalQuizId(quizzes[0].id) }, [quizzes, quizId, selectedQuizId]);
  const load = async () => { if (!supabase || !quizId) return; const { data, error } = await supabase.from('questions').select('*').eq('quiz_id', quizId).order('position'); if (error) { show(error.message); return } setItems((data || []) as QuestionRow[]) };
  useEffect(() => { load() }, [quizId]);
  const reset = () => { setEditing(null); setPrompt(''); setKind('single_select'); setOptions(['', '']); setCorrect(''); setExplanation(''); setPoints(1); setTime('') };
  const beginEdit = (q: QuestionRow) => { setEditing(q); setPrompt(q.prompt); setKind(q.type); setOptions(q.options); setCorrect(q.correct_answer); setExplanation(q.explanation || ''); setPoints(q.points); setTime(q.time_limit_seconds?.toString() || ''); window.scrollTo({ top: 0, behavior: 'smooth' }) };
  const save = async (e: FormEvent) => { e.preventDefault(); if (!supabase || !quizId) return; if (contentLocked) { show('Finish the active session before changing its questions.'); return } const cleanOptions = kind === 'true_false' ? ['True', 'False'] : options.map(o => o.trim()).filter(Boolean); if (cleanOptions.length < 2) { show('Add at least two answer options.'); return } let answer = correct; if (kind === 'true_false' && typeof answer === 'string' && !cleanOptions.includes(answer)) answer = ''; if (kind === 'multiple_select' && !Array.isArray(answer)) answer = []; if (kind !== 'multiple_select' && Array.isArray(answer)) answer = answer[0] || ''; if (!answer || (Array.isArray(answer) && !answer.length)) { show('Select the correct answer before saving.'); return } if (Array.isArray(answer) && answer.some(a => !cleanOptions.includes(a))) { show('Correct answers must match an option.'); return } if (typeof answer === 'string' && !cleanOptions.includes(answer)) { show('Choose the correct answer from the options.'); return } const payload = { quiz_id: quizId, position: editing?.position ?? (items.length + 1), prompt: prompt.trim(), type: kind, options: cleanOptions, correct_answer: answer, explanation: explanation.trim(), points, time_limit_seconds: time ? Number(time) : null }; setBusy(true); const result = editing ? await supabase.from('questions').update(payload).eq('id', editing.id) : await supabase.from('questions').insert(payload); setBusy(false); if (result.error) { show(result.error.message); return } show(editing ? 'Question updated.' : 'Question added.'); reset(); load() };
  const remove = async (q: QuestionRow) => { if (!supabase) return; if (contentLocked) { show('Finish the active session before changing its questions.'); return } const { error } = await supabase.from('questions').delete().eq('id', q.id); if (error) { show(error.message); return } show('Question deleted.'); load() };
  const importFile = async (file?: File) => { if (!file || !supabase || !quizId) return; if (contentLocked) { show('Finish the active session before changing its questions.'); return } try { const validated = questionImportSchema.parse(JSON.parse(await file.text())); const rows = validated.map((q, i) => ({ ...q, quiz_id: quizId, position: items.length + i + 1, time_limit_seconds: q.time_limit_seconds ?? null })); const { error } = await supabase.from('questions').insert(rows); if (error) throw error; show(`${rows.length} question${rows.length === 1 ? '' : 's'} imported.`); load() } catch (e) { const issues = e && typeof e === 'object' && 'issues' in e ? (e as { issues: { message: string; path?: PropertyKey[] }[] }).issues : null; show(issues ? `Invalid question JSON: ${issues.slice(0, 3).map(i => `${i.path?.length ? `${i.path.join('.')}: ` : ''}${i.message}`).join('; ')}` : e instanceof Error ? e.message : 'Could not import this JSON file.') } };
  const exportFile = () => { const data = items.map(({ prompt, type, options, correct_answer, explanation, points, time_limit_seconds }) => ({ prompt, type, options, correct_answer, explanation, points, time_limit_seconds })); const blob = new Blob([JSON.stringify(data, null, 2)], { type: 'application/json' }); const a = document.createElement('a'); a.href = URL.createObjectURL(blob); a.download = `${currentQuiz?.title || 'quiz'}-questions.json`; a.click(); URL.revokeObjectURL(a.href) };
  const filtered = items.filter(q => q.prompt.toLowerCase().includes(search.toLowerCase()));
  const downloadJsonTemplate = () => {
    const sample = [
      { prompt: 'Which planet is known as the Red Planet?', type: 'single_select', options: ['Mars', 'Venus', 'Jupiter', 'Saturn'], correct_answer: 'Mars', points: 10 },
      { prompt: 'Select the primary colors', type: 'multiple_select', options: ['Red', 'Blue', 'Green', 'Yellow'], correct_answer: ['Red', 'Blue', 'Yellow'], points: 5 },
    ];
    const url = URL.createObjectURL(new Blob([JSON.stringify(sample, null, 2)], { type: 'application/json' }));
    const link = document.createElement('a'); link.href = url; link.download = 'question-import-template.json'; link.click(); URL.revokeObjectURL(url);
  };
  return <>
    {!embedded && <div className="page-heading"><div><div className="eyebrow">QUIZ CONTENT</div><h1>Question bank</h1><p>Add, import, edit and organize questions for each quiz.</p></div>{quizId && <div className="question-toolbar"><button className="secondary" onClick={exportFile} disabled={!items.length}><ArrowDownToLine size={15} /> Export JSON</button><button className="secondary" onClick={downloadJsonTemplate}>JSON template</button><label className={`secondary import-button${contentLocked ? ' disabled' : ''}`} aria-disabled={contentLocked}><ArrowUpFromLine size={15} /> Import JSON<input type="file" accept="application/json,.json" disabled={contentLocked} onChange={e => { importFile(e.target.files?.[0]); e.currentTarget.value = '' }} /></label></div>}</div>}
    {embedded && quizId && <div className="question-toolbar question-toolbar-embedded"><span>{contentLocked ? 'Finish the active session before importing questions.' : 'Add several questions at once using a JSON file.'}</span><button className="secondary" onClick={exportFile} disabled={!items.length}><ArrowDownToLine size={15} /> Export JSON</button><button className="secondary" onClick={downloadJsonTemplate}>JSON template</button><label className={`secondary import-button${contentLocked ? ' disabled' : ''}`} aria-disabled={contentLocked}><ArrowUpFromLine size={15} /> Import JSON<input type="file" accept="application/json,.json" disabled={contentLocked} onChange={e => { importFile(e.target.files?.[0]); e.currentTarget.value = '' }} /></label></div>}
    {quizzes.length === 0 ? <div className="panel placeholder"><div className="placeholder-icon"><BookOpen /></div><h2>Create a quiz first</h2><p>Your question bank is organized by quiz. Create a quiz, then add questions here.</p></div> : <>
      {!selectedQuizId && <div className="question-quiz-select"><label>QUIZ</label><select value={quizId} onChange={e => { reset(); setLocalQuizId(e.target.value) }}>{quizzes.map(q => <option value={q.id} key={q.id}>{q.title}</option>)}</select><span className="badge draft">{items.length} questions</span></div>}
      <div className="question-layout">
        <form className="panel question-editor" onSubmit={save}><div className="panel-head"><div><h2>{editing ? 'Edit question' : 'Add a question'}</h2><p>Choose the correct answer and scoring value.</p></div>{editing && <button type="button" className="icon-button" onClick={reset}><X size={17} /></button>}</div>
          <label>Question text <em>*</em></label><textarea required maxLength={2000} rows={3} placeholder="Enter your question" value={prompt} onChange={e => setPrompt(e.target.value)} />
          <label>Answer explanation</label><textarea maxLength={2000} rows={2} placeholder="Explain why this answer is correct (shown after review is enabled)." value={explanation} onChange={e => setExplanation(e.target.value)} />
          <label>Question type</label><select value={kind} onChange={e => { const k = e.target.value as QuestionRow['type']; setKind(k); setCorrect(k === 'multiple_select' ? [] : '') }}><option value="single_select">Single select</option><option value="multiple_select">Multiple select</option><option value="true_false">True / False</option></select>
          {kind === 'true_false' ? <div className="tf-hint">Answer options are True and False.</div> : <><label>Answer options</label><div className="option-editor">{options.map((option, index) => <div className="option-edit-row" key={index}><span>{String.fromCharCode(65 + index)}</span><input required maxLength={500} placeholder={`Option ${index + 1}`} value={option} onChange={e => setOptions(options.map((o, i) => i === index ? e.target.value : o))} />{options.length > 2 && <button type="button" className="icon-button" aria-label="Remove option" onClick={() => { const next = options.filter((_, i) => i !== index); setOptions(next); if (Array.isArray(correct)) setCorrect(correct.filter(a => a !== option)); else if (correct === option) setCorrect('') }}><X size={15} /></button>}</div>)}{options.length < 12 && <button type="button" className="text-button add-option" onClick={() => setOptions([...options, ''])}><Plus size={14} /> Add option</button>}</div></>}
          <label>Correct answer{kind === 'multiple_select' ? 's' : ''}</label><div className="correct-options">{(kind === 'true_false' ? ['True', 'False'] : options.filter(Boolean)).map(option => <label key={option}><input type={kind === 'multiple_select' ? 'checkbox' : 'radio'} name="correct-answer" checked={Array.isArray(correct) ? correct.includes(option) : correct === option} onChange={e => { if (kind === 'multiple_select') setCorrect(e.target.checked ? [...(Array.isArray(correct) ? correct : []), option] : (Array.isArray(correct) ? correct : []).filter(a => a !== option)); else setCorrect(option) }} /><span>{option}</span></label>)}</div>
          <div className="question-numbers"><div><label>Points</label><input type="number" min="0" max="100000" step="0.5" value={points} onChange={e => setPoints(Number(e.target.value))} /></div><div><label>Question timer (seconds) <span>optional</span></label><input type="number" min="1" max="3600" placeholder="Use quiz default or none" value={time} onChange={e => setTime(e.target.value)} /></div></div><div className="question-form-actions">{editing && <button type="button" className="secondary" onClick={reset}>Cancel edit</button>}<button className="primary" disabled={busy}>{busy ? 'Saving…' : editing ? 'Save question' : 'Add question'} <span>→</span></button></div>
        </form>
        <section className="panel question-list"><div className="panel-head"><div><h2>Questions <span className="count-badge">{items.length}</span></h2><p>Manage the questions in this quiz.</p></div></div><div className="searchbox question-search"><Search size={15} /><input placeholder="Find a question…" value={search} onChange={e => setSearch(e.target.value)} /></div>{filtered.length === 0 ? <div className="empty-state"><div className="empty-icon"><FileQuestion /></div><b>No questions yet</b><p>Add a question or import a JSON file.</p></div> : <div className="question-cards">{filtered.map(q => <article className="question-row" key={q.id}><div className="question-row-top"><span className="question-num">{q.position}</span><span className="badge draft">{q.type.replace('_', ' ')}</span><span className="question-points">{q.points} pts</span><div className="question-row-actions"><button className="icon-button" title="Edit" onClick={() => beginEdit(q)}><Settings size={15} /></button><button className="icon-button delete-icon" title="Delete" onClick={() => remove(q)}><X size={15} /></button></div></div><b>{q.prompt}</b><div className="question-option-preview">{q.options.map((o, i) => <span key={i} className={(Array.isArray(q.correct_answer) ? q.correct_answer.includes(o) : q.correct_answer === o) ? 'is-correct' : ''}>{String.fromCharCode(65 + i)}. {o}</span>)}</div></article>)}</div>}</section>
      </div>
    </>}
  </>;
}

function CreateQuiz({ onClose, onCreated, show }: { onClose: () => void; onCreated: () => void; show: (s: string) => void }) {
  const [title, setTitle] = useState('');
  const [description, setDescription] = useState('');
  const [mode, setMode] = useState<'live_controlled' | 'self_paced'>('live_controlled');
  const [speedPoints, setSpeedPoints] = useState(false);
  const [partialMarking, setPartialMarking] = useState(false);
  const [allowNavigation, setAllowNavigation] = useState(true);
  const [allowAnswerChanges, setAllowAnswerChanges] = useState(false);
  const [allowReattempts, setAllowReattempts] = useState(false);
  const [negativePercent, setNegativePercent] = useState(0);
  const [totalMinutes, setTotalMinutes] = useState(15);
  const [saving, setSaving] = useState(false);

  const submit = async (e: FormEvent) => {
    e.preventDefault();
    if (!supabase) return;
    setSaving(true);
    const code = Math.random().toString(36).slice(2, 8).toUpperCase();
    const settings = {
      progression: 'manual', total_time_seconds: totalMinutes * 60,
      allow_navigation: allowNavigation, allow_answer_changes: allowAnswerChanges, allow_reattempts: allowReattempts, show_leaderboard: false,
      scoring: { speed_points_enabled: speedPoints, partial_marking: partialMarking, negative_marking_percent: negativePercent },
    };
    const { error } = await supabase.from('quizzes').insert({ title: title.trim(), description: description.trim(), mode, status: 'draft', join_code: code, settings });
    setSaving(false);
    if (error) { show(error.message); return; }
    onCreated();
  };

  return <div className="modal-backdrop" onMouseDown={e => e.target === e.currentTarget && onClose()}><form className="modal quiz-create-modal" onSubmit={submit}>
    <div className="modal-head"><div><span className="eyebrow">NEW QUIZ</span><h2>Create a quiz</h2></div><button type="button" className="icon-button" onClick={onClose}><X size={18} /></button></div>
    <p className="modal-copy">Set the quiz mode, timing and scoring rules. Add questions after creation.</p>
    <label>Quiz title <em>*</em></label><input autoFocus required maxLength={100} placeholder="e.g. General Knowledge Quiz" value={title} onChange={e => setTitle(e.target.value)} />
    <label>Description</label><textarea rows={2} maxLength={500} placeholder="What will participants learn?" value={description} onChange={e => setDescription(e.target.value)} />
    <label>Quiz mode</label><div className="mode-options"><button type="button" className={mode === 'live_controlled' ? 'mode-selected' : ''} onClick={() => setMode('live_controlled')}><Gamepad2 size={18} /><b>Live controlled</b><small>Host reveals each question</small></button><button type="button" className={mode === 'self_paced' ? 'mode-selected' : ''} onClick={() => setMode('self_paced')}><Clock3 size={18} /><b>Self-paced</b><small>Participants go at their pace</small></button></div>
    <div className="quiz-timing"><div><label>Time per participant (minutes)</label><input type="number" min="1" max="1440" value={totalMinutes} onChange={e => setTotalMinutes(Number(e.target.value))} /></div></div>
    <div className="scoring-setup"><div className="scoring-setup-head"><b>Scoring rules</b><small>Applied by the database when answers are submitted.</small></div><label className="setting-check"><input type="checkbox" checked={allowNavigation} onChange={e => setAllowNavigation(e.target.checked)} /><span><b>Allow previous question navigation</b><small>Participants may return to questions they have passed.</small></span></label><label className="setting-check"><input type="checkbox" checked={allowAnswerChanges} onChange={e => setAllowAnswerChanges(e.target.checked)} /><span><b>Allow answer changes</b><small>Participants can update answers before a question closes.</small></span></label><label className="setting-check"><input type="checkbox" checked={allowReattempts} onChange={e => setAllowReattempts(e.target.checked)} /><span><b>Allow participant reattempts</b><small>Otherwise, the same username and phone number can only join once per quiz run.</small></span></label><label className="setting-check"><input type="checkbox" checked={speedPoints} onChange={e => setSpeedPoints(e.target.checked)} /><span><b>Speed points</b><small>Multiplier based on time remaining when question timers are enabled.</small></span></label><label className="setting-check"><input type="checkbox" checked={partialMarking} onChange={e => setPartialMarking(e.target.checked)} /><span><b>Partial marks</b><small>Give credit on multiple select questions.</small></span></label><div className="negative-setting"><span><b>Incorrect answer penalty</b><small>Percent of the question marks deducted.</small></span><select value={negativePercent} onChange={e => setNegativePercent(Number(e.target.value))}><option value={0}>No penalty</option><option value={25}>25%</option><option value={50}>50%</option><option value={100}>100%</option></select></div></div>
    <div className="modal-foot"><button type="button" className="secondary" onClick={onClose}>Cancel</button><button className="primary" disabled={saving || !title.trim() || totalMinutes < 1}>{saving ? 'Creating…' : 'Create quiz'}<span>→</span></button></div>
  </form></div>;
}
function Live({ quizzes, show, onRefresh, selectedQuizId, embedded = false }: { quizzes: Quiz[]; show: (s: string) => void; onRefresh: () => void; selectedQuizId?: string; embedded?: boolean }) {
  const [id, setId] = useState('');
  const [questions, setQuestions] = useState<QuestionRow[]>([]);
  const [questionId, setQuestionId] = useState('');
  const [mergeLeaderboard, setMergeLeaderboard] = useState(false);
  const [runProgress, setRunProgress] = useState({ participants: 0, submitted: 0, reviewEnabled: false, loaded: false });
  const active = quizzes.find(q => q.id === (selectedQuizId || id)) || (!selectedQuizId ? quizzes.find(q => ['live', 'waiting_room', 'paused'].includes(q.status)) : undefined);
  const joinUrl = active ? `${import.meta.env.VITE_PUBLIC_APP_URL || location.origin}/join/${active.join_code || active.id}` : '';

  useEffect(() => {
    if (!supabase || !active) { setQuestions([]); setQuestionId(''); return; }
    supabase.from('questions').select('*').eq('quiz_id', active.id).order('position').then(({ data, error }) => {
      if (error) show(error.message);
      else {
        const loaded = (data || []) as QuestionRow[];
        setQuestions(loaded);
        setQuestionId(active.current_question_id || loaded[0]?.id || '');
      }
    });
  }, [active?.id, active?.current_question_id]);

  useEffect(() => {
    if (!active?.active_run_id || !supabase) { setRunProgress({ participants: 0, submitted: 0, reviewEnabled: false, loaded: false }); return }
    const client = supabase;
    let mounted = true;
    const loadProgress = async () => {
      const [participants, run] = await Promise.all([
        client.from('participants').select('status').eq('run_id', active.active_run_id!),
        client.from('quiz_runs').select('review_enabled').eq('id', active.active_run_id!).maybeSingle(),
      ]);
      if (!mounted) return;
      if (participants.error || run.error) { show(participants.error?.message || run.error?.message || 'Could not load quiz session status.'); return }
      const rows = (participants.data || []).filter(row => row.status !== 'logged_out');
      setRunProgress({ participants: rows.length, submitted: rows.filter(row => row.status === 'completed').length, reviewEnabled: Boolean(run.data?.review_enabled), loaded: true });
    };
    void loadProgress();
    const timer = window.setInterval(() => { void loadProgress(); }, 1500);
    return () => { mounted = false; window.clearInterval(timer) };
  }, [active?.active_run_id, show]);

  useEffect(() => {
    if (!active?.id || !selectedQuizId) return;
    const timer = window.setInterval(() => { void onRefresh(); }, 2000);
    return () => window.clearInterval(timer);
  }, [active?.id, selectedQuizId, onRefresh]);

  const control = async (action: string) => {
    if (!supabase || !active) return;
    if (action === 'reveal' && !questionId) { show('Add and select a question first.'); return; }
    const { error } = await supabase.rpc('admin_quiz_control', {
      p_quiz: active.id, p_action: action, p_question: action === 'reveal' ? questionId : null,
      p_merge_leaderboard: action === 'open_room' && mergeLeaderboard,
    });
    if (error) show(error.message);
    else { show(`Quiz ${action.replace('_', ' ')} updated.`); onRefresh(); }
  };

  return <>
    {!embedded && <div className="page-heading"><div><div className="eyebrow">HOST CONSOLE</div><h1>Live quiz control</h1><p>Open a waiting room, reveal questions and manage your competition.</p></div><span className="badge draft">● Host view</span></div>}
    <div className="live-layout">
      <section className="panel live-main">
        {!selectedQuizId && <><label>Select a quiz</label><select value={active?.id || id} onChange={e => setId(e.target.value)}><option value="">Choose a quiz…</option>{quizzes.map(q => <option key={q.id} value={q.id}>{q.title} · {q.status}</option>)}</select></>}
        {active ? <>
          <div className="live-quiz-title"><div><span className={`badge ${active.status}`}>{active.status.replace('_', ' ')}</span><h2>{active.title}</h2><p>{active.mode === 'self_paced' ? 'Self-paced' : 'Live controlled'} quiz · {questions.length} questions</p></div><div className="participant-count"><Users /><b>{active.participants}</b><small>participants</small></div></div>
          <div className="control-grid">
            {['draft', 'scheduled'].includes(active.status) && <button onClick={() => control('open_room')}>Open waiting room</button>}
            {active.status === 'completed' && <><label className="setting-check replay-choice"><input type="checkbox" checked={mergeLeaderboard} onChange={event => setMergeLeaderboard(event.target.checked)} /><span><b>Merge with previous leaderboard</b><small>Off by default: keep this audience in a separate board.</small></span></label><button onClick={() => control('open_room')}>Replay for a new audience</button></>}
            {['waiting_room', 'paused'].includes(active.status) && <button onClick={() => control('start')}>{active.status === 'paused' ? 'Resume quiz' : 'Start quiz'}</button>}
            {active.mode === 'live_controlled' && active.status === 'live' && <><button onClick={() => control('pause')}>Pause quiz</button><button onClick={() => control('close_question')}>Close question</button><button onClick={() => control('previous_question')}>Previous question</button><button onClick={() => control('next_question')}>Next question</button><button onClick={() => control('reveal_answer')}>Reveal answer</button></>}
            {active.status === 'live' && <>{!active.settings?.show_leaderboard ? <button onClick={() => control('show_leaderboard')}>Show live leaderboard</button> : <button onClick={() => control('hide_leaderboard')}>Hide leaderboard</button>}</>}
            {['waiting_room', 'live', 'paused'].includes(active.status) && <button className="danger-control" disabled={active.mode === 'self_paced' && active.status === 'live' && (!runProgress.loaded || runProgress.participants !== runProgress.submitted)} onClick={() => control('end')}>End quiz</button>}
          </div>
          {active.mode === 'live_controlled' && questions.length > 0 && active.status === 'live' && <div className="reveal-question"><label>QUESTION TO REVEAL</label><select value={questionId} onChange={e => setQuestionId(e.target.value)}>{questions.map(q => <option key={q.id} value={q.id}>Q{q.position}. {q.prompt}</option>)}</select><button className="primary" onClick={() => control('reveal')}>Reveal question <span>→</span></button></div>}
          {active.mode === 'self_paced' && ['live', 'paused', 'waiting_room'].includes(active.status) && <div className="current-question"><span className="eyebrow">SUBMISSION PROGRESS</span><b>{runProgress.submitted} of {runProgress.participants} participants submitted</b><p>Self-paced questions are controlled by each participant.</p></div>}
          {active.status === 'completed' && <div className="current-question"><span className="eyebrow">ANSWER REVIEW</span><b>{runProgress.reviewEnabled ? 'Review is available to participants' : 'Review is hidden from participants'}</b><p>Enable review only after the audience has finished submitting.</p>{runProgress.reviewEnabled ? <button className="secondary" onClick={() => control('disable_review')}>Disable answer review</button> : <button className="primary" disabled={!runProgress.loaded || runProgress.participants !== runProgress.submitted} onClick={() => control('enable_review')}>Enable answer review</button>}</div>}
          <div className="current-question"><span className="eyebrow">CURRENT QUESTION</span><b>{active.current_question_id ? questions.find(q => q.id === active.current_question_id)?.prompt || 'Question is loading…' : active.status === 'waiting_room' ? 'Waiting room is open' : active.status === 'live' ? 'Quiz is live' : 'No question revealed'}</b><p>{active.status === 'live' ? 'The host controls question visibility and progression.' : 'Use the controls above to manage the quiz.'}</p></div>
        </> : <div className="empty-state"><div className="empty-icon"><Gamepad2 /></div><b>No active quiz selected</b><p>Create a quiz before opening your live room.</p></div>}
      </section>
      <section className="panel join-card"><h2>Join your quiz</h2><p>Participants can scan this QR code to join.</p>{active ? <><div className="qr-wrap"><QRCodeSVG value={joinUrl} size={164} level="M" /></div><div className="join-code-label">JOIN CODE</div><div className="join-code">{active.join_code || '------'}<button className="icon-button" onClick={() => { navigator.clipboard.writeText(active.join_code || ''); show('Join code copied.'); }}><Copy size={15} /></button></div><small className="join-url">{joinUrl}</small><a className="secondary projector-link" href={joinUrl.replace('/join/', '/projector/')} target="_blank" rel="noreferrer"><ExternalLink size={14} /> Open projector view</a></> : <div className="qr-empty"><QrCode size={35} /><span>Select a quiz to generate its join code and QR.</span></div>}</section>
    </div>
  </>;
} function SettingsPage() { return <><div className="page-heading"><div><div className="eyebrow">PREFERENCES</div><h1>Settings</h1><p>Configure your workspace and application preferences.</p></div></div><div className="panel settings-panel"><div className="settings-tabs"><button className="selected">General</button><button>Quiz defaults</button><button>Notifications</button><button>Security</button></div><div className="settings-content"><h2>Workspace settings</h2><p>Current deployment and account configuration.</p><div className="setting-row"><div><b>Data connection</b><small>Quiz data and authentication provider</small></div><span className={`badge ${isConfigured ? 'completed' : 'draft'}`}>{isConfigured ? 'Connected' : 'Not configured'}</span></div><div className="setting-row"><div><b>Application URL</b><small>Used to create participant join links and QR codes</small></div><span className="setting-value">{import.meta.env.VITE_PUBLIC_APP_URL || location.origin}</span></div><div className="setting-row"><div><b>Timezone</b><small>Dates are shown in your browser’s local timezone</small></div><span className="setting-value">Automatic</span></div></div></div></> }

function ParticipantJoin() {
  const { code = '' } = useParams();
  const [name, setName] = useState('');
  const [mobile, setMobile] = useState('');
  const [token, setToken] = useState('');
  const activeToken = useRef('');
  const [recoveryToken, setRecoveryToken] = useState(() => localStorage.getItem(`lqp:${code}`) || '');
  const [state, setState] = useState<any>(null);
  const [answer, setAnswer] = useState<any>(null);
  const [lastSubmittedAnswer, setLastSubmittedAnswer] = useState<any>(null);
  const [submittedQuestion, setSubmittedQuestion] = useState('');
  const [message, setMessage] = useState('');
  const [busy, setBusy] = useState(false);
  const q = state?.question;
  const [clockNow, setClockNow] = useState(Date.now());
  const draftKey = `lqp:${code}:draft`;
  const secondsRemaining = q?.deadline ? Math.max(0, Math.ceil((new Date(q.deadline).getTime() - clockNow) / 1000)) : null;
  const overallRemaining = state?.overall_deadline ? Math.max(0, Math.ceil((new Date(state.overall_deadline).getTime() - clockNow) / 1000)) : null;

  const readState = async (sessionToken: string) => {
    if (!supabase) return;
    const { data, error } = await supabase.rpc('participant_state', { p_token: sessionToken });
    if (activeToken.current !== sessionToken) return;
    if (error) {
      setMessage(error.message);
      if (error.message.toLowerCase().includes('session expired')) {
        sessionStorage.removeItem(`lqp:${code}`);
        localStorage.removeItem(`lqp:${code}`);
        setRecoveryToken('');
        activeToken.current = '';
        setToken('');
      }
    }
    else if (data?.participant_completed) {
      const { data: overview, error: overviewError } = await supabase.rpc('participant_overview', { p_token: sessionToken });
      if (activeToken.current !== sessionToken) return;
      if (overviewError) { setMessage(overviewError.message); return; }
      setState({ ...data, participant_overview: overview });
    } else setState({ ...data, participant_overview: null });
  };
  useEffect(() => { if (token) readState(token); }, [token, code]);
  useEffect(() => { if (!token) return; const timer = window.setInterval(() => readState(token), 1000); return () => window.clearInterval(timer); }, [token, code]);
  useEffect(() => { if (token && !recoveryToken) { localStorage.setItem(`lqp:${code}`, token); setRecoveryToken(token); } }, [token, recoveryToken, code]);
  useEffect(() => { const timer = window.setInterval(() => setClockNow(Date.now()), 1000); return () => window.clearInterval(timer); }, []);
  useEffect(() => { const saved = state?.saved_answer; let draft: any = null; try { const raw = localStorage.getItem(draftKey); if (raw) { const parsed = JSON.parse(raw); if (parsed.questionId === q?.id) draft = parsed.answer; } } catch { localStorage.removeItem(draftKey); } setAnswer(saved ?? draft ?? (q?.type === 'multiple_select' ? [] : null)); setSubmittedQuestion(state?.answer_submitted ? q?.id || '' : ''); setLastSubmittedAnswer(saved ?? null); }, [q?.id, state?.saved_answer, state?.answer_submitted, draftKey]);
  useEffect(() => { if (!q?.id || !token || answer === null || (Array.isArray(answer) && answer.length === 0)) return; localStorage.setItem(draftKey, JSON.stringify({ questionId: q.id, answer })); }, [q?.id, answer, token, draftKey]);

  const join = async (e: FormEvent) => {
    e.preventDefault();
    if (!supabase) { setMessage('This quiz is not connected to its database yet.'); return; }
    setBusy(true);
    const { data, error } = await supabase.rpc('join_quiz', { p_code: code, p_name: name, p_mobile: mobile || null });
    setBusy(false);
    if (error) { setMessage(error.message.includes('already attempted') ? 'You have already attempted this quiz with this username and phone number.' : error.message); return; }
    activeToken.current = data.token;
    setState(null);
    setAnswer(null);
    setLastSubmittedAnswer(null);
    setSubmittedQuestion('');
    localStorage.removeItem(draftKey);
    sessionStorage.setItem(`lqp:${code}`, data.token);
    localStorage.setItem(`lqp:${code}`, data.token);
    setRecoveryToken(data.token);
    setToken(data.token);
    setMessage('');
    await readState(data.token);
  };
  const sendAnswer = async () => {
    if (!supabase || !token || !q || answer === null || (Array.isArray(answer) && answer.length === 0) || (submittedQuestion === q.id && !state?.allow_answer_changes)) return false;
    setBusy(true);
    const { error } = await supabase.rpc('submit_answer', { p_token: token, p_question: q.id, p_answer: answer });
    setBusy(false);
    if (error) { setMessage(error.message); return false; }
    localStorage.removeItem(draftKey); setSubmittedQuestion(q.id); setLastSubmittedAnswer(answer); setMessage(''); return true;
  };
  const finishQuiz = async () => {
    if (!supabase || !token) return;
    setBusy(true);
    const { error } = await supabase.rpc('participant_finish', { p_token: token });
    setBusy(false);
    if (error) { setMessage(error.message); return }
    setMessage('Your quiz has been submitted.');
    await readState(token);
  };
  const navigateQuestion = async (direction: 'next' | 'previous') => {
    if (!supabase || !token) return;
    const unsaved = (Array.isArray(answer) ? answer.length > 0 : answer !== null) && JSON.stringify(answer) !== JSON.stringify(lastSubmittedAnswer);
    if (unsaved) { const saved = await sendAnswer(); if (!saved) return; }
    setBusy(true);
    const { data, error } = await supabase.rpc('participant_navigate', { p_token: token, p_direction: direction });
    setBusy(false);
    if (error) setMessage(error.message);
    else { localStorage.removeItem(draftKey); setMessage(data.completed ? 'Quiz submitted.' : ''); await readState(token); }
  };
  const logout = async () => {
    if (token) { localStorage.setItem(`lqp:${code}`, token); setRecoveryToken(token); }
    activeToken.current = '';
    if (supabase && token) await supabase.rpc('participant_logout', { p_token: token });
    sessionStorage.removeItem(`lqp:${code}`); setToken(''); setState(null); setMessage('You are logged out. Your progress is saved on this device.');
  };
  const resumeSession = () => {
    if (!recoveryToken) return;
    activeToken.current = recoveryToken;
    sessionStorage.setItem(`lqp:${code}`, recoveryToken);
    setToken(recoveryToken);
    setMessage('Resuming your saved quiz session…');
  };
  const forgetSession = async () => {
    activeToken.current = '';
    if (supabase && recoveryToken) await supabase.rpc('participant_revoke', { p_token: recoveryToken });
    sessionStorage.removeItem(`lqp:${code}`);
    localStorage.removeItem(`lqp:${code}`);
    setRecoveryToken('');
    setToken('');
    setState(null);
    setMessage('Saved session forgotten. You can join again if the quiz is still open.');
  };
  const toggleAnswer = (value: string) => {
    if (q?.type !== 'multiple_select') { setAnswer(value); return; }
    const selected: string[] = Array.isArray(answer) ? answer : [];
    setAnswer(selected.includes(value) ? selected.filter(item => item !== value) : [...selected, value]);
  };
  const leaderboard = Array.isArray(state?.leaderboard) ? state.leaderboard : [];
  const overview = state?.participant_overview;
  const formatDuration = (seconds: number) => {
    const hours = Math.floor(seconds / 3600);
    const minutes = Math.floor(seconds % 3600 / 60);
    const remainingSeconds = seconds % 60;
    return hours
      ? `${hours}:${String(minutes).padStart(2, '0')}:${String(remainingSeconds).padStart(2, '0')}`
      : `${minutes}:${String(remainingSeconds).padStart(2, '0')}`;
  };

  return <div className="participant-page">
    <div className="participant-top"><div className="brand-mark"><Sparkles size={20} /></div><b>LiveQuiz <span>Pro</span></b><span className="participant-code">QUIZ {code.toUpperCase()}</span></div>
    <div className="participant-card">
      {!token ? <><div className="eyebrow">YOU’RE INVITED</div><h1>{recoveryToken ? "Welcome back" : "Join the quiz"}</h1><p>{recoveryToken ? "A saved attempt is available on this device. Resume it, or enter your details below to join again." : "Enter your name to join the host’s waiting room."}</p>{recoveryToken && <div className="resume-session"><button type="button" className="primary full" onClick={resumeSession}>Resume saved session <span>→</span></button><button type="button" className="forget-session" onClick={forgetSession}>Forget saved session on this device</button></div>}<form onSubmit={join}><label>{recoveryToken ? "Join with a different attempt" : "Your name"}</label><input required maxLength={80} value={name} onChange={e => setName(e.target.value)} placeholder="How should we call you?" /><label>Mobile number <span>optional</span></label><input type="tel" value={mobile} onChange={e => setMobile(e.target.value)} placeholder="Enter your phone number" /><button className="primary full" disabled={busy}>{busy ? 'Joining…' : 'Join quiz'} <span>→</span></button></form></> : <>
        <div className="participant-status"><i />CONNECTED</div><h1>{state?.quiz_title || 'Quiz waiting room'}</h1>
        {state?.quiz_status === 'waiting_room' ? <div className="waiting"><div className="waiting-pulse"><Users size={25} /></div><b>You’re in the waiting room, {state?.participant_name}.</b><p>The host will start the quiz shortly. Keep this screen open.</p></div> : null}
        {state?.participant_completed && <section className="participant-overview"><div className="participant-overview-heading"><div className="waiting-pulse"><Trophy size={22} /></div><div><b>Quiz submitted</b><p>Your results update as other participants submit.</p></div></div>{overview ? <div className="participant-overview-grid"><div><span>Total points</span><strong>{Number(overview.total_points).toLocaleString()}</strong></div><div><span>Marks earned</span><strong>{Number(overview.total_marks).toLocaleString()}</strong></div><div><span>Correct</span><strong>{overview.correct_count}</strong></div><div><span>Wrong</span><strong>{overview.wrong_count}</strong></div><div><span>Attempted</span><strong>{overview.attempted_count} / {overview.total_questions}</strong></div><div><span>Time taken</span><strong>{formatDuration(Number(overview.time_taken_seconds))}</strong></div><div className="overview-rank"><span>Current rank</span><strong>{overview.rank ? `#${overview.rank}` : 'Updating…'}</strong></div></div> : <p className="overview-loading">Loading your score overview…</p>}</section>}
        {state?.quiz_status === 'live' && q && !state?.participant_completed ? <section className="participant-active-question" key={q.id}><div className="participant-question-meta"><div className="question-progress">QUESTION {q.position} OF {state.question_count}{overallRemaining !== null && <small>Your time {Math.floor(overallRemaining / 60).toString().padStart(2, '0')}:{(overallRemaining % 60).toString().padStart(2, '0')}</small>}</div>{secondsRemaining !== null && <div className={`question-timer ${secondsRemaining < 10 ? 'urgent' : ''}`}><Clock3 size={14} />{Math.floor(secondsRemaining / 60).toString().padStart(2, '0')}:{(secondsRemaining % 60).toString().padStart(2, '0')}</div>}</div><h2 className="participant-question">{q.prompt}</h2><div className="participant-options">{(q.options || []).map((option: string, index: number) => { const selected = Array.isArray(answer) ? answer.includes(option) : answer === option; return <button key={index} className={selected ? 'chosen' : ''} onClick={() => toggleAnswer(option)} disabled={(submittedQuestion === q.id && !state?.allow_answer_changes) || secondsRemaining === 0 || overallRemaining === 0 || q.answer_revealed}><span>{String.fromCharCode(65 + index)}</span>{option}</button>; })}</div>{(Array.isArray(answer) ? answer.length > 0 : answer !== null) && <button className="clear-answer" onClick={() => setAnswer(q.type === 'multiple_select' ? [] : null)}>Clear answer</button>}{state?.mode !== 'self_paced' && <button className="primary full" onClick={sendAnswer} disabled={busy || (submittedQuestion === q.id && !state?.allow_answer_changes) || secondsRemaining === 0 || overallRemaining === 0 || q.answer_revealed || answer === null || (Array.isArray(answer) && answer.length === 0)}>{q.answer_revealed ? 'Question closed' : overallRemaining === 0 || secondsRemaining === 0 ? 'Time is up' : submittedQuestion === q.id && state?.allow_answer_changes ? 'Update answer' : submittedQuestion === q.id ? 'Answer submitted' : busy ? 'Submitting…' : 'Submit answer'}</button>}{state?.mode === 'self_paced' && <div className="participant-navigation">{state.allow_navigation && <button className="secondary" onClick={() => navigateQuestion('previous')} disabled={busy || q.position <= 1 || overallRemaining === 0}>← Previous</button>}<button className="secondary" onClick={() => navigateQuestion('next')} disabled={busy || overallRemaining === 0}>{q.position >= state.question_count ? 'Submit quiz' : 'Next question'}</button></div>}{q.answer_revealed && <div className="answer-reveal"><b>Correct answer</b><span>{Array.isArray(q.correct_answer) ? q.correct_answer.join(', ') : q.correct_answer}</span>{state?.saved_points !== null && state?.saved_points !== undefined && <small>Marks awarded: {Number(state.saved_points).toLocaleString()}</small>}</div>}</section> : null}
        {state?.quiz_status === 'live' && !q && !state?.participant_completed ? <div className="waiting"><div className="waiting-pulse"><Clock3 size={25} /></div><b>{state?.mode === 'self_paced' ? 'Starting your quiz…' : 'The host is getting the next question ready.'}</b><p>Your screen will update when a question is ready.</p></div> : null}
        {state?.quiz_status === 'paused' ? <div className="waiting"><div className="waiting-pulse"><Clock3 size={25} /></div><b>The quiz is paused.</b><p>Wait here for the host’s next update.</p></div> : null}
        {state?.quiz_status === 'completed' && !state?.participant_completed ? <div className="waiting"><div className="waiting-pulse"><Trophy size={25} /></div><b>Quiz completed</b><p>Submit your quiz to see your score. Answers stay hidden until the controller enables review.</p><button className="primary" disabled={busy} onClick={finishQuiz}>{busy ? 'Submitting…' : 'Submit quiz'} <span>→</span></button></div> : null}
        {state?.show_leaderboard && leaderboard.length > 0 && <section className="participant-leaderboard"><h2><Trophy size={16} /> Leaderboard</h2>{leaderboard.map((row: any) => <div key={`${row.id || row.name}-${row.rank}-${row.score}`} className="participant-rank leaderboard-update"><span>{row.rank}</span><b>{row.name}</b><strong>{Number(row.score).toLocaleString()} pts</strong></div>)}</section>}
        {state?.quiz_status === 'completed' && <section className="participant-review"><h2>Review your quiz</h2>{state?.review_enabled ? (state.review_questions || []).map((item: any) => <article key={item.id} className={`review-question ${item.is_correct ? 'review-correct' : 'review-incorrect'}`}><div className="review-question-meta"><span>QUESTION {item.position}</span><b>{item.is_correct ? 'Correct' : item.answer === null ? 'Not answered' : 'Incorrect'}</b></div><h3>{item.prompt}</h3><div className="review-answer"><span>Your answer</span><b>{Array.isArray(item.answer) ? item.answer.join(', ') : item.answer || 'No answer submitted'}</b></div><div className="review-answer"><span>Correct answer</span><b>{Array.isArray(item.correct_answer) ? item.correct_answer.join(', ') : item.correct_answer}</b></div>{item.explanation && <p>{item.explanation}</p>}</article>) : <p className="review-locked"><ShieldCheck size={16} /> Answer review will appear here after the controller enables it.</p>}</section>}
        <button className="participant-logout" onClick={logout}>Leave quiz</button>
      </>}
      {message && <div className={message.includes('joined') || message.includes('received') ? 'participant-message' : 'error'}>{message}</div>}
    </div>
    <p className="participant-privacy"><ShieldCheck size={13} /> Your name appears to the quiz host. Your mobile number stays private.</p>
  </div>;
}

function Projector() {
  const { code = '' } = useParams();
  const [state, setState] = useState<any>(null);
  const [error, setError] = useState('');
  const [fullscreenError, setFullscreenError] = useState('');
  const [isFullscreen, setIsFullscreen] = useState(false);
  const [projectorTab, setProjectorTab] = useState<'qr' | 'leaderboard'>('qr');
  const joinUrl = `${import.meta.env.VITE_PUBLIC_APP_URL || location.origin}/join/${code}`;
  const refresh = async () => {
    if (!supabase) { setError('This projector is not connected to Supabase.'); return; }
    const { data, error: queryError } = await supabase.rpc('projector_state', { p_code: code });
    if (queryError) setError(queryError.message); else { setError(''); setState(data); }
  };
  useEffect(() => { refresh(); const timer = window.setInterval(refresh, 1000); return () => window.clearInterval(timer); }, [code]);
  useEffect(() => {
    const updateFullscreen = () => setIsFullscreen(Boolean(document.fullscreenElement));
    document.addEventListener('fullscreenchange', updateFullscreen);
    return () => document.removeEventListener('fullscreenchange', updateFullscreen);
  }, []);
  const toggleFullscreen = async () => {
    try {
      if (document.fullscreenElement) await document.exitFullscreen();
      else await document.documentElement.requestFullscreen();
      setFullscreenError('');
    } catch (cause) {
      setFullscreenError(cause instanceof Error ? cause.message : 'Unable to change fullscreen mode.');
    }
  };
  const leaders = Array.isArray(state?.leaderboard) ? state.leaderboard : [];
  return <main className={`projector-page ${projectorTab === 'qr' ? 'projector-qr-view' : 'projector-leaderboard-view'}`}>
    <header className="projector-header"><div className="brand-mark"><Sparkles size={22} /></div><b>LiveQuiz <span>Pro</span></b><button className="projector-fullscreen" onClick={toggleFullscreen} title={isFullscreen ? 'Exit fullscreen' : 'Enter fullscreen'} aria-label={isFullscreen ? 'Exit fullscreen' : 'Enter fullscreen'}>{isFullscreen ? <Minimize2 size={17} /> : <Maximize2 size={17} />}<span>{isFullscreen ? 'Exit fullscreen' : 'Fullscreen'}</span></button><span className={`projector-status ${state?.status || 'loading'}`}><i />{(state?.status || 'connecting').replace('_', ' ')}</span></header>
    {fullscreenError && <div className="projector-fullscreen-error" role="status">{fullscreenError}</div>}
    {error ? <div className="projector-error">{error}</div> : !state ? <div className="projector-wait">Connecting to the quiz...</div> : <>
      <div className="projector-title"><h1>{state.title}</h1><div>{state.participant_count} participants joined</div></div>
      {projectorTab === 'leaderboard' && state.status === 'completed' && <h2 className="projector-finished">Quiz complete</h2>}
      <div className="projector-tabs" role="tablist" aria-label="Projector views"><button role="tab" aria-selected={projectorTab === 'qr'} className={projectorTab === 'qr' ? 'selected' : ''} onClick={() => setProjectorTab('qr')}><QrCode size={17} /> Join QR</button><button role="tab" aria-selected={projectorTab === 'leaderboard'} className={projectorTab === 'leaderboard' ? 'selected' : ''} onClick={() => setProjectorTab('leaderboard')}><Trophy size={17} /> Leaderboard</button></div>
      {projectorTab === 'qr' && <div className="projector-invite"><div><span className="eyebrow">JOIN THE QUIZ</span><h2>{state.status === 'completed' ? 'Quiz complete' : 'Scan to play'}</h2><p>Scan the QR code or enter this code on the join page.</p><div className="projector-code">{code.toUpperCase()}</div></div><div className="projector-qr"><QRCodeSVG value={joinUrl} size={220} level="H" /></div></div>}
      {projectorTab === 'leaderboard' && (leaders.length > 0 ? <section className="projector-leaderboard"><h2><Trophy size={25} /> Live leaderboard</h2><div className="projector-top-three">{leaders.slice(0, 3).map((row: any, index: number) => <article className={`projector-podium podium-${index + 1}`} key={`${row.id || row.name}-${row.rank}-${row.score}`}><span>{row.rank}</span><b>{row.name}</b><strong>{Number(row.score).toLocaleString()} pts</strong></article>)}</div>{leaders.length > 3 && <div className="projector-rest">{leaders.slice(3).map((row: any) => <div key={`${row.id || row.name}-${row.rank}-${row.score}`}><span>{row.rank}</span><b>{row.name}</b><strong>{Number(row.score).toLocaleString()} pts</strong></div>)}</div>}</section> : <div className="projector-tab-empty">Waiting for participants to join. Scores will appear here as they submit answers.</div>)}
      <footer className="projector-footer"><span>LiveQuiz Pro � Live competition</span><span>Join code {code.toUpperCase()}</span></footer>
    </>}
  </main>;
}
