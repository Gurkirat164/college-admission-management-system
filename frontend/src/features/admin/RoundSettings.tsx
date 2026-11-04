import {useState} from 'react';
import {post,put} from '../../lib/api';
import type {Actions} from '../../components/ui';
function localInput(value:string) {const d=new Date(value);return new Date(d.getTime()-d.getTimezoneOffset()*60000).toISOString().slice(0,16);}
export default function RoundSettings({workspace:w,mutate,busy}:Actions) {
 const [selected,setSelected]=useState(w.rounds.at(-1)?.round_id??1),[deadline,setDeadline]=useState(localInput(new Date(Date.now()+86400000).toISOString()));
 const round=w.rounds.find(r=>r.round_id===selected),last=w.rounds.at(-1);
 return <details className="round-settings"><summary>Round deadlines and next-round setup</summary><form className="history-form" onSubmit={e=>{e.preventDefault();mutate(()=>put(`/admin/rounds/${selected}/deadline`,{deadline:new Date(deadline).toISOString()}),'Response deadline saved.');}}><label>Round<select value={selected} onChange={e=>setSelected(Number(e.target.value))}>{w.rounds.map(r=><option key={r.round_id} value={r.round_id}>Round {r.round_no} / {r.status.toLowerCase()}</option>)}</select></label><label>New response deadline (local time)<input required type="datetime-local" value={deadline} onChange={e=>setDeadline(e.target.value)}/></label><button disabled={busy||!round||!['CHOICES_OPEN','LOCKED'].includes(round.status)}>Save deadline</button></form>{last?.status==='CLOSED'&&<div><p>All previous rounds must be closed before a new round can be created.</p><button disabled={busy} onClick={()=>mutate(()=>post(`/admin/rounds/${w.year}/next`,{deadline:new Date(deadline).toISOString()}),'Next round created and locked. Review it before publishing.')}>Create next round</button></div>}</details>;
}
