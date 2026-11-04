import {useRef,useState,type ReactNode} from 'react';
import {Check,ChevronLeft,ChevronRight} from 'lucide-react';

export function Status({value}:{value:string}) {
  const success=['SUCCEEDED','CONFIRMED','CURRENT','PASS','VERIFIED','PUBLISHED','ALLOTTED','ACCEPTED','SAFE','LIKELY','UPGRADED','NEW_SEAT','RETAINED'].includes(value);
  return <span className={`status ${success?'positive':''}`}>{success&&<Check size={13} aria-hidden="true"/>}{value.toLowerCase().replaceAll('_',' ')}</span>;
}
export function Empty({children}:{children:ReactNode}) {return <div className="empty">{children}</div>;}
export function Table<T>({rows,columns,label}:{rows:T[];columns:{label:string;render:(row:T)=>ReactNode}[];label:string}) {
  const [page,setPage]=useState(0); const pages=Math.max(1,Math.ceil(rows.length/10));const current=Math.min(page,pages-1);
  if(!rows.length)return <Empty>No {label.toLowerCase()} yet.</Empty>;
  return <><div className="table-scroll"><table><caption className="sr-only">{label}</caption><thead><tr>{columns.map(col=><th key={col.label} scope="col">{col.label}</th>)}</tr></thead><tbody>{rows.slice(current*10,current*10+10).map((row,i)=><tr key={i}>{columns.map(col=><td key={col.label}>{col.render(row)}</td>)}</tr>)}</tbody></table></div>{pages>1&&<div className="pagination"><span>Page {current+1} of {pages}</span><button className="quiet icon-button" aria-label="Previous page" disabled={!current} onClick={()=>setPage(current-1)}><ChevronLeft size={16}/></button><button className="quiet icon-button" aria-label="Next page" disabled={current+1>=pages} onClick={()=>setPage(current+1)}><ChevronRight size={16}/></button></div>}</>;
}
export function Confirm({label,title,children,onConfirm,disabled=false}:{label:string;title:string;children:ReactNode;onConfirm:()=>void;disabled?:boolean}) {
  const dialog=useRef<HTMLDialogElement>(null);
  return <><button disabled={disabled} onClick={()=>dialog.current?.showModal()}>{label}</button><dialog ref={dialog} aria-label={title}><h2>{title}</h2><div className="dialog-copy">{children}</div><div className="actions"><button className="quiet" onClick={()=>dialog.current?.close()}>Cancel</button><button onClick={()=>{dialog.current?.close();onConfirm();}}>{label}</button></div></dialog></>;
}
export interface Actions {busy:boolean; mutate:(action:()=>Promise<unknown>,message:string)=>Promise<void>; workspace:import('../lib/types').Workspace}
