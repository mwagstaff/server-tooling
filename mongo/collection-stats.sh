#!/usr/bin/env bash
set -euo pipefail

# Print MongoDB collections sorted by data size, then document count.
#
# Usage:
#   ./collection-stats.sh [HOST]
#
# Defaults:
#   HOST sky
#
# Environment:
#   MONGO_CONTAINER    MongoDB container name (default: mongo-kidsplorers)
#   MONGO_DATABASES    Space-separated database names to inspect. By default,
#                      all non-system databases are inspected.
#   INCLUDE_SYSTEM_DBS Set to 1 to include admin, config, and local databases.

HOST="${1:-sky}"
MONGO_CONTAINER="${MONGO_CONTAINER:-mongo-kidsplorers}"
MONGO_DATABASES="${MONGO_DATABASES:-}"
INCLUDE_SYSTEM_DBS="${INCLUDE_SYSTEM_DBS:-0}"

SSH_OPTS=(-o StrictHostKeyChecking=accept-new)

die() { printf "\nERROR: %s\n" "$*" >&2; exit 1; }

if [ "$#" -gt 1 ]; then
  die "Usage: $0 [HOST]"
fi

if ! ssh -o ConnectTimeout=5 -o BatchMode=yes "${SSH_OPTS[@]}" "${HOST}" "exit" 2>/dev/null; then
  die "Cannot connect to ${HOST}"
fi

ssh "${SSH_OPTS[@]}" "${HOST}" bash -s -- \
  "${MONGO_CONTAINER}" \
  "${MONGO_DATABASES:-__ALL_DATABASES__}" \
  "${INCLUDE_SYSTEM_DBS}" <<'REMOTE'
set -euo pipefail

MONGO_CONTAINER="${1}"
MONGO_DATABASES="${2}"
INCLUDE_SYSTEM_DBS="${3}"

if [ "${MONGO_DATABASES}" = "__ALL_DATABASES__" ]; then
  MONGO_DATABASES=""
fi

if ! command -v docker >/dev/null 2>&1; then
  echo "Docker is not installed or not on PATH" >&2
  exit 1
fi

if ! sudo docker ps --format '{{.Names}}' | grep -qx "${MONGO_CONTAINER}"; then
  echo "MongoDB container is not running: ${MONGO_CONTAINER}" >&2
  exit 1
fi

sudo docker exec -i \
  -e MONGO_DATABASES="${MONGO_DATABASES}" \
  -e INCLUDE_SYSTEM_DBS="${INCLUDE_SYSTEM_DBS}" \
  "${MONGO_CONTAINER}" \
  mongosh --quiet --eval "$(cat <<'MONGO'
const explicitDbs = (process.env.MONGO_DATABASES || "")
  .split(/\s+/)
  .map((name) => name.trim())
  .filter(Boolean);
const includeSystemDbs = process.env.INCLUDE_SYSTEM_DBS === "1";
const systemDbs = new Set(["admin", "config", "local"]);

function asNumber(value) {
  if (value == null) return 0;
  if (typeof value === "number") return value;
  if (typeof value.toNumber === "function") return value.toNumber();
  return Number(value);
}

function formatBytes(bytes) {
  bytes = asNumber(bytes);
  if (!Number.isFinite(bytes)) return "";

  const units = ["B", "KiB", "MiB", "GiB", "TiB"];
  let value = bytes;
  let unit = units[0];

  for (let i = 1; i < units.length && Math.abs(value) >= 1024; i += 1) {
    value /= 1024;
    unit = units[i];
  }

  return `${value >= 10 || unit === "B" ? value.toFixed(0) : value.toFixed(1)} ${unit}`;
}

function formatDate(value) {
  return value ? value.toISOString() : "";
}

function objectIdDate(database, collectionName, direction) {
  const doc = database
    .getCollection(collectionName)
    .find({ _id: { $type: "objectId" } }, { _id: 1 })
    .sort({ _id: direction })
    .limit(1)
    .toArray()[0];

  if (!doc || !doc._id || typeof doc._id.getTimestamp !== "function") {
    return null;
  }

  return doc._id.getTimestamp();
}

function listDatabases() {
  if (explicitDbs.length > 0) return explicitDbs;

  return db
    .adminCommand({ listDatabases: 1, nameOnly: true })
    .databases
    .map((database) => database.name)
    .filter((name) => includeSystemDbs || !systemDbs.has(name));
}

const rows = [];

for (const databaseName of listDatabases()) {
  const database = db.getSiblingDB(databaseName);
  const collections = database
    .getCollectionInfos({ type: "collection" })
    .map((collection) => collection.name)
    .filter((name) => !name.startsWith("system."));

  for (const collectionName of collections) {
    const stats = database.runCommand({ collStats: collectionName });

    if (!stats.ok) {
      rows.push({
        ns: `${databaseName}.${collectionName}`,
        error: stats.errmsg || "collStats failed",
      });
      continue;
    }

    let oldest = null;
    let latest = null;
    try {
      oldest = objectIdDate(database, collectionName, 1);
      latest = objectIdDate(database, collectionName, -1);
    } catch (error) {
      oldest = null;
      latest = null;
    }

    rows.push({
      ns: `${databaseName}.${collectionName}`,
      size: asNumber(stats.size),
      storageSize: asNumber(stats.storageSize),
      indexSize: asNumber(stats.totalIndexSize),
      count: asNumber(stats.count),
      avgObjSize: asNumber(stats.avgObjSize),
      oldest,
      latest,
    });
  }
}

rows.sort((a, b) => {
  const sizeDelta = (b.size || 0) - (a.size || 0);
  if (sizeDelta !== 0) return sizeDelta;
  return (b.count || 0) - (a.count || 0);
});

if (rows.length === 0) {
  print("No collections found.");
  quit(0);
}

const table = rows.map((row) => ({
  namespace: row.ns,
  size: formatBytes(row.size),
  storage: formatBytes(row.storageSize),
  indexes: formatBytes(row.indexSize),
  records: row.count,
  avgRecord: formatBytes(row.avgObjSize),
  oldestRecord: formatDate(row.oldest),
  latestRecord: formatDate(row.latest),
  error: row.error || "",
}));

console.table(table);
MONGO
)"
REMOTE
