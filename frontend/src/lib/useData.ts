import {useCallback,useEffect,useState} from 'react';
import {api,errorMessage} from './api';
export function useData<T>(path:string,revision:unknown=0) {
 const [data,setData]=useState<T|null>(null),[error,setError]=useState(''),[loading,setLoading]=useState(true);
 const reload=useCallback(async()=>{setLoading(true);try{setData(await api<T>(path));setError('');}catch(e){setError(errorMessage(e));}finally{setLoading(false);}},[path]);
 useEffect(()=>{reload();},[reload,revision]);
 return {data,error,loading,reload};
}
