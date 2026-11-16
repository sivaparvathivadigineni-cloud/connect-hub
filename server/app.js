import dotenv from 'dotenv';
import { fileURLToPath } from 'node:url';
import { dirname, resolve } from 'node:path';
import express from 'express';
import cors from 'cors';
import helmet from 'helmet';
import { createClient } from '@supabase/supabase-js';

dotenv.config({ path: resolve(dirname(fileURLToPath(import.meta.url)), '../.env') });

const app = express();
const supabaseUrl = process.env.SUPABASE_URL || process.env.VITE_SUPABASE_URL;
const publishableKey = process.env.SUPABASE_PUBLISHABLE_KEY || process.env.VITE_SUPABASE_PUBLISHABLE_KEY;
const supabase = supabaseUrl && publishableKey
  ? createClient(supabaseUrl, publishableKey, { auth: { persistSession: false, autoRefreshToken: false } })
  : null;

app.use(helmet());
const clientOrigin = (process.env.CLIENT_ORIGIN || (process.env.NODE_ENV === 'production' ? '' : 'http://localhost:5173'))
  .trim()
  .replace(/\/+$/, '');
if (!clientOrigin) {
  throw new Error('CLIENT_ORIGIN must be set to the deployed frontend origin in production.');
}
app.use(cors({ origin: clientOrigin }));
app.use(express.json({ limit: '20kb' }));

const requireSupabase = (_req, res, next) => supabase
  ? next()
  : res.status(503).json({ error: 'Supabase is not configured. Set the project URL and publishable key.' });

const handle = fn => (req, res, next) => Promise.resolve(fn(req, res, next)).catch(next);

const auth = async (req, res, next) => {
  const token = req.headers.authorization?.match(/^Bearer\s+(.+)$/i)?.[1];
  if (!token) return res.status(401).json({ error: 'Sign in to continue.' });
  try {
    const { data, error } = await supabase.auth.getUser(token);
    if (error || !data.user) return res.status(401).json({ error: 'Your session is invalid or expired. Please sign in again.' });
    req.user = data.user;
    req.userDb = createClient(supabaseUrl, publishableKey, {
      auth: { persistSession: false, autoRefreshToken: false },
      global: { headers: { Authorization: `Bearer ${token}` } },
    });
    return next();
  } catch {
    return res.status(401).json({ error: 'Your session could not be verified. Please sign in again.' });
  }
};

const getJoinedSessions = async (client, userId) => {
  const { data: memberships, error: membershipError } = await client
    .from('session_participants').select('session_id').eq('student_id', userId);
  if (membershipError) throw membershipError;
  const ids = memberships.map(row => row.session_id);
  if (!ids.length) return [];
  const { data, error } = await client.from('session_details').select('*').in('id', ids).order('starts_at');
  if (error) throw error;
  return data.filter(session => session.host_id !== userId);
};

app.get('/api/health', (_req, res) => res.json({ ok: true, service: 'Connect Hub API', database: supabase ? 'configured' : 'not configured' }));

app.get('/api/games', requireSupabase, handle(async (_req, res) => {
  const { data, error } = await supabase.from('games').select('*').order('category').order('name');
  if (error) throw error;
  res.json({ games: data });
}));

app.get('/api/profile', requireSupabase, auth, handle(async (req, res) => {
  const { data, error } = await req.userDb.from('profiles').select('*').eq('id', req.user.id).single();
  if (error) throw error;
  res.json({ profile: data });
}));

app.put('/api/profile', requireSupabase, auth, handle(async (req, res) => {
  const full_name = String(req.body.full_name || '').trim();
  const department = String(req.body.department || '').trim();
  const year = Number(req.body.year);
  if (full_name.length < 2 || full_name.length > 80 || department.length < 2 || department.length > 80 || !Number.isInteger(year) || year < 1 || year > 6) {
    return res.status(400).json({ error: 'Check your name, department, and year of study.' });
  }
  const { data, error } = await req.userDb.from('profiles').update({ full_name, department, year }).eq('id', req.user.id).select().single();
  if (error) throw error;
  res.json({ profile: data });
}));

app.get('/api/sessions', requireSupabase, handle(async (req, res) => {
  let query = supabase.from('session_details').select('*').eq('status', 'OPEN')
    .gte('starts_at', new Date().toISOString()).order('starts_at')
    .limit(Math.min(Number(req.query.limit) || 50, 100));
  if (req.query.game) query = query.eq('game_name', String(req.query.game));
  if (req.query.category) query = query.eq('category', String(req.query.category).toUpperCase());
  const { data, error } = await query;
  if (error) throw error;
  res.json({ sessions: data });
}));

app.post('/api/sessions', requireSupabase, auth, handle(async (req, res) => {
  const { game_name, location, starts_at, max_players, notes = '' } = req.body;
  const date = new Date(starts_at);
  const capacity = Number(max_players);
  if (typeof game_name !== 'string' || !game_name.trim() || typeof location !== 'string' || !location.trim() ||
      !Number.isFinite(date.getTime()) || date <= new Date() || !Number.isInteger(capacity) || capacity < 2 || capacity > 30 ||
      typeof notes !== 'string' || notes.length > 240) {
    return res.status(400).json({ error: 'Check the game, location, future date, capacity (2–30), and note.' });
  }
  const { data, error } = await req.userDb.rpc('create_game_session', {
    p_game_name: game_name.trim(), p_location: location.trim(), p_starts_at: date.toISOString(),
    p_max_players: capacity, p_notes: notes.trim(),
  });
  if (error) throw error;
  res.status(201).json({ session: data });
}));

app.post('/api/sessions/:id/join', requireSupabase, auth, handle(async (req, res) => {
  const { data, error } = await req.userDb.rpc('join_game_session', { p_session_id: req.params.id });
  if (error) {
    if (error.message.includes('full')) return res.status(409).json({ error: 'This session is full.' });
    if (error.message.includes('already')) return res.status(409).json({ error: 'You have already joined this session.' });
    if (error.message.includes('past')) return res.status(409).json({ error: 'This session has already started.' });
    if (error.message.includes('unavailable')) return res.status(409).json({ error: 'This session is unavailable.' });
    throw error;
  }
  res.json({ participant: data });
}));

app.get('/api/sessions/:id/participants', requireSupabase, auth, handle(async (req, res) => {
  const { data, error } = await req.userDb.rpc('get_host_session_participants', {
    p_session_id: req.params.id,
  });
  if (error) {
    if (error.code === '42501') {
      return res.status(403).json({ error: 'Only the session host can view its participants.' });
    }
    if (error.code === '22P02') return res.status(400).json({ error: 'Invalid session ID.' });
    throw error;
  }
  res.json(data);
}));

app.get('/api/sessions/created', requireSupabase, auth, handle(async (req, res) => {
  const { data, error } = await req.userDb.from('session_details').select('*')
    .eq('host_id', req.user.id).order('starts_at', { ascending: false });
  if (error) throw error;
  res.json({ sessions: data });
}));

app.get('/api/sessions/joined', requireSupabase, auth, handle(async (req, res) => {
  res.json({ sessions: await getJoinedSessions(req.userDb, req.user.id) });
}));

app.get('/api/dashboard', requireSupabase, auth, handle(async (req, res) => {
  const [{ data: created, error }, joined] = await Promise.all([
    req.userDb.from('session_details').select('*').eq('host_id', req.user.id).order('starts_at', { ascending: false }),
    getJoinedSessions(req.userDb, req.user.id),
  ]);
  if (error) throw error;
  res.json({ created, joined });
}));

app.use((err, _req, res, _next) => {
  console.error(err);
  res.status(500).json({ error: process.env.NODE_ENV === 'production' ? 'The request could not be completed.' : 'The request could not be completed. Check the server logs.' });
});

const port = Number(process.env.PORT) || 4000;
app.listen(port, () => console.log(`Connect Hub API listening on ${port}`));
