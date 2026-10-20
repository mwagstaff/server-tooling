import test from 'node:test';
import assert from 'node:assert/strict';
import {fleetHealth,HealthMonitor} from '../lib/health.ts';
import type {Service,Config} from '../lib/types.ts';

const services=[{name:'api',host:'mini'},{name:'web',host:'sky'}] as Service[];
test('fleet includes every service and cannot show stale checks as healthy',()=>{
  const now=Date.now();
  const rows=fleetHealth(services,[{name:'api',host:'mini',status:'healthy',
    checkedAt:new Date(now-66000).toISOString(),checks:{process:true}}],now);
  assert.equal(rows[0].status,'stale');
  assert.equal(rows[1].status,'unknown');
  assert.equal(rows.length,2);
});
test('a fresh failure stays unhealthy and a report cannot cross host boundaries',()=>{
  const rows=fleetHealth(services,[{name:'api',host:'mini',status:'unhealthy',
    checkedAt:new Date().toISOString(),checks:{process:true,endpoint:false}},
    {name:'web',host:'mini',status:'healthy',checkedAt:new Date().toISOString(),checks:{}}]);
  assert.equal(rows[0].status,'unhealthy');
  assert.equal(rows[1].status,'unknown');
});
test('collector failure clears an earlier healthy result without executing recovery',async()=>{
  let fail=false;
  const monitor=new HealthMonitor({host:'mini',services} as Config,async(_c,target,op)=>{
    assert.equal(target.host,'mini');assert.equal(op,'health_all');
    if(fail)throw new Error('runner unavailable');
    return {services:[{name:'api',status:'healthy',checkedAt:new Date().toISOString(),checks:{process:true,endpoint:true}}]};
  });
  await monitor.refresh();assert.equal(monitor.reports[0].status,'healthy');
  fail=true;await monitor.refresh();assert.equal(monitor.reports[0].status,'unknown');
  assert.equal(fleetHealth(services,monitor.reports)[0].status,'unknown');
  assert.equal(monitor.reports.length,1);
});
test('slow checks do not overlap when the next refresh is due',async()=>{
  let release!:()=>void,calls=0;
  const monitor=new HealthMonitor({host:'mini',services} as Config,async()=>{
    calls++;await new Promise<void>(r=>release=r);return {services:[]};
  });
  const first=monitor.refresh();
  await monitor.refresh();assert.equal(calls,1);
  release();await first;assert.equal(monitor.busy,false);
});
