SET search_path=admission,pg_catalog,public;
INSERT INTO admission_cycle(year,choice_deadline) VALUES(2026,clock_timestamp()+interval '90 days');
INSERT INTO program(program_id,institute,code,name) VALUES
 (1,'North Campus','CSE','Computer Science & Engineering'),
 (2,'North Campus','ECE','Electronics & Communication'),
 (3,'North Campus','ME','Mechanical Engineering'),
 (4,'South Campus','CSE','Computer Science & Engineering'),
 (5,'South Campus','CE','Civil Engineering');
INSERT INTO program_eligibility SELECT 2026,program_id,80 FROM program;
INSERT INTO seat_matrix SELECT 2026,p.program_id,c,CASE WHEN c='OPEN' THEN 2 WHEN c='OBC_NCL' THEN 1 ELSE 0 END FROM program p CROSS JOIN unnest(enum_range(NULL::seat_cat)) c;
INSERT INTO counselling_round(year,round_no,response_deadline) VALUES(2026,1,clock_timestamp()+interval '7 days');
INSERT INTO student(student_id,full_name) VALUES
 (1,'Diya Sharma'),(2,'Kunal Mehta'),(3,'Tara Singh'),(4,'Dev Patel'),
 (5,'Aisha Khan'),(6,'Rohan Das'),(7,'Meera Nair'),(8,'Arjun Rao'),
 (9,'Isha Gupta'),(10,'Kabir Joshi'),(11,'Ananya Sen'),(12,'Vikram Shah');
INSERT INTO application(student_id,year,admission_category,status)
 SELECT student_id,2026,CASE WHEN student_id IN (1,3,7,10) THEN 'OBC_NCL'::seat_cat ELSE 'OPEN'::seat_cat END,'VERIFIED' FROM student;
INSERT INTO exam_result SELECT student_id,2026,300-student_id*8,student_id,
 CASE WHEN student_id IN(1,3,7,10) THEN (SELECT count(*)::int FROM student t WHERE t.student_id<=s.student_id AND t.student_id IN(1,3,7,10)) ELSE NULL END FROM student s;
INSERT INTO choice SELECT s.student_id,2026,q.pref_order::smallint,q.program_id FROM student s
 CROSS JOIN (VALUES(1,1),(2,2),(3,4),(4,3),(5,5)) q(pref_order,program_id);
INSERT INTO hist_closing SELECT y,program_id,c, greatest(1,(program_id*2 + CASE WHEN c='OPEN' THEN 2 ELSE 0 END + y-2023)),'synthetic' FROM generate_series(2023,2025) y CROSS JOIN program CROSS JOIN unnest(ARRAY['OPEN','OBC_NCL']::seat_cat[]) c;
REFRESH MATERIALIZED VIEW mv_cutoff_trend;
SELECT setval(pg_get_serial_sequence('student','student_id'),(SELECT max(student_id) FROM student));
SELECT setval(pg_get_serial_sequence('program','program_id'),(SELECT max(program_id) FROM program));
UPDATE student SET dob=date '2007-01-01'+student_id::int WHERE student_id BETWEEN 1 AND 12;
UPDATE exam_result SET maths=round(total_marks/3,2),physics=round(total_marks/3,2),chemistry=total_marks-2*round(total_marks/3,2) WHERE student_id BETWEEN 1 AND 12;
