import type {Config} from './types.ts';
import type {Store} from './store.ts';

export function incidentBudget(config:Config,store:Store):number {
  return Math.min(1,config.budgetUsd,store.setting('budgetUsd',config.budgetUsd));
}

// Journal accounting survives re-investigation and process restarts. Failed or
// interrupted requests retain their full reservation; only reported usage refunds it.
export function providerSpent(store:Store,id:string,provider:string,model?:string):number {
  let spent=0,pending=0;
  for(const e of store.events(id)) {
    if(e.data.provider!==provider || model!==undefined && e.data.model!==model) continue;
    if(e.kind==='model_request') {pending=e.data.reservedUsd;spent+=pending;}
    if(e.kind==='model_usage') {spent+=e.data.costUsd-pending;pending=0;}
  }
  return Math.max(0,spent);
}
