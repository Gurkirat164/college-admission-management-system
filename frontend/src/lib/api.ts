export function csrfToken() {
  return document.cookie.split('; ').find(row=>row.startsWith('admission_csrf='))?.split('=')[1] ?? '';
}
export async function api<T>(path:string, options:RequestInit={}):Promise<T> {
  const headers = new Headers(options.headers);
  if (options.body && !(options.body instanceof FormData)) headers.set('Content-Type','application/json');
  if (options.method && options.method!=='GET') headers.set('X-CSRF-Token',csrfToken());
  let response:Response;
  try {response=await fetch(`${import.meta.env.VITE_API_BASE ?? '/api/v1'}${path}`,{...options,headers,credentials:'same-origin'});}
  catch {throw new Error('The local API is unavailable. Start the backend, then try again.');}
  const value=await response.json().catch(()=>null);
  if (!response.ok) {
    const error=new Error(typeof value?.detail==='string'?value.detail:response.status===401?'Sign in to continue.':'The request could not complete. Check your input and try again.');
    Object.assign(error,{status:response.status}); throw error;
  }
  return value as T;
}
export const post=<T>(path:string,body:unknown={})=>api<T>(path,{method:'POST',body:JSON.stringify(body)});
export const put=<T>(path:string,body:unknown)=>api<T>(path,{method:'PUT',body:JSON.stringify(body)});
export function errorMessage(error:unknown) {return error instanceof Error?error.message:'Request failed. Please try again.';}
export function friendly(value:string) {return value.toLowerCase().replaceAll('_',' ').replace(/^./,s=>s.toUpperCase());}
