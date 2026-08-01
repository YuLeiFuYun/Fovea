# Fovea Evidence Bundles

机器生成的 PR Evidence Bundle 放在此目录，必须通过：

```sh
python3 scripts/validate-evidence.py evidence/<change>.json
```

`pass` 结果只能由 `trusted-ci`、`held-out-evaluator`、`human-reviewer` 或 `release-builder` 产生。Agent 本地输出只能记录为 `agent-declared`，不能满足 required gate。
