# Monitoring Users

Create these users on each host before running `setup-monitoring.sh`.
Both are optional -- only create what the host needs.

## PostgreSQL

```sql
CREATE USER alloy_monitor WITH PASSWORD '<password>';
GRANT pg_monitor TO alloy_monitor;
```

`pg_monitor` grants read-only access to stats, activity, and `pg_stat_statements`.

## Elasticsearch

```bash
curl -u "elastic:<admin_password>" -X POST "http://localhost:9200/_security/role/monitoring_role" \
  -H 'Content-Type: application/json' -d '{
    "cluster": ["monitor"],
    "indices": [{"names": ["*"], "privileges": ["monitor"]}]
  }'

curl -u "elastic:<admin_password>" -X POST "http://localhost:9200/_security/user/alloy_monitor" \
  -H 'Content-Type: application/json' -d '{
    "password": "<password>",
    "roles": ["monitoring_role"]
  }'
```

`monitor` cluster privilege grants read-only access to cluster health, node stats, and index stats.
