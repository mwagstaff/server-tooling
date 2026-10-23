import {DatabaseSync} from 'node:sqlite';
import {randomUUID} from 'node:crypto';
import type {Alert, Incident} from './types.ts';

export class Store {
  db: DatabaseSync;
  constructor(file: string) {
    this.db = new DatabaseSync(file);
    this.db.exec(`PRAGMA journal_mode=WAL; PRAGMA busy_timeout=5000;
      CREATE TABLE IF NOT EXISTS incidents (id TEXT PRIMARY KEY, key TEXT UNIQUE, data TEXT NOT NULL);
      CREATE TABLE IF NOT EXISTS events (id INTEGER PRIMARY KEY, incident TEXT, at TEXT, kind TEXT, data TEXT);
      CREATE TABLE IF NOT EXISTS settings (key TEXT PRIMARY KEY, data TEXT);
      CREATE TABLE IF NOT EXISTS notifications (id INTEGER PRIMARY KEY, incident TEXT, channel TEXT, data TEXT, attempts INTEGER DEFAULT 0, next INTEGER DEFAULT 0, delivered INTEGER DEFAULT 0);
      CREATE TABLE IF NOT EXISTS email_seen (id TEXT PRIMARY KEY);
      CREATE TABLE IF NOT EXISTS deliveries (key TEXT PRIMARY KEY, incident TEXT NOT NULL);
    `);
  }
  get(id: string): Incident | undefined {
    const row = this.db.prepare('SELECT data FROM incidents WHERE id=?').get(id);
    return row ? JSON.parse(row.data as string) : undefined;
  }
  list(): Incident[] {
    return this.db.prepare('SELECT data FROM incidents ORDER BY rowid DESC LIMIT 500').all().map(r => JSON.parse(r.data as string));
  }
  put(incident: Incident) {
    const previous=this.get(incident.id);
    if(previous?.resolvedAt && !incident.resolvedAt) incident.resolvedAt=previous.resolvedAt;
    incident.updated = new Date().toISOString();
    this.db.prepare('INSERT INTO incidents VALUES(?,?,?) ON CONFLICT(id) DO UPDATE SET data=excluded.data')
      .run(incident.id, incident.key, JSON.stringify(incident));
  }
  ingest(alert: Alert): {incident: Incident; fresh: boolean} {
    const row = this.db.prepare('SELECT data FROM incidents WHERE key=? OR id=(SELECT incident FROM deliveries WHERE key=?)').get(alert.key, alert.key);
    if (row) {
      const incident: Incident = JSON.parse(row.data as string);
      if (alert.status === 'resolved' && alert.key === incident.alert.key) {
        incident.resolvedAt = alert.receivedAt;
        // A source resolution is evidence, not proof that an action recovered the service.
        if (incident.status === 'queued' || incident.status === 'needs_approval') incident.status = 'source_resolved';
        if (['improved','verification_incomplete'].includes(incident.status)) incident.status='queued';
      }
      this.put(incident);
      if(this.maintenance(alert.host,alert.service)) this.set(`maintenance:deferred:${incident.id}`,true);
      return {incident, fresh:false};
    }
    const correlated = alert.status === 'firing' && alert.service !== 'unknown' &&
      this.list().find(i => i.host === alert.host && i.service === alert.service &&
        i.alert.source !== alert.source && Date.parse(alert.receivedAt) - Date.parse(i.created) < 15 * 60000 &&
        !['recovered','source_resolved','healthy'].includes(i.status));
    if (correlated) {
      this.db.prepare('INSERT INTO deliveries VALUES(?,?)').run(alert.key, correlated.id);
      // Prefer the structured source so source resolution and fresh-state checks
      // still work when its email copy arrived first.
      if(alert.source==='alertmanager') {
        correlated.alert=alert;
        this.put(correlated);
      }
      this.event(correlated.id, 'correlated_alert', alert);
      return {incident:correlated, fresh:false};
    }
    const incident: Incident = {
      id: randomUUID(), key: alert.key, host: alert.host, service: alert.service,
      status: alert.status === 'resolved' ? 'source_resolved' : 'queued',
      created: alert.receivedAt, updated: alert.receivedAt, alert, diagnosis: '', spent: 0, attempts: 0
    };
    this.put(incident);
    this.event(incident.id, 'alert', alert);
    if(this.maintenance(alert.host,alert.service)) this.set(`maintenance:deferred:${incident.id}`,true);
    return {incident, fresh:true};
  }
  event(id: string, kind: string, data: unknown) {
    this.db.prepare('INSERT INTO events(incident,at,kind,data) VALUES(?,?,?,?)')
      .run(id, new Date().toISOString(), kind, JSON.stringify(data));
  }
  events(id: string) {
    return this.db.prepare('SELECT at,kind,data FROM events WHERE incident=? ORDER BY id').all(id)
      .map(r => ({at:r.at as string,kind:r.kind as string, data:JSON.parse(r.data as string)}));
  }
  setting<T>(key: string, fallback: T): T {
    const r = this.db.prepare('SELECT data FROM settings WHERE key=?').get(key);
    return r ? JSON.parse(r.data as string) : fallback;
  }
  set(key: string, value: unknown) {
    this.db.prepare('INSERT INTO settings VALUES(?,?) ON CONFLICT(key) DO UPDATE SET data=excluded.data')
      .run(key, JSON.stringify(value));
  }
  maintenance(host:string,service:string,now=Date.now()) {
    return this.setting<{host:string;services:string[];endsAt:number}[]>('maintenance:windows',[])
      .some(w=>w.host===host && w.endsAt>now && (!w.services.length || w.services.includes(service)));
  }
  recover() {
    for (const i of this.list()) {
      if (['investigating', 'acting', 'verifying'].includes(i.status)) {
        i.status = 'interrupted';
        i.diagnosis += '\nResponder restarted during investigation/recovery. Review action journal before another attempt.';
        this.put(i); this.event(i.id, 'interrupted', {});
      }
    }
  }
}
