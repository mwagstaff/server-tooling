import type {Config,Service} from './types.ts';
import {runTarget} from './runner.ts';

export type ServiceHealth = {
  name:string; host:string; status:'healthy'|'unhealthy'|'unknown'|'stale';
  checkedAt:string|null; checks:Record<string,boolean>; reason?:string;
};
export const HEALTH_INTERVAL_MS=30000;
export const HEALTH_STALE_MS=65000;

export function fleetHealth(services:Service[], reports:ServiceHealth[], now=Date.now()):ServiceHealth[] {
  return services.map(s=>{
    const report=reports.find(r=>r.name===s.name&&r.host===s.host);
    if(!report) return {name:s.name,host:s.host,status:'unknown',checkedAt:null,checks:{},reason:'Status unavailable'};
    if(report.status==='unknown') return report;
    if(!report.checkedAt || !Number.isFinite(Date.parse(report.checkedAt)) ||
      now-Date.parse(report.checkedAt)>HEALTH_STALE_MS) {
      return {...report,status:'stale',reason:'Check is out of date'};
    }
    return report;
  });
}

export class HealthMonitor {
  reports:ServiceHealth[]=[];
  busy=false;
  config:Config;
  run:typeof runTarget;
  constructor(config:Config,run=runTarget) {this.config=config;this.run=run;}
  async refresh() {
    if(this.busy) return;
    this.busy=true;
    const services=this.config.services.filter(s=>s.host===this.config.host);
    try {
      const result=await this.run(this.config,{host:this.config.host,name:'__host__'},'health_all');
      if(!Array.isArray(result.services)) throw new Error('Invalid health report');
      this.reports=services.map(s=>{
        const r=result.services.find((r:any)=>r.name===s.name);
        if(!r || !['healthy','unhealthy','unknown'].includes(r.status) ||
          !Number.isFinite(Date.parse(r.checkedAt))) throw new Error('Incomplete health report');
        return {...r,host:s.host};
      });
    } catch {
      this.reports=services.map(s=>({name:s.name,host:s.host,status:'unknown',checkedAt:null,
        checks:{},reason:'Health checks unavailable'}));
    } finally {this.busy=false;}
  }
}
