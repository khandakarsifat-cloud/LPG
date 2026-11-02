import type { PermissionDefinition } from '../types/access';

// Adding a capability selects its dependencies. Removing one removes all dependents.
export function permissionSelection(current:readonly string[],id:string,enabled:boolean,catalog:readonly PermissionDefinition[]):string[] {
 const selected=new Set(current);const definitions=new Map(catalog.map(p=>[p.id,p]));
 if(enabled){const add=(key:string)=>{const p=definitions.get(key);if(!p||p.owner_only||selected.has(key))return;selected.add(key);p.dependencies.forEach(add);};add(id);}
 else{selected.delete(id);let changed=true;while(changed){changed=false;for(const key of selected){const p=definitions.get(key);if(p&&p.dependencies.some(d=>!selected.has(d))){selected.delete(key);changed=true;}}}}
 return [...selected].sort();
}
