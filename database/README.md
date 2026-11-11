# Database setup

1. For a new database, run migrations/001_initial_schema.sql, migrations/002_student_profile_details.sql, then migrations/003_email_auth_rls.sql in SQL Editor.
2. For the existing CONNECT HUB database, run only migrations/003_email_auth_rls.sql; it preserves the existing tables and data.
3. Enable email sign-up in Supabase Auth. For development testing, email confirmation may be disabled.
4. Configure the root .env from .env.example with the project URL and publishable key. No service-role key is used.

The migrations create profiles linked one-to-one to Auth users, games, sessions, and the many-to-many participant relationship. Profiles include department and year of study. RLS policies protect student records and host-owned sessions. Authenticated database functions create and join sessions atomically, enforcing host inclusion, duplicate prevention, and capacity.
