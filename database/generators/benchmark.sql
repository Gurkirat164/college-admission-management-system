-- Only for a newly created, disposable admission_verify_* database.
-- :students is replaced by the verification tool after integer range validation.
INSERT INTO admission.admission_cycle(year,choice_deadline) VALUES(2026,now()+interval '90 days');
INSERT INTO admission.program(program_id,institute,code,name)
SELECT g,'Synthetic Campus '||((g-1)/10+1),'P'||((g-1)%10+1),'Synthetic program '||g FROM generate_series(1,30) g;
INSERT INTO admission.program_eligibility SELECT 2026,program_id,80 FROM admission.program;
INSERT INTO admission.seat_matrix
SELECT 2026,p.program_id,c,CASE WHEN c='OPEN' THEN greatest(2,:students/120) ELSE greatest(1,:students/360) END
FROM admission.program p CROSS JOIN unnest(enum_range(NULL::admission.seat_cat)) c;
INSERT INTO admission.student(student_id,full_name,dob) SELECT g,'Synthetic Student '||g,date '2007-01-01' FROM generate_series(1,:students) g;
INSERT INTO admission.application(student_id,year,admission_category,status)
SELECT student_id,2026,(CASE WHEN student_id%10<4 THEN 'OPEN' WHEN student_id%10=4 THEN 'EWS' WHEN student_id%10 IN(5,6) THEN 'OBC_NCL' WHEN student_id%10 IN(7,8) THEN 'SC' ELSE 'ST' END)::admission.seat_cat,'VERIFIED' FROM admission.student;
INSERT INTO admission.exam_result(student_id,year,total_marks,crl_rank,cat_rank,maths,physics,chemistry)
SELECT student_id,2026,marks,student_id,CASE WHEN admission_category='OPEN' THEN NULL ELSE row_number() OVER(PARTITION BY admission_category ORDER BY student_id)::int END,
round(marks/3,2),round(marks/3,2),marks-2*round(marks/3,2)
FROM(SELECT a.*,round(300-(student_id-1)/200.0,2) marks FROM admission.application a) q;
INSERT INTO admission.choice
SELECT student_id,2026,pref::smallint,((student_id::int%3)*6+pref-1)%30+1 FROM admission.student CROSS JOIN generate_series(1,12) pref;
INSERT INTO admission.counselling_round(year,round_no,response_deadline) VALUES(2026,1,now()+interval '7 days');
UPDATE admission.admission_cycle SET input_revision=1;
