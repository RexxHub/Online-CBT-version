"""Rexx Hub: export exam results for the online Teachers Dashboard.

Put this file in the SCH CBT APP folder (next to app.py) and run:
    python export_online.py            -> all exams that are published or have submissions
    python export_online.py --exam 5   -> one exam only
Writes rexxhub-results-<date>.json. Read-only: it never changes the database.
Passwords, keys and certificates are NOT exported.
"""
import argparse, json, os, sqlite3, time

HERE = os.path.dirname(os.path.abspath(__file__))
DB = os.path.join(HERE, "data", "rexxhub.db")


def norm(s):
    return " ".join((s or "").lower().split())


def is_correct(qtype, answer, response):  # same rule as the exam app
    if response is None or response == "":
        return False
    if qtype in ("mcq", "tf"):
        return response.strip().upper() == answer.strip().upper()
    return norm(response) in [norm(a) for a in answer.split("|")]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--exam", type=int, help="export only this exam id")
    args = ap.parse_args()
    db = sqlite3.connect("file:%s?mode=ro" % DB.replace("\\", "/"), uri=True)
    db.row_factory = sqlite3.Row
    first = db.execute("SELECT MIN(created_at) m FROM users WHERE role='admin'").fetchone()["m"]
    out = {"version": 1, "install_id": str(first), "exported_at": int(time.time()), "exams": []}
    sql = "SELECT e.*, u.username AS tname FROM exams e JOIN users u ON u.id=e.teacher_id"
    if args.exam:
        exams = db.execute(sql + " WHERE e.id=?", (args.exam,)).fetchall()
    else:
        exams = db.execute(sql + " WHERE e.published=1 OR e.id IN (SELECT exam_id FROM attempts) ORDER BY e.id").fetchall()
    for e in exams:
        qs = db.execute("SELECT * FROM questions WHERE exam_id=? ORDER BY position, id", (e["id"],)).fetchall()
        qmap = {q["id"]: q for q in qs}
        atts = db.execute("SELECT a.*, s.username, s.full_name, s.class_name FROM attempts a "
                          "JOIN users s ON s.id=a.student_id WHERE a.exam_id=? AND a.status='submitted'", (e["id"],)).fetchall()
        answers = []
        for a in atts:
            for r in db.execute("SELECT * FROM answers WHERE attempt_id=?", (a["id"],)):
                q = qmap.get(r["question_id"])
                if q:
                    answers.append({"attempt_id": a["id"], "question_id": q["id"], "response": r["response"],
                                    "correct": is_correct(q["qtype"], q["answer"], r["response"])})
        out["exams"].append({
            "exam": {"id": e["id"], "teacher_username": e["tname"], "title": e["title"], "subject": e["subject"],
                     "duration_min": e["duration_min"], "target_class": e["target_class"], "pass_mark": e["pass_mark"],
                     "opens_at": e["opens_at"], "closes_at": e["closes_at"]},
            "questions": [{"id": q["id"], "pos": q["position"], "qtype": q["qtype"], "qtext": q["text"],
                           "options": json.loads(q["options_json"] or "[]"), "answer": q["answer"], "marks": q["marks"]} for q in qs],
            "attempts": [{"id": a["id"], "student_username": a["username"], "student_name": a["full_name"],
                          "class_name": a["class_name"], "started_at": a["started_at"], "submitted_at": a["submitted_at"],
                          "score": a["score"], "total": a["total"], "tab_switches": a["tab_switches"]} for a in atts],
            "answers": answers})
    name = os.path.join(HERE, "rexxhub-results-%s.json" % time.strftime("%Y%m%d-%H%M"))
    with open(name, "w", encoding="utf-8") as f:
        json.dump(out, f)
    n = sum(len(x["attempts"]) for x in out["exams"])
    print("Exported %d exam(s), %d submission(s) -> %s" % (len(out["exams"]), n, name))


if __name__ == "__main__":
    main()
