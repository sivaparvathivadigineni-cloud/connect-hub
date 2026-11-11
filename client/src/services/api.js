import { supabase } from './supabase.js';

const base = import.meta.env.VITE_API_URL || 'http://localhost:4000/api';
export async function api(path, options = {}) {
  const { data } = supabase ? await supabase.auth.getSession() : { data: { session: null } };
  const response = await fetch(`${base}${path}`, {
    ...options,
    headers: { 'Content-Type': 'application/json', ...(data.session?.access_token ? { Authorization: `Bearer ${data.session.access_token}` } : {}), ...options.headers },
  });
  const body = await response.json().catch(() => ({}));
  if (!response.ok) throw new Error(body.error || 'Something went wrong. Please try again.');
  return body;
}
