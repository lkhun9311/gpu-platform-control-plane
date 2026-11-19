| case | t | spec limits.swap / requests.memory | containerStatuses limits.swap | memory.swap.max | memory.swap.current | memory.max | oom_kill | PodResizeInProgress |
|---|---|---|---|---|---|---|---|---|
| A4 | before | 512Mi / 64Mi | 512Mi | 512.0Mi | 256.0Mi (268431360) | 128.0Mi | 0 | absent |
| A4 | +20s | 64Mi / 64Mi | 512Mi | 512.0Mi | 256.0Mi (268431360) | 128.0Mi | 0 | True Error |
| A4 | +41s | 64Mi / 64Mi | 512Mi | 512.0Mi | 256.0Mi (268431360) | 128.0Mi | 0 | True Error |
| A4 | +61s | 64Mi / 64Mi | 512Mi | 512.0Mi | 256.0Mi (268431360) | 128.0Mi | 0 | True Error |
| S1 | before | 512Mi / 64Mi | 512Mi | 512.0Mi | 256.0Mi (268431360) | 128.0Mi | 0 | absent |
| S1 | +20s | 64Mi / 64Mi | 64Mi | 64.0Mi | 256.0Mi (268431360) | 128.0Mi | 0 | absent |
| S1 | +40s | 64Mi / 64Mi | 64Mi | 64.0Mi | 256.0Mi (268431360) | 128.0Mi | 0 | absent |
| S1 | +61s | 64Mi / 64Mi | 64Mi | 64.0Mi | 256.0Mi (268431360) | 128.0Mi | 0 | absent |
| S2 | before | 512Mi / 64Mi | 512Mi | 512.0Mi | 256.0Mi (268431360) | 128.0Mi | 0 | absent |
| S2 | +20s | 64Mi / 64Mi | 64Mi | 64.0Mi | 256.0Mi (268431360) | 128.0Mi | 0 | absent |
| S2 | +40s | 64Mi / 64Mi | 64Mi | 64.0Mi | 256.0Mi (268431360) | 128.0Mi | 0 | absent |
| S2 | +60s | 64Mi / 64Mi | 64Mi | 64.0Mi | 256.0Mi (268431360) | 128.0Mi | 0 | absent |
| S3 | before | 512Mi / 64Mi | 512Mi | 512.0Mi | 256.0Mi (268431360) | 128.0Mi | 0 | absent |
| S3 | +20s | 64Mi / 64Mi | 64Mi | 64.0Mi | 256.0Mi (268431360) | 128.0Mi | 0 | absent |
| S3 | +40s | 64Mi / 64Mi | 64Mi | 64.0Mi | 256.0Mi (268431360) | 128.0Mi | 0 | absent |
| S3 | +60s | 64Mi / 64Mi | 64Mi | 64.0Mi | 256.0Mi (268431360) | 128.0Mi | 0 | absent |
| S4 | before | 512Mi / 64Mi | 512Mi | 512.0Mi | 256.0Mi (268431360) | 128.0Mi | 0 | absent |
| S4 | +20s | 64Mi / 64Mi | 64Mi | 64.0Mi | 256.0Mi (268431360) | 128.0Mi | 0 | absent |
| S4 | +40s | 64Mi / 64Mi | 64Mi | 64.0Mi | 256.0Mi (268431360) | 128.0Mi | 0 | absent |
| S4 | +60s | 64Mi / 64Mi | 64Mi | 64.0Mi | 256.0Mi (268431360) | 128.0Mi | 0 | absent |
| S5 | before | 512Mi / 64Mi | 512Mi | 512.0Mi | 256.0Mi (268431360) | 128.0Mi | 0 | absent |
| S5 | +20s | 64Mi / 64Mi | 64Mi | 64.0Mi | 256.0Mi (268431360) | 128.0Mi | 0 | absent |
| S5 | +41s | 64Mi / 64Mi | 64Mi | 64.0Mi | 256.0Mi (268431360) | 128.0Mi | 0 | absent |
| S5 | +61s | 64Mi / 64Mi | 64Mi | 64.0Mi | 256.0Mi (268431360) | 128.0Mi | 0 | absent |
