REXVA CBT - Online edition (dark theme + parent portal)

LOOK: style.css, clock.js, fonts/ and brand/ are copied unchanged from the offline app (V1.3.0).
      online.css only adds what the online pages need (tabs, print sheets).

SETUP (existing Supabase project)
 1. Supabase > SQL Editor > run upgrade_parent_portal.sql once. (schema.sql = original + this upgrade, for new projects.)
    Running it again is safe.
 1b. SYNC BUTTON: at the very end of upgrade_parent_portal.sql is one commented line. Put a long secret (20+ random
    characters) in it, remove the leading "--", run it, then enter the SAME secret in the offline app:
    Admin > Sync online > Sync key. Project URL = your Supabase URL; Anon key = the publishable key in index.html.
    After that, "Sync now" makes results visible to teachers and approved parents straight away.
    If the exam app is ever reinstalled, sync stops with a message; run: delete from settings where key='install_id';
 2. Supabase > Authentication > URL Configuration: set Site URL to your hosted page and add it under
    Redirect URLs (needed for e-mail confirmation and "Forgot password").
 3. Authentication > Providers > Email: keep "Confirm email" ON; set minimum password length to 10.
    Strongly recommended: Authentication > Attack Protection > enable CAPTCHA (Turnstile/hCaptcha).
 4. Upload the whole folder to your host (index.html, style.css, online.css, clock.js, fonts/, brand/).
    If your host allows response headers, also send: X-Frame-Options: DENY, Referrer-Policy: no-referrer,
    Strict-Transport-Security. (The page already carries a Content-Security-Policy.)

HOW PARENTS GET ACCESS
 Parent signs up with the child's Student ID + name -> request is PENDING -> admin opens "Parents",
 compares the name with the school record, presses Approve. Remove ends access at once.
 Matching ignores case, spaces and the hyphen (ADAOKA-7K3QD = adaoka7k3qd).
 If you re-issue a student's ID offline, the parent must be re-linked (the link is to the old ID).

WHAT A PARENT CAN SEE AND DOWNLOAD (approved children only, read-only)
 Scores, pass/fail, class average and position; the report card (print); and for each exam the child sat,
 the questions with the child's answer and the correct answer (Download CSV, or Print / save as PDF).
 No other student's name or answers. The database gives parents no write access.
