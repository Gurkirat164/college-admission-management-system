export type Role = 'ADMIN' | 'STUDENT' | 'ANALYST' | 'AUDITOR';
export interface User {user_id:number; full_name:string; email:string; role:Role; student_id:number|null}
export interface DemoAccount extends User {password:string}
export interface Seat {program_id:number; seat_category:string; seats:number}
export interface Program {program_id:number; institute:string; code:string; name:string; seats:Seat[]}
export interface Round {round_id:number; round_no:number; status:string; response_deadline:string; published_sim_id:number|null}
export interface DocumentRecord {document_id:number; original_name:string; status:string; reason:string|null}
export interface Application {student_id:number; year:number; full_name?:string; admission_category:string; status:string; crl_rank:number|null; cat_rank:number|null; total_marks:number|null; choices_locked_at:string|null; review_reason:string|null; documents?:DocumentRecord[]}
export interface Allocation {round_id:number; student_id:number; program_id:number; seat_category:string; pref_order:number; decision:string|null}
export interface Run {pinned?:boolean;is_mock?:boolean;sim_id:number; round_id:number; label:string; is_published:boolean; snapshot_id:number; duration_ms:number; scenario:Record<string,unknown>; checks:{stability?:string; capacity?:string; monotonicity?:string; blocking_pairs?:number; iterations?:number}; summary:{assigned?:number; applicants?:number; changes?:Record<string,number>}}
export interface RunResult {student_id:number; student_name:string; program:string; institute:string; seat_category:string; pref_order:number; rank_used:number}
export interface Diff {base_program:number|null;sim_program:number|null;student_id:number; student_name:string; base_code:string|null; sim_code:string|null; change_type:string; base_category:string|null; sim_category:string|null}
export interface Cutoff {program_id:number;program:string;institute:string;seat_category:string;before:number|null;after:number|null;shift:number|null;filled:number|null}
export interface RippleNode {pool:string;depth:number;program:string;institute:string;category:string}
export interface RunDetails extends Run {results:RunResult[]; diff:Diff[];cutoffs?:Cutoff[];ripple?:{nodes:RippleNode[];edges:{source:string;target:string;students:number}[];method:string};outcomes?:Record<string,number>}
export interface Freshness {refreshed_at:string|null;stale:boolean;error:string|null;rules_version:string}
export interface Holding {student_id:number;student_name:string;program:string;institute:string;seat_category:string;source:string;final:boolean;confirmed_at:string|null}
export interface Job {job_id:number;job_name:string;status:string;started_at:string;completed_at:string|null;message:string|null;sim_id:number|null}
export interface AdminDashboard {holdings:Holding[];jobs:Job[];freshness:Freshness|null}
export interface Workspace {user:User; year:number; synthetic:boolean; cycle:{choices_locked:boolean; choice_deadline:string}; programs:Program[]; rounds:Round[]; application?:Application; choices?:number[]; documents?:DocumentRecord[]; allocations?:Allocation[]; applications?:Application[]; simulations?:Run[]}
export interface Trace {program:string; institute:string; seat_category:string; rank_used:number; closing_rank:number|null; pref_order:number; outcome:string}
export interface Chance {program_id:number; program:string; institute:string; seat_category:string; your_rank:number; projected_close:number; years_of_data:number; band:string; synthetic:boolean}
export interface SpotPool {pool_id:number; program:string; institute:string; seat_category:string; seats_left:number; status:string}
