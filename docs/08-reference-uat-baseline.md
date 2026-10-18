# Reference UAT Observability Baseline

> **Public reference only:** Directory tokens such as `<opensearch-install-dir>` are placeholders, not literal Linux paths. The bank-specific layout and actual paths belong in the private deployment inventory. Generic systemd and config templates elsewhere in this repo remain examples, not evidence of the live installation.

**Reference baseline:** historical UAT example; deployment-specific paths and timestamps are omitted.
**Purpose:** Record a representative component baseline and service layout for reproducible qualification.

This document is intentionally sanitized. It records example versions, path roles, and service responsibilities only. It contains no customer names, internal addresses, credentials, certificates, tokens, or telemetry data.

## Verified component matrix

| Component | Version | Reference executable role / state |
|---|---:|---|
| OpenSearch | 3.6.0 | `<opensearch-install-dir>/bin/opensearch` |
| OpenSearch Dashboards | 3.6.0 | `<dashboards-install-dir>/bin/opensearch-dashboards` |
| Data Prepper | 2.16.0 | `<data-prepper-install-dir>/bin/data-prepper` |
| Prometheus | 3.14.0 | `<prometheus-install-dir>/prometheus` |
| Alertmanager | 0.31.1 | `<alertmanager-install-dir>/alertmanager` |
| node_exporter | 1.12.1 | `<node-exporter-binary>`; installed where Linux host scraping is required |
| process-exporter | 0.8.7 | `<process-exporter-binary>` |
| OpenTelemetry Collector on the dedicated host | Not installed | Collector responsibilities remain cluster-side |
| OpenTelemetry Java agent | 2.30.0 | Application instrumentation baseline |

## Verified service layout

The reference dedicated host runs these systemd-managed services:

- OpenSearch
- OpenSearch Dashboards
- Data Prepper
- Prometheus
- Alertmanager
- node_exporter
- process-exporter

The Prometheus reference process uses:

- configuration: `<prometheus-config-file>`
- TSDB: `<prometheus-data-dir>`
- retention time: `5d`
- retention size: `3GB`
- listen address: `0.0.0.0:9090`
- remote-write receiver enabled

The Alertmanager reference process uses:

- configuration: `<alertmanager-config-file>`
- storage: `<alertmanager-data-dir>`
- listen address: `0.0.0.0:9093`

The process-exporter reference process uses:

- configuration: `<process-exporter-config-file>`
- listen address: `127.0.0.1:9256`
- `gather-smaps=false`
- `threads=false`
- `children=true`

## v1 qualification rule

The first reusable release must reproduce this verified baseline before any component version modernization is attempted.

The release is not qualified until a clean lab machine passes:

1. clean host bootstrap;
2. exact-version verification;
3. configuration render and validation;
4. first apply;
5. second apply without duplicate or destructive changes;
6. backup;
7. intentional non-production damage;
8. restore;
9. post-restore verification.

Future upgrades must be performed as separate changes and must repeat the same qualification sequence.
